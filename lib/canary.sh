#!/bin/bash
# Canary promotion gate (spec 7.1-7.5, issue #22): clone a runner from a
# candidate generation, prove it can complete a real GitHub Actions job, and
# promote it — or retry, and on the last attempt reject the image.
#
# Registering is not evidence. A runner that registers, shows Online/Idle and
# is never assigned work is the exact failure this platform exists to catch,
# so the gate is a real workflow_dispatch polled to conclusion.
#
# EXIT STATUS CONTRACT — `runner canary <gen>` / canary_main. maintain (#24)
# branches on these, so they are API, not an accident:
#
#   0  the canary passed and the generation was promoted (or was already active)
#   1  an error in the gate itself: bad arguments, an unreadable store, a
#      generation in a state the gate cannot act on, or a promotion that did
#      not go through after a passing canary
#   2  not attempted, and no attempt was consumed (spec 7.5): CANARY_ENABLED is
#      not true, the canary is unconfigured, GitHub could not be reached at
#      all, a promotion is in progress, or another canary holds the lock
#   3  the attempt failed and attempts remain — retried on a later cycle
#   4  the attempt budget is spent: the generation is `failed`, its digest is
#      memoed (spec 6.3), and an error notification went out
#
# Idempotent on purpose, because maintain calls it unattended every cycle: a
# second invocation while one is running returns 2 and touches nothing, an
# already-spent budget finalises the generation without cloning, a leftover
# canary VM from a killed attempt is destroyed before the next clone, and an
# unconfigured canary never consumes an attempt. Proven by "two canaries do
# not run at once", "an attempt budget already spent is finalised without
# another clone", "a leftover canary VM from a killed attempt is destroyed
# before the clone", and the item-5 tests in tests/unit/canary.bats.
#
# LOCKS. The gate holds exactly one lock of its own — CANARY_LOCK_FILE — for
# the whole run, and takes no other lock directly. That is what keeps it clear
# of the promotion deadlock described in spec 7.3: clone_runner takes the pool
# lock *shared* underneath it (and returns 3 rather than proceeding while
# PROMOTION_PAUSE_FILE is set), and promote_generation takes the pause file
# plus the pool lock *exclusively* — both while this gate holds nothing but
# CANARY_LOCK_FILE, which neither of them wants. The only other lock it ever
# touches is the per-slot lock around the canary VM's destroy, which is the
# lock lib/reclone.sh holds on the same VM name, and it is taken with a bounded
# wait and released immediately. Proven by "the gate takes no pool lock of its
# own" and "the canary lock is released when the gate finishes".
#
# Library: functions only at source time. Tests load_lib canary.sh and call
# canary_main. When executed as the CLI (`BASH_SOURCE == $0`), require_root,
# load_infra_config, then canary_main. Do not require_root at source time.
#
# GEN_* fields are loaded via gen_read in this shell; gen_update/gen_transition
# are subshells, so SC2030/SC2031 are false positives here as in generations.sh.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_CANARY_LOADED:-}" ]]; then
    return 0
fi
RUNNER_CANARY_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=generations.sh
source "$LIB_DIR/generations.sh"
# digest_is_memoed / memo_failed_digest (spec 6.3) live with the bake pipeline.
# shellcheck source=bake.sh
source "$LIB_DIR/bake.sh"
# shellcheck source=promote.sh
source "$LIB_DIR/promote.sh"

# Poll cadences and the per-request ceiling. Constants rather than config keys:
# spec 14 names the two budgets (CANARY_REGISTER_TIMEOUT, CANARY_TIMEOUT), not
# the interval inside them. Tests set them to 0.
CANARY_POLL_SECONDS="${CANARY_POLL_SECONDS:-15}"
CANARY_REGISTER_POLL_SECONDS="${CANARY_REGISTER_POLL_SECONDS:-10}"
CANARY_API_MAX_TIME="${CANARY_API_MAX_TIME:-20}"
# How long the VM destroy waits for the per-slot lock the hookscript re-clone
# path holds. Bounded: if reclone.sh is already destroying this canary, the
# work is done either way.
CANARY_DESTROY_LOCK_WAIT="${CANARY_DESTROY_LOCK_WAIT:-30}"
CANARY_DESTROY_RETRY_SECONDS="${CANARY_DESTROY_RETRY_SECONDS:-2}"

# Set by canary_preflight for the rest of the run.
CANARY_RUN_ORG=""
CANARY_RUN_REPO=""
CANARY_RUN_REF=""
# Set by canary_attempt so canary_main can report and record them.
CANARY_RUN_URL=""
CANARY_FAIL_REASON=""
CANARY_VMID=""
CANARY_UNCONFIGURED_REASON=""

canary_usage() {
    echo "Usage: runner canary <generation-id>"
}

# fd 218 is the gate's own lock (CANARY_LOCK_FILE). Released explicitly on
# every exit path rather than left to process exit, because canary_main is a
# library function: maintain (#24) calls it in-process and would otherwise hold
# the lock for the rest of its cycle.
_canary_unlock() {
    exec 218>&- 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Configuration (spec 14, 20)
# ---------------------------------------------------------------------------

# The GitHub token the gate dispatches with. CANARY_PAT overrides the org PAT,
# which only has to carry admin:org and so may not be able to dispatch at all.
# It is only ever written into curl's stdin config, never a log line.
canary_token() {
    local pat="${CANARY_PAT:-}"
    pat="${pat//[[:space:]]/}"
    if [[ -n "$pat" ]]; then
        printf '%s\n' "$pat"
        return 0
    fi
    [[ -n "${GITHUB_PAT:-}" ]] || return 1
    printf '%s\n' "$GITHUB_PAT"
}

# The org-config slug whose GitHub org hosts CANARY_REPO and registers the
# canary runner. CANARY_ORG names it; with exactly one organization configured
# there is nothing to choose, so that one is the default rather than a key the
# operator must set. Two or more and the gate refuses to guess.
canary_org_slug() {
    local slug="${CANARY_ORG:-}"
    local -a orgs=()

    slug="${slug//[[:space:]]/}"
    if [[ -z "$slug" ]]; then
        mapfile -t orgs < <(list_orgs)
        if [[ ${#orgs[@]} -ne 1 ]]; then
            log_error "CANARY_ORG is unset and ${#orgs[@]} organizations are configured — set CANARY_ORG to the one hosting CANARY_REPO"
            return 1
        fi
        slug="${orgs[0]}"
    fi
    if ! validate_org_name "$slug"; then
        log_error "Invalid CANARY_ORG '$slug'"
        return 1
    fi
    if [[ ! -f "$ORG_CONFIG_DIR/${slug}.conf" ]]; then
        log_error "CANARY_ORG '$slug' is not a configured organization — run 'runner add-org'"
        return 1
    fi
    printf '%s\n' "$slug"
}

# owner/repo for the canary workflow. A bare name is taken to live under the
# canary org's GitHub organization.
canary_repo_full_name() {
    local github_org="${1:-}" repo="${CANARY_REPO:-}"

    repo="${repo//[[:space:]]/}"
    [[ "$repo" == */* ]] || repo="${github_org}/${repo}"
    if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        log_error "Invalid CANARY_REPO '${CANARY_REPO:-}' (expected <owner>/<repo> or <repo>)"
        return 1
    fi
    printf '%s\n' "$repo"
}

# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------

# One API call. The PAT goes to curl in a config read from stdin: never on
# argv, where /proc/PID/cmdline hands it to any local user, never in curl's
# environment, and never on a process-substitution fd — see the long note on
# github_runners_snapshot for why the fd is the wrong shape.
# Proven by "the canary PAT never reaches curl argv".
#
# Usage: _canary_api <method> <url> [json-body]
# stdout: the response body, then the HTTP status code on its own last line.
# "000" means the request never completed (DNS, timeout, connection refused).
_canary_api() {
    local method="${1:-GET}" url="${2:-}" data="${3:-}" pat auth_config out
    local -a args

    [[ -n "$url" ]] || return 1
    pat=$(canary_token) || {
        log_error "canary: no GitHub token available (CANARY_PAT or the org PAT)"
        return 1
    }
    printf -v auth_config 'header = "Authorization: token %s"\n' "$pat"

    args=(-sS -w '\n%{http_code}' --max-time "$CANARY_API_MAX_TIME"
        -X "$method"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
        --config -)
    [[ -z "$data" ]] || args+=(-H "Content-Type: application/json" --data "$data")
    args+=("$url")

    out=$(curl "${args[@]}" <<< "$auth_config" 2>/dev/null) || out=""
    # A curl that died before writing anything still has to look like a
    # completed call to every caller below, or each one grows its own guard.
    [[ -n "$out" ]] || out=$'\n000'
    printf '%s\n' "$out"
}

_canary_api_code() {
    local resp="${1:-}"
    printf '%s' "${resp##*$'\n'}"
}

_canary_api_body() {
    local resp="${1:-}"
    [[ "$resp" == *$'\n'* ]] || { printf ''; return 0; }
    printf '%s' "${resp%$'\n'*}"
}

# Classic PATs advertise their scopes in X-OAuth-Scopes on any authenticated
# response. Fine-grained tokens send no such header at all, which is not a
# failure: their permissions are not enumerable this way, so the dispatch
# response is what classifies them (spec 14 asks for the scope to be named
# rather than a failed dispatch later — that is exactly what classic tokens,
# the ones that can actually be checked, get here).
#
# stdout: the scope list. Exit: 0 header present, 3 header absent
# (fine-grained), 2 GitHub rejected the token, 1 the probe did not complete.
canary_pat_scopes() {
    local pat auth_config out code headers line

    pat=$(canary_token) || return 1
    printf -v auth_config 'header = "Authorization: token %s"\n' "$pat"
    out=$(curl -sS -o /dev/null -D - -w '\n%{http_code}' \
        --max-time "$CANARY_API_MAX_TIME" \
        -H "Accept: application/vnd.github+json" \
        --config - \
        "https://api.github.com/" <<< "$auth_config" 2>/dev/null) || out=""
    [[ -n "$out" ]] || return 1

    code="${out##*$'\n'}"
    headers="${out%$'\n'*}"
    case "$code" in
        200) ;;
        401) return 2 ;;
        *) return 1 ;;
    esac

    line=$(grep -i '^x-oauth-scopes:' <<< "$headers" | tail -n 1) || line=""
    [[ -n "$line" ]] || return 3
    line="${line#*:}"
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    printf '%s\n' "$line"
}

# workflow_dispatch needs `repo` on a classic PAT (`public_repo` is enough for
# a public repository) or Actions: read and write on a fine-grained one.
# stdout on failure: the reason, for the canary.unconfigured notification.
canary_check_scope() {
    local private="${1:-true}" scopes rc=0 scope
    local -a have=()

    scopes=$(canary_pat_scopes) || rc=$?
    case "$rc" in
        0) ;;
        2)
            printf 'the canary PAT was rejected by GitHub (401) — it is invalid, expired, or revoked'
            return 1
            ;;
        3)
            log_info "canary: the PAT exposes no X-OAuth-Scopes header (fine-grained); scopes cannot be enumerated"
            return 0
            ;;
        *)
            printf 'could not reach the GitHub API to validate the canary PAT'
            return 1
            ;;
    esac

    IFS=', ' read -ra have <<< "$scopes"
    for scope in "${have[@]}"; do
        [[ "$scope" == "repo" ]] && return 0
        [[ "$scope" == "public_repo" && "$private" != "true" ]] && return 0
    done
    printf "the canary PAT is missing the 'repo' scope needed to dispatch a workflow (it has: %s)" \
        "${scopes:-<none>}"
    return 1
}

# ---------------------------------------------------------------------------
# Preflight (spec 7.5: a canary that cannot be attempted consumes no attempt)
# ---------------------------------------------------------------------------

_canary_note_unconfigured() {
    CANARY_UNCONFIGURED_REASON="${1:-unknown}"
    log_error "Canary not attempted: ${CANARY_UNCONFIGURED_REASON}"
}

# Everything that has to be true before an attempt can begin. Returns 0 when
# the canary is configured and dispatchable — with CANARY_RUN_ORG /
# CANARY_RUN_REPO / CANARY_RUN_REF set for the run — and 1 otherwise, with the
# reason in CANARY_UNCONFIGURED_REASON for the caller to notify.
canary_preflight() {
    local slug repo resp code body ref private state scope_reason

    CANARY_UNCONFIGURED_REASON=""
    CANARY_RUN_ORG=""
    CANARY_RUN_REPO=""
    CANARY_RUN_REF=""

    if ! canary_repo_configured; then
        _canary_note_unconfigured "CANARY_REPO is empty (spec 20: the operator supplies it)"
        return 1
    fi
    if ! slug=$(canary_org_slug); then
        _canary_note_unconfigured "CANARY_ORG does not name a configured organization"
        return 1
    fi
    if ! github_runner_credentials "$slug" >/dev/null; then
        _canary_note_unconfigured "the org config for '$slug' has no usable GITHUB_ORG/GITHUB_PAT"
        return 1
    fi
    # Safe now: load_org_config exits the process on a missing or invalid org
    # config, and both were just checked.
    load_org_config "$slug"

    if ! repo=$(canary_repo_full_name "$GITHUB_ORG"); then
        _canary_note_unconfigured "CANARY_REPO '${CANARY_REPO:-}' is not a valid repository name"
        return 1
    fi
    if [[ ! "${CANARY_WORKFLOW:-}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        _canary_note_unconfigured "CANARY_WORKFLOW '${CANARY_WORKFLOW:-}' is not a workflow file name"
        return 1
    fi

    resp=$(_canary_api GET "https://api.github.com/repos/${repo}") || {
        _canary_note_unconfigured "the canary PAT could not be read for repository $repo"
        return 1
    }
    code=$(_canary_api_code "$resp")
    body=$(_canary_api_body "$resp")
    case "$code" in
        200) ;;
        401)
            _canary_note_unconfigured "the canary PAT was rejected by GitHub (401) reading $repo"
            return 1
            ;;
        403)
            _canary_note_unconfigured "the canary PAT is forbidden (403) from $repo — a classic PAT needs 'repo', a fine-grained one needs Actions: read and write"
            return 1
            ;;
        404)
            _canary_note_unconfigured "canary repository $repo does not exist or the canary PAT cannot see it (404)"
            return 1
            ;;
        000)
            _canary_note_unconfigured "the GitHub API was unreachable while reading $repo"
            return 1
            ;;
        *)
            _canary_note_unconfigured "unexpected HTTP $code from GitHub reading $repo"
            return 1
            ;;
    esac
    ref=$(jq -r '.default_branch // empty' <<< "$body" 2>/dev/null) || ref=""
    if [[ -z "$ref" || "$ref" == *[[:space:]]* ]]; then
        _canary_note_unconfigured "GitHub did not report a default branch for $repo"
        return 1
    fi
    private=$(jq -r 'if .private == false then "false" else "true" end' <<< "$body" 2>/dev/null) || private="true"

    if ! scope_reason=$(canary_check_scope "$private"); then
        _canary_note_unconfigured "$scope_reason"
        return 1
    fi

    resp=$(_canary_api GET "https://api.github.com/repos/${repo}/actions/workflows/${CANARY_WORKFLOW}") || {
        _canary_note_unconfigured "could not read workflow ${CANARY_WORKFLOW} in $repo"
        return 1
    }
    code=$(_canary_api_code "$resp")
    body=$(_canary_api_body "$resp")
    case "$code" in
        200) ;;
        404)
            _canary_note_unconfigured "workflow ${CANARY_WORKFLOW} is not on the default branch of $repo — install templates/canary-workflow.yml as .github/workflows/${CANARY_WORKFLOW}"
            return 1
            ;;
        401|403)
            _canary_note_unconfigured "the canary PAT cannot read workflow ${CANARY_WORKFLOW} in $repo (HTTP $code)"
            return 1
            ;;
        000)
            _canary_note_unconfigured "the GitHub API was unreachable while reading workflow ${CANARY_WORKFLOW}"
            return 1
            ;;
        *)
            _canary_note_unconfigured "unexpected HTTP $code reading workflow ${CANARY_WORKFLOW} in $repo"
            return 1
            ;;
    esac
    state=$(jq -r '.state // empty' <<< "$body" 2>/dev/null) || state=""
    if [[ "$state" != "active" ]]; then
        _canary_note_unconfigured "workflow ${CANARY_WORKFLOW} in $repo is '${state:-unknown}', not active — it cannot be dispatched"
        return 1
    fi

    CANARY_RUN_ORG="$slug"
    CANARY_RUN_REPO="$repo"
    CANARY_RUN_REF="$ref"
    return 0
}

# ---------------------------------------------------------------------------
# The attempt (spec 7.1)
# ---------------------------------------------------------------------------

# Wait for the canary clone to show up Online in the org's runner list.
canary_wait_online() {
    local org="$1" name="$2" deadline details id busy status
    deadline=$(( $(date +%s) + CANARY_REGISTER_TIMEOUT ))
    while :; do
        if details=$(github_runner_lookup_details "$org" "$name"); then
            IFS=$'\t' read -r id busy status <<< "$details"
            if [[ "$status" == "online" ]]; then
                log_info "canary: runner $name is Online (id $id, busy=$busy)"
                return 0
            fi
        fi
        (( $(date +%s) < deadline )) || return 1
        sleep "$CANARY_REGISTER_POLL_SECONDS"
    done
}

# Highest existing workflow_dispatch run id, read before dispatching so the run
# this gate then watches is provably a new one. Clock-independent, unlike
# filtering on created_at.
# Proven by "a workflow run that predates the dispatch is never adopted".
canary_latest_run_id() {
    local resp code body id
    resp=$(_canary_api GET "https://api.github.com/repos/${CANARY_RUN_REPO}/actions/workflows/${CANARY_WORKFLOW}/runs?event=workflow_dispatch&per_page=1") || return 1
    code=$(_canary_api_code "$resp")
    body=$(_canary_api_body "$resp")
    [[ "$code" == "200" ]] || return 1
    id=$(jq -r '([.workflow_runs[]?.id] | max) // 0' <<< "$body" 2>/dev/null) || return 1
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$id"
}

# workflow_dispatch. Returns 0 dispatched, 2 the canary cannot be attempted at
# all (scope, missing workflow, inputs the installed copy does not have), 1 a
# failure that is worth a retry.
canary_dispatch() {
    local gen_id="$1" data resp code body message

    data=$(jq -cn --arg ref "$CANARY_RUN_REF" --arg gen "$gen_id" \
        '{ref: $ref, inputs: {generation: $gen}}') || {
        log_error "canary: could not build the dispatch payload"
        return 1
    }
    resp=$(_canary_api POST \
        "https://api.github.com/repos/${CANARY_RUN_REPO}/actions/workflows/${CANARY_WORKFLOW}/dispatches" \
        "$data") || return 1
    code=$(_canary_api_code "$resp")
    body=$(_canary_api_body "$resp")
    message=$(jq -r '.message // empty' <<< "$body" 2>/dev/null) || message=""

    case "$code" in
        204)
            log_info "canary: dispatched ${CANARY_WORKFLOW} in ${CANARY_RUN_REPO} (ref ${CANARY_RUN_REF}, generation $gen_id)"
            return 0
            ;;
        401|403)
            log_error "canary: dispatch refused with HTTP $code — the canary PAT cannot write Actions: a classic PAT needs 'repo', a fine-grained one Actions: read and write${message:+ ($message)}"
            return 2
            ;;
        404)
            log_error "canary: dispatch got 404 — ${CANARY_WORKFLOW} is not dispatchable in ${CANARY_RUN_REPO} on ${CANARY_RUN_REF}${message:+ ($message)}"
            return 2
            ;;
        422)
            log_error "canary: dispatch rejected with 422 — the installed workflow does not match templates/canary-workflow.yml (inputs or ref)${message:+ ($message)}"
            return 2
            ;;
        *)
            log_error "canary: dispatch failed with HTTP $code${message:+ ($message)}"
            return 1
            ;;
    esac
}

# The run the dispatch created: newer than the pre-dispatch baseline, and
# preferring the one whose run-name names this generation. Proven by "the new
# run whose title names this generation is the one watched".
# stdout: "<run-id>\t<html-url>".
canary_find_run() {
    local gen_id="$1" baseline="$2" deadline="$3"
    local resp code body picked title run_id run_url run_title

    title="Runner canary gen-${gen_id}"
    while :; do
        resp=$(_canary_api GET "https://api.github.com/repos/${CANARY_RUN_REPO}/actions/workflows/${CANARY_WORKFLOW}/runs?event=workflow_dispatch&per_page=30") || resp=""
        code=$(_canary_api_code "$resp")
        body=$(_canary_api_body "$resp")
        if [[ "$code" == "200" ]]; then
            picked=$(jq -r --argjson base "$baseline" --arg title "$title" '
                [.workflow_runs[]? | select((.id // 0) > $base)] as $new
                | ((($new | map(select(.display_title == $title))) | max_by(.id))
                   // ($new | max_by(.id)))
                | if . == null then empty
                  else "\(.id)\t\(.html_url // "")\t\(.display_title // "")" end
            ' <<< "$body" 2>/dev/null) || picked=""
            if [[ -n "$picked" ]]; then
                IFS=$'\t' read -r run_id run_url run_title <<< "$picked"
                if [[ "$run_title" != "$title" ]]; then
                    # The gate still watches it: the alternative is timing out
                    # a run that is probably ours. Worth saying out loud —
                    # a workflow whose run-name does not name the generation
                    # cannot be bound to this dispatch by name.
                    log_warn "canary: run $run_id is titled '${run_title}', not '${title}' — the installed workflow may predate run-name"
                fi
                printf '%s\t%s\n' "$run_id" "$run_url"
                return 0
            fi
        fi
        (( $(date +%s) < deadline )) || return 1
        sleep "$CANARY_POLL_SECONDS"
    done
}

# Poll one run to conclusion. stdout: the conclusion (success, failure,
# cancelled, timed_out, ...). Returns 1 when the deadline passes first.
canary_wait_run() {
    local run_id="$1" deadline="$2" resp code body status conclusion

    while :; do
        resp=$(_canary_api GET "https://api.github.com/repos/${CANARY_RUN_REPO}/actions/runs/${run_id}") || resp=""
        code=$(_canary_api_code "$resp")
        body=$(_canary_api_body "$resp")
        if [[ "$code" == "200" ]]; then
            status=$(jq -r '.status // empty' <<< "$body" 2>/dev/null) || status=""
            if [[ "$status" == "completed" ]]; then
                conclusion=$(jq -r '.conclusion // "unknown"' <<< "$body" 2>/dev/null) || conclusion="unknown"
                printf '%s\n' "$conclusion"
                return 0
            fi
        fi
        (( $(date +%s) < deadline )) || return 1
        sleep "$CANARY_POLL_SECONDS"
    done
}

# ---------------------------------------------------------------------------
# The canary VM (spec 7.4)
# ---------------------------------------------------------------------------

# VMID of a VM by exact name, or nothing.
canary_vmid_by_name() {
    local name="$1" vmid
    vmid=$(qm list 200>&- 201>&- 202>&- 2>/dev/null | awk -v n="$name" 'NR>1 && $2 == n {print $1}') || return 1
    [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$vmid"
}

# Destroy one canary VM and free its volumes. Only the canary VM: the
# candidate template is retained on failure (spec 7.5) so a retry is a clone
# and a dispatch, not a 45-minute rebake.
#
# The per-slot lock is the one lib/reclone.sh takes for the same VM name when
# the canary powers off, so the two cannot race; the hookscript is deleted
# first so the destroy does not fire a re-clone at all. Proven by "a failed run
# keeps the candidate template and destroys only the canary VM" and "a canary
# VM that already powered off and vanished is not an error".
canary_destroy_vm() {
    local vmid="${1:-}" name="${2:-}" org="${3:-}" attempt rc=0 status

    [[ "$vmid" =~ ^[0-9]+$ ]] || return 0

    # Best-effort: an --ephemeral runner that ran its job has already removed
    # itself, and one that never registered has nothing to remove.
    deregister_runner "$org" "$name" || true

    mkdir -p "$(dirname "${RUNNER_SLOT_LOCK_PREFIX}-${name}.lock")" || true
    exec 200>"${RUNNER_SLOT_LOCK_PREFIX}-${name}.lock" || return 1
    if ! flock -w "$CANARY_DESTROY_LOCK_WAIT" 200; then
        exec 200>&-
        log_warn "canary: $name is locked by another process (hookscript re-clone) — leaving its destroy to that"
        return 1
    fi

    if ! qm status "$vmid" 200>&- 201>&- 202>&- >/dev/null 2>&1; then
        log_info "canary: VM $vmid ($name) is already gone"
        cleanup_clone_snippets "$vmid"
        exec 200>&-
        return 0
    fi

    # Drop the hookscript before stopping: it is what fires reclone.sh, and
    # while reclone now refuses to re-clone a runner-canary VM, there is no
    # reason to race it.
    qm set "$vmid" --delete hookscript 200>&- 201>&- 202>&- >/dev/null 2>&1 || true
    status=$(qm status "$vmid" 200>&- 201>&- 202>&- 2>/dev/null | awk '{print $2}') || status=""
    if [[ "$status" == "running" ]]; then
        qm stop "$vmid" --timeout 30 200>&- 201>&- 202>&- >/dev/null 2>&1 \
            || qm stop "$vmid" --skiplock 200>&- 201>&- 202>&- >/dev/null 2>&1 \
            || true
    fi

    for attempt in 1 2 3; do
        rc=0
        qm destroy "$vmid" --purge 200>&- 201>&- 202>&- >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 0 ]] && break
        (( attempt < 3 )) || break
        sleep "$CANARY_DESTROY_RETRY_SECONDS"
    done
    cleanup_clone_snippets "$vmid"
    exec 200>&-

    if [[ "$rc" -ne 0 ]]; then
        log_error "canary: failed to destroy canary VM $vmid ($name) — the lifetime guard will reap it"
        return 1
    fi
    log_info "canary: destroyed canary VM $vmid ($name)"
    return 0
}

# A canary VM left behind by a killed attempt still carries gen-<N>-canary and
# would absorb this attempt's dispatch. We hold the canary lock, so nothing
# else is mid-canary and this can only be residue.
canary_destroy_leftover() {
    local name="$1" org="$2" vmid
    vmid=$(canary_vmid_by_name "$name") || return 0
    log_warn "canary: destroying a leftover canary VM $vmid ($name) from an earlier attempt"
    canary_destroy_vm "$vmid" "$name" "$org" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# One attempt, end to end
# ---------------------------------------------------------------------------

# Returns 0 the run concluded success, 1 the attempt failed (a real data point
# about this image or about GitHub — retried per spec 7.5), 2 the attempt could
# not be made at all and must not be charged to the budget, 5 the same but for
# an ordinary reason nobody needs paging about.
# Sets CANARY_VMID, CANARY_RUN_URL and CANARY_FAIL_REASON.
canary_attempt() {
    local template_vmid="$1" gen_id="$2"
    local name="canary-gen${gen_id}"
    local clone_vmid="" rc=0 baseline=0 found run_id run_url conclusion deadline

    CANARY_RUN_URL=""
    CANARY_FAIL_REASON=""
    CANARY_VMID=""

    canary_destroy_leftover "$name" "$CANARY_RUN_ORG" || {
        CANARY_FAIL_REASON="a leftover canary VM named $name could not be destroyed"
        return 2
    }

    clone_vmid=$(clone_canary_runner "$name" "$CANARY_RUN_ORG" "$template_vmid") || rc=$?
    clone_vmid="${clone_vmid//[[:space:]]/}"
    if [[ "$rc" -eq 3 ]]; then
        # clone_runner refuses to clone while a promotion is paused. Nothing
        # about the image was tested, so this cannot cost an attempt — and a
        # promotion window is routine, so it is not worth a notification
        # either: the next maintain cycle picks the canary up again.
        CANARY_FAIL_REASON="a promotion is in progress"
        return 5
    fi
    if [[ "$rc" -ne 0 || ! "$clone_vmid" =~ ^[0-9]+$ ]]; then
        CANARY_FAIL_REASON="the canary clone from template $template_vmid failed"
        return 1
    fi
    CANARY_VMID="$clone_vmid"
    log_info "canary: cloned $name (VMID $clone_vmid) from generation $gen_id (template $template_vmid)"

    if ! canary_wait_online "$CANARY_RUN_ORG" "$name"; then
        CANARY_FAIL_REASON="the canary runner never came Online within ${CANARY_REGISTER_TIMEOUT}s"
        return 1
    fi

    baseline=$(canary_latest_run_id) || baseline=0
    rc=0
    canary_dispatch "$gen_id" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        CANARY_FAIL_REASON="GitHub refused the workflow_dispatch (see the log) — the canary is misconfigured"
        return 2
    fi
    if [[ "$rc" -ne 0 ]]; then
        CANARY_FAIL_REASON="the workflow_dispatch failed"
        return 1
    fi

    # One budget from the dispatch to the conclusion, as spec 7.1 step 5 puts
    # it: queue latency is part of what the canary is testing.
    deadline=$(( $(date +%s) + CANARY_TIMEOUT ))
    if ! found=$(canary_find_run "$gen_id" "$baseline" "$deadline"); then
        CANARY_FAIL_REASON="no workflow run appeared for the dispatch within ${CANARY_TIMEOUT}s"
        return 1
    fi
    IFS=$'\t' read -r run_id run_url <<< "$found"
    CANARY_RUN_URL="$run_url"
    log_info "canary: watching run $run_id (${run_url:-no url})"

    if ! conclusion=$(canary_wait_run "$run_id" "$deadline"); then
        CANARY_FAIL_REASON="run $run_id did not conclude within ${CANARY_TIMEOUT}s"
        return 1
    fi
    if [[ "$conclusion" != "success" ]]; then
        CANARY_FAIL_REASON="the canary run concluded '$conclusion'"
        return 1
    fi
    log_info "canary: run $run_id concluded success for generation $gen_id"
    return 0
}

# ---------------------------------------------------------------------------
# Outcome
# ---------------------------------------------------------------------------

# The attempt budget is spent. Reject the image: `failed`, an error
# notification, and — the one path where a canary failure reaches the memo
# (spec 7.5) — memo the digest so the pipeline stops rebaking something that
# cannot pass. Returns non-zero when the store could not be updated.
# Proven by "three consecutive failures reject the generation and memo its
# digest" and "a non-final failure does not memo the digest".
canary_finalize_failed() {
    local vmid="$1" gen_id="$2" digest="$3" attempts="$4" reason="$5"
    local state rc=0 url="${CANARY_RUN_URL:-}"

    state=$(gen_state_of "$vmid") || state=""
    if [[ "$state" == "candidate" ]]; then
        gen_transition "$vmid" failed "canary: $reason" || {
            log_error "canary: failed to mark generation $gen_id as failed"
            rc=1
        }
    fi
    if [[ -n "$digest" && "$digest" != "unknown" ]]; then
        memo_failed_digest "$digest" || {
            log_error "canary: failed to memo digest $digest — the pipeline will rebake this image"
            rc=1
        }
    else
        log_warn "canary: generation $gen_id has no usable template digest to memo"
    fi

    NOTIFY_GENERATION="$gen_id" notify error canary.failed \
        "Canary rejected generation $gen_id after $attempts attempt(s): $reason" \
        "run ${url:-<none>}"
    log_error "canary: generation $gen_id rejected after $attempts attempt(s): $reason"
    return "$rc"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

canary_main() {
    local gen_id="" vmid state digest attempts max attempt rc=0 url
    local lock_wait

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                canary_usage
                return 0
                ;;
            --*)
                log_error "Unknown option: $1"
                canary_usage >&2
                return 1
                ;;
            *)
                if [[ -n "$gen_id" ]]; then
                    log_error "Unexpected argument: $1"
                    canary_usage >&2
                    return 1
                fi
                gen_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$gen_id" ]]; then
        log_error "Missing generation id"
        canary_usage >&2
        return 1
    fi

    apply_generation_defaults

    vmid=$(gen_vmid_for_id "$gen_id") || return 1
    gen_read "$vmid" || return 1
    state="$GEN_STATE"
    digest="${GEN_TEMPLATE_DIGEST:-}"
    attempts="${GEN_CANARY_ATTEMPTS:-0}"
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    CANARY_RUN_URL="${GEN_CANARY_RUN_URL:-}"

    case "$state" in
        candidate) ;;
        active)
            log_info "Generation $gen_id is already active — nothing to canary"
            return 0
            ;;
        failed)
            log_warn "Generation $gen_id is failed — the canary already rejected it"
            return 4
            ;;
        *)
            log_error "Generation $gen_id is $state, not candidate — refusing to canary"
            return 1
            ;;
    esac

    if [[ "${CANARY_ENABLED:-false}" != "true" ]]; then
        log_info "CANARY_ENABLED is not true — not canarying generation $gen_id"
        return 2
    fi

    # Spec 7.5: a canary that cannot be attempted does not consume an attempt
    # and leaves the candidate pending, because retrying a misconfiguration is
    # pointless and burning the budget on it would reject a good image.
    if ! canary_preflight; then
        NOTIFY_GENERATION="$gen_id" notify warn canary.unconfigured \
            "Canary for generation $gen_id was not attempted: ${CANARY_UNCONFIGURED_REASON}"
        return 2
    fi

    max="${CANARY_MAX_ATTEMPTS:-3}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=3
    if (( max < 1 )); then
        log_warn "CANARY_MAX_ATTEMPTS=$max is below 1 — using 1"
        max=1
    fi

    # A previous attempt that died between charging the budget and finalising
    # leaves the record here. Finish it rather than canarying forever.
    if (( attempts >= max )); then
        canary_finalize_failed "$vmid" "$gen_id" "$digest" "$attempts" \
            "the attempt budget ($max) was already spent" || return 1
        return 4
    fi

    lock_wait="${CANARY_LOCK_WAIT_SECONDS:-0}"
    [[ "$lock_wait" =~ ^[0-9]+$ ]] || lock_wait=0
    mkdir -p "$(dirname "$CANARY_LOCK_FILE")" || {
        log_error "canary: cannot create the lock directory for $CANARY_LOCK_FILE"
        return 1
    }
    exec 218>"$CANARY_LOCK_FILE" || {
        log_error "canary: cannot open $CANARY_LOCK_FILE"
        return 1
    }
    if ! flock -w "$lock_wait" -x 218; then
        _canary_unlock
        log_info "canary: another canary run holds $CANARY_LOCK_FILE — skipping"
        return 2
    fi

    # Re-read under the lock: a canary that finished between the checks above
    # and this point may already have promoted or rejected this generation.
    gen_read "$vmid" || { _canary_unlock; return 1; }
    if [[ "$GEN_STATE" != "candidate" ]]; then
        _canary_unlock
        log_info "Generation $gen_id is ${GEN_STATE} — another canary got there first"
        [[ "$GEN_STATE" == "active" ]] && return 0
        [[ "$GEN_STATE" == "failed" ]] && return 4
        return 1
    fi
    attempts="${GEN_CANARY_ATTEMPTS:-0}"
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    if (( attempts >= max )); then
        _canary_unlock
        canary_finalize_failed "$vmid" "$gen_id" "$digest" "$attempts" \
            "the attempt budget ($max) was already spent" || return 1
        return 4
    fi

    # Charge the attempt before doing anything that can die mid-flight. A crash
    # after this point costs one attempt, which is the safe direction: the
    # alternative is a crash loop that canaries forever.
    attempt=$(( attempts + 1 ))
    if ! gen_update "$vmid" GEN_CANARY_ATTEMPTS="$attempt"; then
        _canary_unlock
        log_error "canary: could not record attempt $attempt for generation $gen_id"
        return 1
    fi
    log_info "canary: attempt $attempt/$max for generation $gen_id (VMID $vmid)"

    rc=0
    canary_attempt "$vmid" "$gen_id" || rc=$?

    url="${CANARY_RUN_URL:-}"
    if [[ -n "$url" && "$url" != *[[:space:]]* ]]; then
        gen_update "$vmid" GEN_CANARY_RUN_URL="$url" \
            || log_warn "canary: could not record the run URL on generation $gen_id"
    fi

    # Only the canary VM (spec 7.5): the candidate template stays for a retry.
    if [[ -n "$CANARY_VMID" ]]; then
        canary_destroy_vm "$CANARY_VMID" "canary-gen${gen_id}" "$CANARY_RUN_ORG" || true
    fi

    # The lock is still held here, deliberately: promotion is the last step of
    # this canary, and a second gate starting on the same candidate while it
    # runs would clone a canary for a generation that is about to be active.
    # No deadlock — promote wants PROMOTION_PAUSE_FILE and the pool lock, and
    # nothing that holds those ever wants CANARY_LOCK_FILE.
    case "$rc" in
        0)
            log_info "canary: generation $gen_id passed — promoting"
            if ! promote_generation "$gen_id" --canary-passed; then
                _canary_unlock
                log_error "canary: generation $gen_id passed the canary but promotion failed"
                return 1
            fi
            _canary_unlock
            return 0
            ;;
        2|5)
            # Never attempted: hand the budget back so a misconfiguration or a
            # promotion window cannot reject a good image (spec 7.5). Proven by
            # "a dispatch GitHub refuses hands the attempt back" and "a
            # promotion in progress does not consume an attempt and stays
            # quiet".
            gen_update "$vmid" GEN_CANARY_ATTEMPTS="$attempts" \
                || log_warn "canary: could not restore the attempt count for generation $gen_id"
            if [[ "$rc" -eq 2 ]]; then
                NOTIFY_GENERATION="$gen_id" notify warn canary.unconfigured \
                    "Canary for generation $gen_id was not attempted: ${CANARY_FAIL_REASON:-unknown}"
                log_warn "canary: generation $gen_id was not attempted: ${CANARY_FAIL_REASON:-unknown}"
            else
                log_info "canary: generation $gen_id was not attempted: ${CANARY_FAIL_REASON:-unknown}"
            fi
            _canary_unlock
            return 2
            ;;
    esac

    if (( attempt >= max )); then
        rc=0
        canary_finalize_failed "$vmid" "$gen_id" "$digest" "$attempt" \
            "${CANARY_FAIL_REASON:-the canary failed}" || rc=$?
        _canary_unlock
        [[ "$rc" -eq 0 ]] || return 1
        return 4
    fi

    NOTIFY_GENERATION="$gen_id" notify warn canary.attempt_failed \
        "Canary attempt $attempt/$max failed for generation $gen_id: ${CANARY_FAIL_REASON:-unknown}" \
        "run ${url:-<none>}"
    log_warn "canary: attempt $attempt/$max failed for generation $gen_id: ${CANARY_FAIL_REASON:-unknown} (run ${url:-<none>})"
    _canary_unlock
    return 3
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root canary
    load_infra_config
    canary_main "$@"
fi
