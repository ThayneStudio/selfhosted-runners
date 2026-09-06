#!/usr/bin/env bats
# Canary orchestration (issue #22, spec 7.1/7.3/7.4/7.5): clone, wait for the
# runner to come Online, workflow_dispatch, poll to conclusion, promote or
# retry, and clean the canary VM up either way.
#
# Everything that talks to GitHub goes through curl, which the harness fakes.
# The canary PAT is passed to curl in a config read from stdin, so it never
# appears in the stub's call log -- which is exactly the property
# "the canary PAT never reaches curl argv" asserts.
#
# jq is faked too, so the tests that exercise the real JSON handling shadow it
# with the real binary (use_real_jq), the same convention rollover.bats and
# canary_labels.bats use.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    # clone_canary_runner renders a cloud-init snippet from the installed
    # templates. Must precede load_lib: common.sh only defaults INSTALL_DIR
    # when it is unset.
    INSTALL_DIR="$REPO_ROOT"
    load_lib canary.sh
    MIN_VMID=9001
    TEMPLATE_ID=9000
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    CANARY_ENABLED=true
    CANARY_ORG=acme
    CANARY_REPO=acme-org/canary-repo
    CANARY_WORKFLOW=runner-canary.yml
    CANARY_PAT=""
    apply_generation_defaults
    # No real waiting anywhere in the suite.
    CANARY_POLL_SECONDS=0
    CANARY_REGISTER_POLL_SECONDS=0

    write_org_config acme ghp_test acme-org
    seed_generations
    use_real_jq
    notify() { printf '%s\n' "$*" >> "$STUB_DIR/notify.log"; }

    # Seams the orchestration tests drive directly. A test that wants the real
    # thing redefines it back or asserts on the stub log.
    clone_canary_runner() {
        printf '%s %s %s\n' "$1" "$2" "$3" >> "$STUB_DIR/clone.log"
        printf '9501\n'
    }
    github_runner_lookup_details() { printf '77\tfalse\tonline\n'; }
    promote_generation() {
        printf '%s\n' "$*" >> "$STUB_DIR/promote.log"
        # The real promote refuses --canary-passed unless the record already
        # carries the gate's evidence, so capture what it would have read.
        gen_read 8901
        printf '%s|%s|%s\n' "${GEN_CANARY_RESULT:-}" "${GEN_CANARY_RUN_URL:-}" \
            "${GEN_CANARY_ATTEMPTS:-}" > "$STUB_DIR/evidence-at-promote"
        gen_transition 8901 active
        gen_transition 9000 superseded
    }
    stub_out qm 'destroy *' < /dev/null
    stub_out qm 'set *' < /dev/null
    stub_out qm 'status *' <<'EOF'
status: stopped
EOF
    stub_out qm 'list*' <<'EOF'
      VMID NAME                 STATUS
EOF
    deregister_runner() { printf '%s %s\n' "$1" "$2" >> "$STUB_DIR/deregister.log"; }
    stub_api_ok
}

# tests/stubs/bin/jq is a strict-stub fake like every other command here;
# shadow it with the real binary so the canary's own jq expressions run.
use_real_jq() {
    jq() { /usr/bin/jq "$@"; }
}

seed_generations() {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0
    gen_create 8901 \
        GEN_ID=2 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=newdigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0
}

# api_response <arg-glob> <http-code>, body on stdin. Mirrors what
# _canary_api reads back: the body, then the status code on the last line.
api_response() {
    local pattern="$1" code="$2" body
    body=$(cat)
    stub_out curl "$pattern" <<EOF
$body
$code
EOF
}

# stub_scopes <value>, or no argument for a fine-grained token that carries no
# X-OAuth-Scopes header at all.
stub_scopes() {
    local header=""
    [[ $# -eq 0 ]] || header="x-oauth-scopes: $1"
    stub_out curl '*-D -*api.github.com/' <<EOF
HTTP/2 200
x-github-api-version-selected: 2022-11-28
$header

200
EOF
}

# Every call answers "configured, reachable, and the run passed" unless a test
# re-registers one of these (the newest matching rule wins).
stub_api_ok() {
    stub_scopes 'admin:org, repo'
    api_response '*/repos/acme-org/canary-repo' 200 <<'EOF'
{"default_branch": "main", "private": true, "full_name": "acme-org/canary-repo"}
EOF
    api_response '*/actions/workflows/runner-canary.yml' 200 <<'EOF'
{"id": 4242, "state": "active", "path": ".github/workflows/runner-canary.yml"}
EOF
    # The dispatch is the one call made with -D -, so its fixture carries a
    # header block: GitHub's Date is the instant every run is compared against.
    stub_out curl '*/actions/workflows/runner-canary.yml/dispatches' <<'EOF'
HTTP/2 204
date: Sun, 06 Sep 2026 07:00:00 GMT

204
EOF
    # The baseline read (per_page=1) runs before the dispatch, the search
    # (per_page=30) after it, so one static rule each is enough.
    api_response '*per_page=1' 200 <<'EOF'
{"workflow_runs": [{"id": 9000, "created_at": "2026-09-06T06:00:00Z"}]}
EOF
    api_response '*per_page=30' 200 <<'EOF'
{"workflow_runs": [{"id": 9911, "display_title": "Runner canary gen-2", "created_at": "2026-09-06T07:00:05Z", "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}]}
EOF
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
}

notify_log() {
    [[ -f "$STUB_DIR/notify.log" ]] && cat "$STUB_DIR/notify.log"
    return 0
}

cloned() {
    [[ -f "$STUB_DIR/clone.log" ]]
}

# Take CANARY_LOCK_FILE exclusively from another process, the way a canary
# already running would. flock is deliberately real (the harness does not stub
# it), and the lock lives on the open file description, so it is held for as
# long as the subshell lives.
hold_canary_lock() {
    local ready="$STUB_DIR/canary-holder-ready"
    rm -f "$ready"
    mkdir -p "$(dirname "$CANARY_LOCK_FILE")"
    (
        exec 218>"$CANARY_LOCK_FILE"
        flock -x 218 || exit 1
        : > "$ready"
        sleep 60
    ) &
    CANARY_HOLDER_PID=$!
    local waited=0
    while [[ ! -e "$ready" && "$waited" -lt 200 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    [ -e "$ready" ]
}

teardown() {
    [[ -z "${CANARY_HOLDER_PID:-}" ]] || kill "$CANARY_HOLDER_PID" 2>/dev/null || true
}

# GEN_CANARY_ATTEMPTS, with "never recorded" reported as 0 so a test can say
# "no attempt was consumed" without caring which of the two it is.
attempts_of() {
    gen_read "$1"
    printf '%s\n' "${GEN_CANARY_ATTEMPTS:-0}"
}

# Keep a copy of a function under another name, so an override can delegate
# the calls it does not care about back to the real implementation.
copy_function() {
    local from="$1" to="$2"
    eval "$(declare -f "$from" | sed "1s/^$from/$to/")"
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

@test "lib/canary.sh is syntactically valid and runner dispatches the canary verb" {
    bash -n "$REPO_ROOT/lib/canary.sh"
    grep -Eq '^[[:space:]]*canary\)' "$REPO_ROOT/runner"
}

@test "runner help lists the canary verb" {
    run bash "$REPO_ROOT/runner" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"canary <id>"* ]]
}

@test "lib/canary.sh documents its exit-status contract" {
    # maintain (#24) branches on these codes; they are API, not an accident.
    local code
    for code in 0 1 2 3 4; do
        grep -Eq "^#[[:space:]]+$code[[:space:]]+[a-z]" "$REPO_ROOT/lib/canary.sh" || {
            printf 'exit code %s is not documented in lib/canary.sh\n' "$code" >&2
            return 1
        }
    done
    grep -q 'EXIT STATUS CONTRACT' "$REPO_ROOT/lib/canary.sh"
}

@test "apply_generation_defaults supplies the canary keys spec 14 names" {
    unset CANARY_MAX_ATTEMPTS CANARY_TIMEOUT CANARY_REGISTER_TIMEOUT CANARY_WORKFLOW
    CANARY_ENABLED="" CANARY_REPO="" CANARY_ORG="" CANARY_PAT=""
    apply_generation_defaults
    [ "$CANARY_ENABLED" = "false" ]
    [ "$CANARY_MAX_ATTEMPTS" = "3" ]
    [ "$CANARY_TIMEOUT" = "1800" ]
    [ "$CANARY_REGISTER_TIMEOUT" = "600" ]
    [ "$CANARY_WORKFLOW" = "runner-canary.yml" ]
}

@test "an out-of-range CANARY_MAX_ATTEMPTS falls back to the default" {
    CANARY_MAX_ATTEMPTS=nonsense
    run --separate-stderr apply_generation_defaults
    [ "$status" -eq 0 ]
    apply_generation_defaults 2>/dev/null
    [ "$CANARY_MAX_ATTEMPTS" = "3" ]
}

@test "maintain and canary share one CANARY_REPO predicate" {
    # Two copies of "is the canary configured" is how maintain comes to refuse
    # a bake for a canary the gate would happily have run, or the reverse.
    grep -q 'canary_repo_configured' "$REPO_ROOT/lib/common.sh"
    grep -q 'canary_repo_configured' "$REPO_ROOT/lib/maintain.sh"
    grep -q 'canary_repo_configured' "$REPO_ROOT/lib/canary.sh"

    CANARY_REPO=""
    run canary_repo_configured
    [ "$status" -ne 0 ]
    CANARY_REPO="   "
    run canary_repo_configured
    [ "$status" -ne 0 ]
    CANARY_REPO="acme-org/canary-repo"
    run canary_repo_configured
    [ "$status" -eq 0 ]
}

@test "canary_token prefers CANARY_PAT and falls back to the org PAT" {
    GITHUB_PAT=ghp_org
    CANARY_PAT=""
    run canary_token
    [ "$output" = "ghp_org" ]
    CANARY_PAT=ghp_canary
    run canary_token
    [ "$output" = "ghp_canary" ]
}

# ---------------------------------------------------------------------------
# State gating: what `runner canary <gen>` does with a generation that is not
# a promotable candidate. maintain calls this unattended on every cycle.
# ---------------------------------------------------------------------------

@test "canary of an already-active generation is a no-op success" {
    run --separate-stderr canary_main 1
    [ "$status" -eq 0 ]
    ! cloned
    [ ! -f "$STUB_DIR/promote.log" ]
}

@test "canary of a failed generation reports failed-final without re-running" {
    gen_transition 8901 failed "earlier canary"
    run --separate-stderr canary_main 2
    [ "$status" -eq 4 ]
    ! cloned
}

@test "canary of a baking generation is an error, not a canary" {
    gen_create 8902 GEN_ID=3 GEN_STATE=baking
    run --separate-stderr canary_main 3
    [ "$status" -eq 1 ]
    ! cloned
}

@test "canary of an unknown generation id is an error" {
    run --separate-stderr canary_main 99
    [ "$status" -eq 1 ]
    ! cloned
}

# ---------------------------------------------------------------------------
# Issue 22 item 5: a canary that cannot be attempted consumes no attempt.
# ---------------------------------------------------------------------------

@test "CANARY_ENABLED=false does not attempt a canary and stays quiet" {
    CANARY_ENABLED=false
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    [ "$(attempts_of 8901)" = "0" ]
    [ ! -f "$STUB_DIR/notify.log" ]
}

@test "an empty CANARY_REPO notifies canary.unconfigured and consumes no attempt" {
    CANARY_REPO=""
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    [ "$(attempts_of 8901)" = "0" ]
    notify_log | grep -q 'warn canary.unconfigured'
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
}

@test "an unresolvable canary org consumes no attempt" {
    CANARY_ORG=nosuchorg
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    [ "$(attempts_of 8901)" = "0" ]
    notify_log | grep -q 'warn canary.unconfigured'
}

@test "an empty CANARY_ORG falls back to the only configured org" {
    CANARY_ORG=""
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    grep -q 'canary-gen2 acme 8901' "$STUB_DIR/clone.log"
}

@test "an empty CANARY_ORG with several orgs configured is unconfigured, not a guess" {
    write_org_config beta ghp_beta beta-org
    CANARY_ORG=""
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    notify_log | grep -q 'warn canary.unconfigured'
    [[ "$stderr" == *"CANARY_ORG"* ]]
}

@test "a missing workflow file consumes no attempt and names the workflow" {
    api_response '*/repos/acme-org/canary-repo/actions/workflows/runner-canary.yml' 404 <<'EOF'
{"message": "Not Found"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    [ "$(attempts_of 8901)" = "0" ]
    notify_log | grep -q 'warn canary.unconfigured'
    notify_log | grep -q 'runner-canary.yml'
}

@test "a disabled workflow consumes no attempt" {
    api_response '*/repos/acme-org/canary-repo/actions/workflows/runner-canary.yml' 200 <<'EOF'
{"id": 4242, "state": "disabled_manually", "path": ".github/workflows/runner-canary.yml"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    notify_log | grep -q 'warn canary.unconfigured'
}

@test "a repo the PAT cannot see consumes no attempt" {
    api_response '*/repos/acme-org/canary-repo' 404 <<'EOF'
{"message": "Not Found"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    [ "$(attempts_of 8901)" = "0" ]
    notify_log | grep -q 'warn canary.unconfigured'
}

# ---------------------------------------------------------------------------
# Issue 22 item 8: PAT scope validated up front, naming the missing scope.
# ---------------------------------------------------------------------------

@test "a classic PAT without repo scope is refused by name before any clone" {
    stub_scopes 'admin:org'
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    [ "$(attempts_of 8901)" = "0" ]
    notify_log | grep -q 'warn canary.unconfigured'
    notify_log | grep -q "'repo' scope"
    [[ "$stderr" == *"'repo' scope"* ]]
}

@test "public_repo is enough for a public canary repo" {
    stub_scopes 'admin:org, public_repo'
    api_response '*/repos/acme-org/canary-repo' 200 <<'EOF'
{"default_branch": "main", "private": false, "full_name": "acme-org/canary-repo"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    cloned
}

@test "public_repo is not enough for a private canary repo" {
    stub_scopes 'admin:org, public_repo'
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    notify_log | grep -q 'warn canary.unconfigured'
}

@test "a fine-grained PAT that exposes no scope header is not refused" {
    # Fine-grained tokens carry no X-OAuth-Scopes at all. Refusing them here
    # would make the canary unusable for every least-privilege token; the
    # dispatch response is what classifies them instead.
    stub_scopes
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    cloned
}

@test "a PAT GitHub rejects outright consumes no attempt" {
    stub_out curl '*-D -*api.github.com/' <<'EOF'
HTTP/2 401

401
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    [ "$(attempts_of 8901)" = "0" ]
    notify_log | grep -q 'warn canary.unconfigured'
}

@test "the canary PAT never reaches curl argv" {
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    ! stub_calls curl | grep -q 'ghp_'
    stub_calls curl | grep -q -- '--config -'
    # A process-substitution fd would keep it off argv too, and is banned:
    # see the comment on github_runners_snapshot.
    ! grep -q 'config <(' "$REPO_ROOT/lib/canary.sh"
}

# ---------------------------------------------------------------------------
# Issue 22 item 1: clone, wait for Online, dispatch, poll to conclusion.
# ---------------------------------------------------------------------------

@test "the canary clones canary-gen<N> from the candidate, not from the active template" {
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    grep -qx 'canary-gen2 acme 8901' "$STUB_DIR/clone.log"
    ! grep -q ' 9000$' "$STUB_DIR/clone.log"
}

@test "the canary waits for the runner to come Online before dispatching" {
    github_runner_lookup_details() {
        local n
        n=$(( $(cat "$STUB_DIR/online-polls" 2>/dev/null || echo 0) + 1 ))
        printf '%s' "$n" > "$STUB_DIR/online-polls"
        if (( n < 3 )); then
            printf '77\tfalse\toffline\n'
        else
            printf '77\tfalse\tonline\n'
        fi
    }
    CANARY_REGISTER_TIMEOUT=60

    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_DIR/online-polls")" = "3" ]
    assert_called curl '*/dispatches'
}

@test "a runner that never comes Online fails the attempt without dispatching" {
    github_runner_lookup_details() { printf '77\tfalse\toffline\n'; }
    CANARY_REGISTER_TIMEOUT=0

    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    refute_called curl '*/dispatches'
    # Registering is part of what the canary tests, so this is a real attempt.
    [ "$(attempts_of 8901)" = "1" ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
    assert_called qm 'destroy 9501 --purge'
    notify_log | grep -q 'warn canary.attempt_failed'
}

@test "the dispatch carries the workflow, the repo, the default branch and the generation" {
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    assert_called curl '*-X POST*{"ref":"main","inputs":{"generation":"2"}}*https://api.github.com/repos/acme-org/canary-repo/actions/workflows/runner-canary.yml/dispatches'
}

@test "a workflow run that predates the dispatch is never adopted" {
    # The baseline read happens before the dispatch: a run already at the top
    # of the list is not this dispatch's run, however recent it looks.
    api_response '*per_page=1' 200 <<'EOF'
{"workflow_runs": [{"id": 9911, "created_at": "2026-09-06T06:59:00Z"}]}
EOF
    CANARY_TIMEOUT=0

    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    refute_called curl '*/actions/runs/9911'
    [[ "$stderr" == *"no workflow run naming generation 2 appeared"* ]]
}

# The same hole from the other side: the baseline is right, but a run with
# this generation's own title is already sitting in the list because a
# previous attempt made it. Its id is above a *stale* baseline only if the
# baseline read failed -- so here it is excluded by its timestamp instead,
# which is the guard that survives a racing hand-dispatch between the
# baseline read and ours.
@test "a pre-existing run with this generation's title is not adopted" {
    api_response '*per_page=1' 200 <<'EOF'
{"workflow_runs": []}
EOF
    # Same title, concluded success, but created a minute before the dispatch
    # GitHub timestamped at 07:00:00.
    api_response '*per_page=30' 200 <<'EOF'
{"workflow_runs": [{"id": 9911, "display_title": "Runner canary gen-2", "created_at": "2026-09-06T06:59:00Z", "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}]}
EOF
    CANARY_TIMEOUT=0

    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    refute_called curl '*/actions/runs/9911'
    [ ! -f "$STUB_DIR/promote.log" ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
}

# Critical #1: the baseline read is what stops every run in the list from
# looking new. A non-200, a timeout, or garbage JSON must stop the attempt
# before the dispatch, not fall back to 0.
@test "a baseline read that fails does not dispatch and costs no attempt" {
    api_response '*per_page=1' 500 <<'EOF'
{"message": "Server Error"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    refute_called curl '*/dispatches'
    [ "$(attempts_of 8901)" = "0" ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
    notify_log | grep -q 'warn canary.unconfigured'
    notify_log | grep -q 'baseline'
}

@test "a baseline read that never completes does not dispatch" {
    stub_out curl '*per_page=1' <<'EOF'

000
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    refute_called curl '*/dispatches'
    [ "$(attempts_of 8901)" = "0" ]
}

@test "a baseline read that returns garbage does not dispatch" {
    api_response '*per_page=1' 200 <<'EOF'
not json at all
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    refute_called curl '*/dispatches'
    [ "$(attempts_of 8901)" = "0" ]
}

# The dispatch response's Date and a run's created_at are both whole seconds,
# so the gate's own run can be stamped in the second before the response that
# reported the dispatch. Rejecting it there costs a full CANARY_TIMEOUT and an
# attempt; three of those reject a good image.
@test "a titled run stamped a second before the dispatch response is still ours" {
    api_response '*per_page=30' 200 <<'EOF'
{"workflow_runs": [{"id": 9911, "display_title": "Runner canary gen-2", "created_at": "2026-09-06T06:59:59Z", "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}]}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    assert_called curl '*/actions/runs/9911'
}

@test "a titled run stamped ten seconds earlier is not ours" {
    api_response '*per_page=30' 200 <<'EOF'
{"workflow_runs": [{"id": 9911, "display_title": "Runner canary gen-2", "created_at": "2026-09-06T06:59:50Z", "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}]}
EOF
    CANARY_TIMEOUT=0

    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    refute_called curl '*/actions/runs/9911'
    [ ! -f "$STUB_DIR/promote.log" ]
}

# Important #2: a run that does not name this generation is never polled --
# a concurrent hand-dispatch (README documents `gh workflow run`) or, once
# maintain drives this on a second host, another host's canary.
@test "a newer untitled run does not win over the titled run that follows it" {
    api_response '*per_page=30' 200 <<'EOF'
{"workflow_runs": [
  {"id": 9999, "display_title": "Runner canary gen-7", "created_at": "2026-09-06T07:00:09Z", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9999"},
  {"id": 9911, "display_title": "Runner canary gen-2", "created_at": "2026-09-06T07:00:05Z", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
]}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    assert_called curl '*/actions/runs/9911'
    refute_called curl '*/actions/runs/9999'
}

@test "a run that names no generation of ours is reported, never polled or promoted" {
    api_response '*per_page=30' 200 <<'EOF'
{"workflow_runs": [{"id": 9999, "display_title": "Some other workflow", "created_at": "2026-09-06T07:00:09Z", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9999"}]}
EOF
    CANARY_TIMEOUT=0

    run --separate-stderr canary_main 2
    # Not attempted: the gate has no evidence about this image either way, so
    # the budget is handed back rather than spent on someone else's run.
    [ "$status" -eq 2 ]
    refute_called curl '*/actions/runs/9999'
    [ ! -f "$STUB_DIR/promote.log" ]
    [ "$(attempts_of 8901)" = "0" ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
    notify_log | grep -q 'warn canary.unconfigured'
    notify_log | grep -q '9999'
}

@test "the new run whose title names this generation is the one watched" {
    api_response '*per_page=30' 200 <<'EOF'
{"workflow_runs": [
  {"id": 9912, "display_title": "Runner canary gen-3", "created_at": "2026-09-06T07:00:06Z", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9912"},
  {"id": 9911, "display_title": "Runner canary gen-2", "created_at": "2026-09-06T07:00:05Z", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
]}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    assert_called curl '*/actions/runs/9911'
    refute_called curl '*/actions/runs/9912'
}

@test "the gate polls a queued run until it concludes" {
    copy_function _canary_api _canary_api_orig
    _canary_api() {
        local n
        case "${2:-}" in
            */actions/runs/9911)
                n=$(( $(cat "$STUB_DIR/run-polls" 2>/dev/null || echo 0) + 1 ))
                printf '%s' "$n" > "$STUB_DIR/run-polls"
                case "$n" in
                    1) printf '{"status":"queued"}\n200\n' ;;
                    2) printf '{"status":"in_progress"}\n200\n' ;;
                    *) printf '{"status":"completed","conclusion":"success"}\n200\n' ;;
                esac
                ;;
            *) _canary_api_orig "$@" ;;
        esac
    }
    CANARY_TIMEOUT=60

    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_DIR/run-polls")" = "3" ]
    [ -f "$STUB_DIR/promote.log" ]
}

@test "a run that never concludes is a failed attempt, not a promotion" {
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "in_progress", "conclusion": null, "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
    CANARY_TIMEOUT=0

    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    [ ! -f "$STUB_DIR/promote.log" ]
    notify_log | grep -q 'warn canary.attempt_failed'
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
}

# ---------------------------------------------------------------------------
# Issue 22 items 2, 3 and 4: promote on success, retry on anything else, and
# reject on the last attempt.
# ---------------------------------------------------------------------------

@test "a successful canary promotes the candidate and destroys the canary VM" {
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    grep -q -- '2 --canary-passed' "$STUB_DIR/promote.log"
    # The evidence promote --canary-passed checks has to be on the record
    # *before* the call, or the real promote refuses the gate's own promotion.
    # Its half of the handshake is "promote --canary-passed refuses a
    # generation with no recorded canary run" in tests/unit/promote.bats.
    grep -qx 'success|https://github.com/acme-org/canary-repo/actions/runs/9911|1' \
        "$STUB_DIR/evidence-at-promote"
    gen_read 8901
    [ "$GEN_CANARY_RESULT" = "success" ]
    assert_called qm 'destroy 9501 --purge'
    gen_read 8901
    [ "$GEN_STATE" = "active" ]
    [ "$GEN_CANARY_ATTEMPTS" = "1" ]
    [ "$GEN_CANARY_RUN_URL" = "https://github.com/acme-org/canary-repo/actions/runs/9911" ]
    run digest_is_memoed newdigest
    [ "$status" -ne 0 ]
}

@test "a failed run keeps the candidate template and destroys only the canary VM" {
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "failure", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
    [ "$GEN_CANARY_ATTEMPTS" = "1" ]
    [ "$GEN_CANARY_RUN_URL" = "https://github.com/acme-org/canary-repo/actions/runs/9911" ]
    assert_called qm 'destroy 9501 --purge'
    refute_called qm 'destroy 8901*'
    [ ! -f "$STUB_DIR/promote.log" ]
}

@test "a failed run records GEN_CANARY_RESULT=failure, not just a run URL" {
    # The run URL alone only says a canary ran. A failed run has one too, and
    # `runner promote <id> --canary-passed` would take it as a pass.
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "failure", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    gen_read 8901
    [ "$GEN_CANARY_RESULT" = "failure" ]
    [ "$GEN_CANARY_RUN_URL" = "https://github.com/acme-org/canary-repo/actions/runs/9911" ]
}

@test "an attempt that was never made leaves the recorded result alone" {
    # rc 2/5 conclude nothing, so there is no outcome to record and no earlier
    # one to invent.
    gen_update 8901 GEN_CANARY_RESULT=failure GEN_CANARY_RUN_URL=https://example.test/runs/1
    clone_canary_runner() { return 3; }

    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    gen_read 8901
    [ "$GEN_CANARY_RESULT" = "failure" ]
}

@test "each failed attempt notifies warn with the run URL" {
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "failure", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    notify_log | grep -q 'warn canary.attempt_failed'
    notify_log | grep -q 'runs/9911'
    notify_log | grep -q "concluded 'failure'"
    ! notify_log | grep -q 'error canary.failed'
}

@test "a non-final failure does not memo the digest" {
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "failure"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    run digest_is_memoed newdigest
    [ "$status" -ne 0 ]
}

@test "the third failure marks the generation failed, memos the digest and notifies error" {
    gen_update 8901 GEN_CANARY_ATTEMPTS=2
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "failure", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 4 ]
    gen_read 8901
    [ "$GEN_STATE" = "failed" ]
    [ "$GEN_CANARY_ATTEMPTS" = "3" ]
    [[ "$GEN_FAILED_REASON" == *canary* ]]
    run digest_is_memoed newdigest
    [ "$status" -eq 0 ]
    notify_log | grep -q 'error canary.failed'
    notify_log | grep -q 'runs/9911'
    [ ! -f "$STUB_DIR/promote.log" ]
}

@test "an attempt budget already spent is finalised without another clone" {
    # A previous attempt that died between charging the budget and finishing
    # leaves the record here; canarying it forever would be the other bug.
    gen_update 8901 GEN_CANARY_ATTEMPTS=3
    run --separate-stderr canary_main 2
    [ "$status" -eq 4 ]
    ! cloned
    gen_read 8901
    [ "$GEN_STATE" = "failed" ]
    run digest_is_memoed newdigest
    [ "$status" -eq 0 ]
    notify_log | grep -q 'error canary.failed'
}

@test "a transient failure retries on a later run and succeeds" {
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "failure", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]

    # The next maintain cycle: same candidate, same template, GitHub healthy.
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    gen_read 8901
    [ "$GEN_STATE" = "active" ]
    [ "$GEN_CANARY_ATTEMPTS" = "2" ]
    run digest_is_memoed newdigest
    [ "$status" -ne 0 ]
}

@test "a promotion in progress does not consume an attempt and stays quiet" {
    # clone_runner returns 3 while PROMOTION_PAUSE_FILE is set. Nothing about
    # the image was tested, so charging the budget for it could reject a good
    # generation after three promotions.
    clone_canary_runner() { return 3; }
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    [ "$(attempts_of 8901)" = "0" ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
    [ ! -f "$STUB_DIR/notify.log" ]
}

@test "a dispatch GitHub refuses hands the attempt back" {
    api_response '*/actions/workflows/runner-canary.yml/dispatches' 403 <<'EOF'
{"message": "Resource not accessible by personal access token"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    [ "$(attempts_of 8901)" = "0" ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
    notify_log | grep -q 'warn canary.unconfigured'
    assert_called qm 'destroy 9501 --purge'
}

# ---------------------------------------------------------------------------
# The canary VM (spec 7.4) and the gate's own lock.
# ---------------------------------------------------------------------------

@test "a leftover canary VM from a killed attempt is destroyed before the clone" {
    stub_out qm 'list*' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9502 canary-gen2          running    2048              30.00 1234
EOF
    # Order matters, not just the fact of the destroy: a leftover canary still
    # carries gen-2-canary and would absorb this attempt's dispatch. Snapshot
    # the qm calls at clone time to prove the destroy came first.
    clone_canary_runner() {
        printf '%s %s %s\n' "$1" "$2" "$3" >> "$STUB_DIR/clone.log"
        stub_calls qm > "$STUB_DIR/qm-at-clone"
        printf '9501\n'
    }

    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    assert_called qm 'destroy 9502 --purge'
    cloned
    grep -q 'destroy 9502 --purge' "$STUB_DIR/qm-at-clone"
}

@test "a canary VM that already powered off and vanished is not an error" {
    # The common case: the VM is --ephemeral, so the hookscript re-clone path
    # destroyed it the moment its job finished.
    stub_status qm 'status *' 2
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    refute_called qm 'destroy *'
    grep -q -- '--canary-passed' "$STUB_DIR/promote.log"
}

@test "the canary deregisters its runner before destroying the VM" {
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    grep -qx 'acme canary-gen2' "$STUB_DIR/deregister.log"
}

@test "two canaries do not run at once" {
    hold_canary_lock
    CANARY_LOCK_WAIT_SECONDS=0

    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    ! cloned
    [ "$(attempts_of 8901)" = "0" ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
}

@test "a spent budget is not finalised while another canary holds the lock" {
    # Finalising outside the lock lets two concurrent invocations both reject
    # the generation, both memo the digest and both page an operator.
    gen_update 8901 GEN_CANARY_ATTEMPTS=3
    hold_canary_lock
    CANARY_LOCK_WAIT_SECONDS=0

    run --separate-stderr canary_main 2
    [ "$status" -eq 2 ]
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
    run digest_is_memoed newdigest
    [ "$status" -ne 0 ]
    [ ! -f "$STUB_DIR/notify.log" ]
}

@test "a spent budget is finalised exactly once across repeated invocations" {
    gen_update 8901 GEN_CANARY_ATTEMPTS=3

    run --separate-stderr canary_main 2
    [ "$status" -eq 4 ]
    run --separate-stderr canary_main 2
    [ "$status" -eq 4 ]
    run --separate-stderr canary_main 2
    [ "$status" -eq 4 ]

    [ "$(grep -c 'error canary.failed' "$STUB_DIR/notify.log")" = "1" ]
    [ "$(grep -c '^newdigest$' "$FAILED_DIGESTS_FILE")" = "1" ]
    gen_read 8901
    [ "$GEN_STATE" = "failed" ]
}

@test "the canary lock is released when the gate finishes" {
    run --separate-stderr canary_main 2
    [ "$status" -eq 0 ]
    exec 219>"$CANARY_LOCK_FILE"
    run flock -n -x 219
    exec 219>&-
    [ "$status" -eq 0 ]
}

@test "the gate takes no pool lock of its own" {
    # Spec 7.3: promotion needs the pool lock exclusively and clone_runner
    # holds it shared. A gate that took it as well would deadlock against the
    # promotion it exists to trigger.
    # Scoped to code lines: the header comment explains the composition, and
    # an unscoped grep would match that instead of an actual acquisition.
    run grep -nE '^[[:space:]]*[^#[:space:]].*(POOL_ACTIVITY_LOCK_FILE|PROMOTION_PAUSE_FILE)' \
        "$REPO_ROOT/lib/canary.sh"
    [ "$status" -ne 0 ]
}

@test "only the canary gate passes --canary-passed" {
    # Code lines only. Comments elsewhere may name the flag -- the store
    # documents why it refuses anything but success, for one -- and what
    # matters is which file actually passes or parses it.
    local files
    files=$(grep -lE '^[[:space:]]*[^#[:space:]].*--canary-passed' "$REPO_ROOT"/lib/*.sh \
        | xargs -n1 basename | sort | tr '\n' ' ')
    [ "$files" = "canary.sh promote.sh " ] || {
        printf 'files passing/parsing --canary-passed: %s\n' "$files" >&2
        return 1
    }
}

@test "vm_config_is_canary reads runner-canary out of either separator" {
    run vm_config_is_canary 'name: canary-gen5
tags: gen-5;runner;runner-canary'
    [ "$status" -eq 0 ]

    run vm_config_is_canary 'name: canary-gen5
tags: runner,gen-5,runner-canary'
    [ "$status" -eq 0 ]

    run vm_config_is_canary 'name: runner-1
tags: runner;gen-5'
    [ "$status" -ne 0 ]

    run vm_config_is_canary 'name: runner-1'
    [ "$status" -ne 0 ]

    # A tag that merely starts with the canary tag is a different tag.
    run vm_config_is_canary 'name: runner-1
tags: runner;runner-canary-old'
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The acceptance list of issue #22, as close as a stubbed harness gets to it.
# ---------------------------------------------------------------------------

@test "a failed canary leaves the active generation and the clone pointer alone" {
    # "the active generation keeps serving jobs throughout": the gate never
    # touches the active template, the pointer, or the pool.
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "failure"}
EOF
    run --separate-stderr canary_main 2
    [ "$status" -eq 3 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    refute_called qm 'destroy 9000*'
    refute_called qm 'stop 9000*'
    refute_called qm 'set 9000 *'
}

@test "three consecutive failures reject the generation and memo its digest" {
    api_response '*/actions/runs/9911' 200 <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "failure", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
EOF
    local attempt
    for attempt in 1 2; do
        run --separate-stderr canary_main 2
        [ "$status" -eq 3 ]
        [ "$(attempts_of 8901)" = "$attempt" ]
        gen_read 8901
        [ "$GEN_STATE" = "candidate" ]
        run digest_is_memoed newdigest
        [ "$status" -ne 0 ]
    done

    run --separate-stderr canary_main 2
    [ "$status" -eq 4 ]
    [ "$(attempts_of 8901)" = "3" ]
    gen_read 8901
    [ "$GEN_STATE" = "failed" ]
    run digest_is_memoed newdigest
    [ "$status" -eq 0 ]
    [ "$(grep -c 'warn canary.attempt_failed' "$STUB_DIR/notify.log")" = "2" ]
    [ "$(grep -c 'error canary.failed' "$STUB_DIR/notify.log")" = "1" ]
    [ ! -f "$STUB_DIR/promote.log" ]

    # And a fourth cycle does not clone again, or notify again.
    rm -f "$STUB_DIR/clone.log"
    run --separate-stderr canary_main 2
    [ "$status" -eq 4 ]
    ! cloned
}
