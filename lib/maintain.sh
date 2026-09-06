#!/bin/bash
# The unattended cycle (spec 11.1, issue #24). One run does, in order:
#
#   adopt -> reconcile interrupted states -> gc -> canary gate -> detect ->
#   bake -> canary gate the image just baked -> drift check
#
# Spec 11.1 lists the stages as "adoption if needed -> detect -> bake if needed
# -> canary -> promote -> gc -> drift check". The gate runs *before* the bake
# decision as well, because an ungated candidate from a previous cycle has to
# be resolved before another ~30 GB image is baked on top of it; and GC runs
# before rather than after, because a generation superseded by this cycle's
# promotion is the retained rollback target (spec 9) and would not be collected
# in the same run anyway.
#
# Only the bake *start* is gated on REBAKE_WINDOW and REBAKE_ENABLED. Adoption,
# reconciliation, GC, the canary gate, detection and the drift check run on
# every cycle, whatever the clock says, so a catch-up run outside the window
# defers the bake to the next window rather than skipping the day.
#
# Every stage is individually skippable (--skip-*) and idempotent: interrupting
# the cycle anywhere and re-running it completes without duplicating anything.
#
# The drift check is the one stage that runs on EVERY exit path, including a
# failed adoption or reconcile — spec 11.4 wants the alarm firing exactly when
# the pipeline is broken, so failures record an exit status and fall through
# rather than returning early.
#
# THE POINTER. promote_generation rewrites TEMPLATE_ID in CONFIG_FILE and does
# not assign the calling shell's copy, so the canary stage re-reads it after a
# promotion. Everything after that stage — detect_should_bake, drift — reads
# the in-shell copy, and without the reload the cycle would bake a twin of the
# image it had just promoted.
#
# LOCKS. The cycle takes no lock of its own. Each stage takes exactly the locks
# its verb takes, so a manual `runner bake|gc|canary|promote|rollback|rollover`
# running concurrently meets the same lock it always meets and no new ordering
# is introduced: the dead-bake reconcile probes BAKE_LOCK_FILE non-blocking
# (spec 15 — the record is written before the VM exists, so only the lock can
# tell a dead bake from a live one), the two-actives reconcile probes the pause
# file and POOL_ACTIVITY_LOCK_FILE non-blocking, gc_main takes gc -> bake ->
# pause -> pool, bake_main takes the bake lock non-blocking, and canary_main
# holds only CANARY_LOCK_FILE.
#
# Library: functions only at source time. Tests load_lib maintain.sh and call
# maintain_main. When executed as the CLI (`BASH_SOURCE == $0`), require_root,
# load_infra_config, then maintain_main. Do not require_root at source time.
#
# MAINTAIN_NOW_HHMM is a test-only HH:MM override for in_rebake_window.
# Production reads `date +%H:%M`. Do not set it on a host.
#
# GEN_* fields are loaded via gen_read in this shell; gen_transition is a
# subshell, so SC2030/SC2031 are false positives here as in generations.sh.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_MAINTAIN_LOADED:-}" ]]; then
    return 0
fi
RUNNER_MAINTAIN_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# bake.sh pulls generations.sh (adopt, gen_list, gen_transition) and detect.sh.
# shellcheck source=bake.sh
source "$LIB_DIR/bake.sh"
# shellcheck source=gc.sh
source "$LIB_DIR/gc.sh"
# The gate and the drift check are cycle stages, so they are called in-process
# the same way gc_main and bake_main are: one process for the systemd oneshot,
# one journal identity, and canary_main's exit status branched on directly
# instead of through a subshell.
# shellcheck source=canary.sh
source "$LIB_DIR/canary.sh"
# shellcheck source=drift.sh
source "$LIB_DIR/drift.sh"

# True (0) when local time is inside REBAKE_WINDOW (HH:MM-HH:MM, inclusive).
# Invalid window, wrap-past-midnight, or an unreadable clock → log_error and
# return 2 (invalid). A valid window that does not contain now → return 1
# (outside). Both fail closed for bake starts. v1 does not wrap midnight.
in_rebake_window() {
    local window now
    local sh sm eh em nh nm
    local start_min end_min now_min

    apply_generation_defaults
    window="${REBAKE_WINDOW:-}"
    window="${window//[[:space:]]/}"

    if [[ ! "$window" =~ ^([0-9]{2}):([0-9]{2})-([0-9]{2}):([0-9]{2})$ ]]; then
        log_error "Invalid REBAKE_WINDOW '${REBAKE_WINDOW:-<empty>}' (expected HH:MM-HH:MM)"
        return 2
    fi
    sh="${BASH_REMATCH[1]}"
    sm="${BASH_REMATCH[2]}"
    eh="${BASH_REMATCH[3]}"
    em="${BASH_REMATCH[4]}"

    if ((10#$sh > 23 || 10#$eh > 23 || 10#$sm > 59 || 10#$em > 59)); then
        log_error "Invalid REBAKE_WINDOW '$window' (hour/minute out of range)"
        return 2
    fi

    start_min=$((10#$sh * 60 + 10#$sm))
    end_min=$((10#$eh * 60 + 10#$em))
    if ((start_min > end_min)); then
        log_error "Invalid REBAKE_WINDOW '$window' (wrap-past-midnight is not supported)"
        return 2
    fi
    if ((start_min == end_min)); then
        log_error "Invalid REBAKE_WINDOW '$window' (zero-width window)"
        return 2
    fi

    if [[ -n "${MAINTAIN_NOW_HHMM:-}" ]]; then
        now="$MAINTAIN_NOW_HHMM"
    else
        now=$(date +%H:%M) || {
            log_error "Failed to read local time for REBAKE_WINDOW"
            return 2
        }
    fi
    now="${now//[[:space:]]/}"
    if [[ ! "$now" =~ ^([0-9]{2}):([0-9]{2})$ ]]; then
        log_error "Invalid clock value for rebake window: ${now:-<empty>}"
        return 2
    fi
    nh="${BASH_REMATCH[1]}"
    nm="${BASH_REMATCH[2]}"
    if ((10#$nh > 23 || 10#$nm > 59)); then
        log_error "Invalid clock value for rebake window: $now"
        return 2
    fi
    now_min=$((10#$nh * 60 + 10#$nm))
    ((now_min >= start_min && now_min <= end_min))
}

# Fail a leftover baking generation. Never qm destroy TEMPLATE_ID. Proven by
# "dead baking record with free bake lock is failed and the VM destroyed",
# "dead baking at TEMPLATE_ID is failed but the VM is not destroyed", and
# "dead baking with no VM still frees leftover volumes".
maintain_fail_dead_bake() {
    local vmid="${1:-}"
    local digest="" gen_id="" pointer="" state=""
    local reason="host reboot or interrupted bake"

    gen_read "$vmid" || return 1
    digest="${GEN_TEMPLATE_DIGEST:-}"
    gen_id="${GEN_ID:-}"

    bake_reap_vmid "$vmid" baking "$reason"

    # Live pointer: bake_reap_vmid skips destroy *and* the failed transition.
    # The record still has to leave baking or the next cycle retries forever.
    state=$(gen_state_of "$vmid" 2>/dev/null) || state=""
    if [[ "$state" == "baking" ]]; then
        pointer=$(reload_active_template_id) || pointer=""
        if [[ "$vmid" == "$pointer" ]]; then
            log_error "Refusing to destroy TEMPLATE_ID $TEMPLATE_ID on dead-bake reconcile"
            gen_transition "$vmid" failed "$reason" || true
        fi
    fi

    # Do not memo/notify a generation that finished (candidate/active) between
    # the baking snapshot and this reap — that would block the weekly floor.
    state=$(gen_state_of "$vmid" 2>/dev/null) || state=""
    [[ "$state" == "failed" ]] || return 0

    if [[ -n "$digest" && "$digest" != "unknown" ]]; then
        memo_failed_digest "$digest" || log_error "Failed to memo failed digest $digest"
    fi
    NOTIFY_GENERATION="$gen_id" notify error bake.failed "$reason"
    return 0
}

# SIGKILL/OOM can leave PROMOTION_PAUSE_FILE on tmpfs. Stale means nothing
# holds an exclusive flock on the pause file itself — not "exclusive 202 is
# free". Promote writes the pause and flocks it *before* flock -w 202, so a
# 202 probe would steal the pause from a live waiter. Proven by "promotion
# pause is left when the pause file is flocked".
maintain_clear_stale_promotion_pause() {
    [[ -e "$PROMOTION_PAUSE_FILE" ]] || return 0
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")" || return 0
    exec 209>>"$PROMOTION_PAUSE_FILE" || return 0
    if flock -n 209; then
        rm -f "$PROMOTION_PAUSE_FILE"
        log_warn "Removed stale promotion pause file (no pause-file lock holder)"
    fi
    exec 209>&- || true
    return 0
}

# If BAKE_LOCK_FILE is taken, a live bake owns these records — leave them.
# Proven by "baking record is left alone when the bake lock is held".
# fd 208: 207 is bake_main's exclusive lock.
maintain_reconcile_baking() {
    local vmid list
    local -a baking=()

    list=$(gen_list baking) || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        baking+=("$vmid")
    done <<< "$list"
    ((${#baking[@]} > 0)) || return 0

    mkdir -p "$(dirname "$BAKE_LOCK_FILE")" || return 1
    exec 208>"$BAKE_LOCK_FILE" || {
        log_error "Cannot open bake lock $BAKE_LOCK_FILE"
        return 1
    }
    if ! flock -n 208; then
        log_info "Bake lock is held — leaving baking records alone"
        exec 208>&- || true
        return 0
    fi

    for vmid in "${baking[@]}"; do
        maintain_fail_dead_bake "$vmid" || true
    done
    exec 208>&- || true
    return 0
}

# Zero actives: restore the generation TEMPLATE_ID names (superseded→active
# is allowed). failed/rejected/baking: log_warn and do not force invalid edges.
maintain_repair_zero_actives() {
    local state

    if [[ -z "${TEMPLATE_ID:-}" ]] || ! gen_exists "$TEMPLATE_ID"; then
        log_warn "Zero active generations and TEMPLATE_ID is not a known generation"
        return 0
    fi
    gen_read "$TEMPLATE_ID" || return 1
    state="$GEN_STATE"
    case "$state" in
        active)
            return 0
            ;;
        superseded|candidate)
            gen_transition "$TEMPLATE_ID" active || return 1
            notify warn generation.reconciled \
                "Zero active generations; restored VMID $TEMPLATE_ID to active"
            log_warn "Zero active generations; restored VMID $TEMPLATE_ID to active"
            return 0
            ;;
        *)
            log_warn "Zero active generations; TEMPLATE_ID $TEMPLATE_ID is $state — not forcing an invalid transition"
            return 0
            ;;
    esac
}

# Split-brain active records: TEMPLATE_ID wins; if that is ambiguous, newest
# GEN_PROMOTED_AT. Never the highest GEN_ID. Proven by "two actives:
# TEMPLATE_ID wins, not the higher GEN_ID". Skip while a promote holds the
# pause file. Zero actives restore the pointer's generation.
maintain_reconcile_two_actives() {
    local vmid keep="" best_ts="" ts list rc=0 pool_fd
    local -a actives=()
    local -a losers=()

    if [[ -e "$PROMOTION_PAUSE_FILE" ]]; then
        log_info "Promotion pause file present — skipping active-generation reconcile"
        return 0
    fi

    # Exclusive flock on the pool lock file so a live promote that lost the
    # pause bit cannot gen_transition while we demote. Skip if the pool is busy.
    # Proven by "two-actives skipped while the exclusive pool lock is held".
    mkdir -p "$(dirname "$POOL_ACTIVITY_LOCK_FILE")" || return 1
    # Dynamic fd: the same inode as promote's exclusive 202. Hard-coded 202/213
    # collide with clone_runner and with bats `run` stderr capture.
    # Proven by "two-actives skipped while the exclusive pool lock is held".
    exec {pool_fd}>"$POOL_ACTIVITY_LOCK_FILE" || return 1
    if ! flock -n "$pool_fd"; then
        log_info "pool lock busy — skipping active-generation reconcile"
        exec {pool_fd}>&-
        return 0
    fi

    list=$(gen_list active) || {
        exec {pool_fd}>&-
        return 1
    }
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        actives+=("$vmid")
    done <<< "$list"
    if ((${#actives[@]} == 0)); then
        maintain_repair_zero_actives
        rc=$?
        exec {pool_fd}>&-
        return "$rc"
    fi
    if ((${#actives[@]} <= 1)); then
        exec {pool_fd}>&-
        return 0
    fi

    for vmid in "${actives[@]}"; do
        if [[ -n "${TEMPLATE_ID:-}" && "$vmid" == "$TEMPLATE_ID" ]]; then
            keep="$vmid"
            break
        fi
    done

    if [[ -z "$keep" ]]; then
        for vmid in "${actives[@]}"; do
            gen_read "$vmid" || {
                exec {pool_fd}>&-
                return 1
            }
            ts="${GEN_PROMOTED_AT:-}"
            if [[ -z "$keep" ]]; then
                keep="$vmid"
                best_ts="$ts"
                continue
            fi
            if [[ -n "$ts" && ( -z "$best_ts" || "$ts" > "$best_ts" ) ]]; then
                keep="$vmid"
                best_ts="$ts"
            fi
        done
    fi
    if [[ -z "$keep" ]]; then
        exec {pool_fd}>&-
        return 1
    fi

    for vmid in "${actives[@]}"; do
        [[ "$vmid" != "$keep" ]] || continue
        losers+=("$vmid")
        gen_transition "$vmid" superseded || {
            exec {pool_fd}>&-
            return 1
        }
    done
    if ((${#losers[@]} == 0)); then
        exec {pool_fd}>&-
        return 0
    fi

    notify warn generation.reconciled \
        "Multiple active generations; kept VMID $keep" \
        "demoted ${losers[*]} to superseded"
    log_warn "Reconciled $((${#actives[@]})) active generations; kept VMID $keep"
    exec {pool_fd}>&-
    return 0
}

# ---------------------------------------------------------------------------
# Steady-state notices
#
# Some cycle states persist until a human acts — a candidate that cannot be
# gated because CANARY_ENABLED=false is the one this exists for. Notifying on
# every daily run would teach the operator to filter the webhook, so a notice
# fires when its value changes and stays quiet while it repeats. Same shape as
# drift_note_failure's `warned=` marker in lib/drift.sh.
# ---------------------------------------------------------------------------

maintain_note_value() {
    local key="${1:-}" line
    [[ -n "$key" && -f "$MAINTAIN_NOTICE_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] || continue
        printf '%s' "${line#"$key="}"
        return 0
    done < "$MAINTAIN_NOTICE_FILE"
    return 0
}

# Record (or, with an empty value, forget) one notice key. Never fails the
# cycle: an unwritable state directory costs a repeated notification, nothing
# more.
maintain_set_note() {
    local key="${1:-}" value="${2:-}" line
    local -a kept=()

    [[ -n "$key" ]] || return 0
    if [[ -f "$MAINTAIN_NOTICE_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" ]] || continue
            [[ "$line" == "$key="* ]] && continue
            kept+=("$line")
        done < "$MAINTAIN_NOTICE_FILE"
    fi
    [[ -z "$value" ]] || kept+=("$key=$value")

    if ((${#kept[@]} == 0)); then
        rm -f "$MAINTAIN_NOTICE_FILE"
        return 0
    fi
    ensure_state_dir "$(dirname "$MAINTAIN_NOTICE_FILE")" || return 0
    printf '%s\n' "${kept[@]}" | gen_write_file_atomic "$MAINTAIN_NOTICE_FILE" ||
        log_warn "Failed to record maintain notice $key"
    return 0
}

# True (0) the first time <key> is seen carrying <value>, false while it
# repeats. The caller notifies only on true.
maintain_note_once() {
    local key="${1:-}" value="${2:-}"
    [[ "$(maintain_note_value "$key")" != "$value" ]] || return 1
    maintain_set_note "$key" "$value"
    return 0
}

# ---------------------------------------------------------------------------
# Cycle stages
# ---------------------------------------------------------------------------

# Read the candidate the cycle acts on into MAINTAIN_CANDIDATE_VMID (empty
# when there is none) and MAINTAIN_CANDIDATE_COUNT.
#
# Globals rather than stdout on purpose: the caller needs both values, and the
# warn-once bookkeeping below would be lost to the subshell a command
# substitution creates. Callers must therefore invoke this directly, never as
# $(maintain_read_candidate).
#
# "Newest" is gen_newest_candidate — highest GEN_ID, the same selection GC
# makes. Not the highest VMID: allocate_generation_vmid hands out the lowest
# free band VMID, so a generation baked after GC freed a lower slot sits below
# an older one.
#
# More than one candidate is a symptom, not a normal state — the bake stage
# refuses to bake while any exists — so it is named once per cycle rather than
# once per read.
maintain_read_candidate() {
    local vmid list

    MAINTAIN_CANDIDATE_VMID=""
    MAINTAIN_CANDIDATE_COUNT=0

    list=$(gen_list candidate) || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        MAINTAIN_CANDIDATE_COUNT=$((MAINTAIN_CANDIDATE_COUNT + 1))
    done <<< "$list"
    ((MAINTAIN_CANDIDATE_COUNT > 0)) || return 0

    MAINTAIN_CANDIDATE_VMID=$(gen_newest_candidate) || return 1
    if ((MAINTAIN_CANDIDATE_COUNT > 1)) && [[ -z "${MAINTAIN_MULTI_CANDIDATE_WARNED:-}" ]]; then
        MAINTAIN_MULTI_CANDIDATE_WARNED=1
        log_warn "$MAINTAIN_CANDIDATE_COUNT candidate generations exist; acting on the newest by GEN_ID, VMID $MAINTAIN_CANDIDATE_VMID"
    fi
    return 0
}

# Put a candidate through the canary gate (spec 7.1-7.5). The gate's exit
# status is the contract documented at the top of lib/canary.sh and is API for
# exactly this caller; this stage translates it into "the cycle may continue"
# (0) or "the cycle does not understand the store" (1). What the gate did to
# the record is what the bake stage reads next: a promoted candidate is gone,
# so the bake stage stops holding; a candidate still standing keeps holding.
maintain_canary_stage() {
    local vmid gen_id rc=0

    maintain_read_candidate || return 1
    vmid="$MAINTAIN_CANDIDATE_VMID"
    if [[ -z "$vmid" ]]; then
        maintain_set_note candidate_pending ""
        return 0
    fi
    gen_read "$vmid" || return 1
    gen_id="${GEN_ID:-}"
    if [[ ! "$gen_id" =~ ^[0-9]+$ ]]; then
        log_error "Candidate VMID $vmid carries no usable generation id"
        return 1
    fi

    # Spec 13/14: with the gate off, promotion is the operator's decision and
    # `runner upgrade` is the verb that makes it. Leaving the candidate alone
    # is the whole behavior; saying so once is the rest of it.
    if [[ "${CANARY_ENABLED:-false}" != "true" ]]; then
        log_info "candidate generation $gen_id (VMID $vmid) is waiting for an operator: CANARY_ENABLED=false — promote it with 'runner upgrade'"
        if maintain_note_once candidate_pending "$gen_id"; then
            NOTIFY_GENERATION="$gen_id" notify warn maintain.candidate_pending \
                "Candidate generation $gen_id is baked but ungated" \
                "CANARY_ENABLED=false; promote it with 'runner upgrade'"
        fi
        return 0
    fi
    maintain_set_note candidate_pending ""

    canary_main "$gen_id" || rc=$?
    case "$rc" in
        0)
            log_info "canary passed: generation $gen_id was promoted"
            # promote_generation rewrites TEMPLATE_ID in CONFIG_FILE
            # (lib/promote.sh) and deliberately does not assign this shell's
            # copy; lib/upgrade.sh compensates the same way after its own
            # promote. Everything downstream reads the in-shell copy —
            # detect_should_bake compares the input digest against the record
            # TEMPLATE_ID names (lib/detect.sh), and drift_fleet_version reads
            # its GEN_RUNNER_VERSION — so without this reload the cycle would
            # compare against the generation it had just superseded, bake a
            # twin of the image it had just promoted, and then report drift
            # against the version it had just replaced.
            TEMPLATE_ID=$(reload_active_template_id) || {
                log_error "Could not re-read the active pointer after promoting generation $gen_id"
                return 1
            }
            ;;
        2)
            # Already notified by the gate. Not an attempt, so nothing was
            # consumed and the candidate stays exactly where it was.
            log_info "canary was not attempted for generation $gen_id — it stays a candidate"
            ;;
        3)
            log_info "canary attempt failed for generation $gen_id — retry on the next cycle"
            ;;
        4)
            # The gate already failed the record, memoed the digest (spec 6.3)
            # and notified. A new bake is free to run if the digest differs.
            log_warn "canary rejected generation $gen_id — its digest is memoed"
            ;;
        *)
            log_error "Canary gate errored (exit $rc) for generation $gen_id"
            NOTIFY_GENERATION="$gen_id" notify error maintain.canary_error \
                "Canary gate errored (exit $rc) for generation $gen_id" \
                "no bake will start this cycle"
            return 1
            ;;
    esac
    return 0
}

# Detection runs every cycle (issue #24 item 3); only the bake start is gated.
# bake_main is never --force here: --force is the operator's override (spec
# 11.1) and would ignore the window, the memo and the weekly floor.
maintain_bake_stage() {
    local candidate="${1:-}"
    local decision win_rc=0

    decision=$(detect_should_bake) || {
        log_error "detect_should_bake failed"
        return 1
    }
    case "$decision" in
        yes\ *)
            log_info "bake needed: ${decision#yes }"
            ;;
        no\ *)
            log_info "nothing to do: ${decision#no }"
            return 0
            ;;
        *)
            log_error "detect_should_bake produced an unreadable decision: ${decision:-<empty>}"
            return 1
            ;;
    esac

    # An ungated candidate is already occupying the band. Baking a second image
    # on top of it strands ~30 GB per cycle and leaves the gate two candidates
    # to choose between. Whatever the gate stage decided above stands. The VMID
    # is passed in rather than re-derived so the whole cycle acts on one
    # reading of the store.
    if [[ -n "$candidate" ]]; then
        log_info "not starting a bake: the candidate at VMID $candidate is waiting on the canary gate"
        return 0
    fi

    # canary_repo_configured lives in common.sh so this and the gate
    # itself (lib/canary.sh) cannot disagree about "configured".
    if [[ "${CANARY_ENABLED}" == "true" ]] && ! canary_repo_configured; then
        notify warn canary.unconfigured \
            "CANARY_ENABLED=true but CANARY_REPO is empty — refusing to bake"
        log_warn "Refusing to start a bake: CANARY_ENABLED=true but CANARY_REPO is empty"
        return 0
    fi
    in_rebake_window || win_rc=$?
    if (( win_rc != 0 )); then
        if (( win_rc == 1 )); then
            log_info "deferring bake until REBAKE_WINDOW"
        fi
        return 0
    fi
    if [[ "${REBAKE_ENABLED}" != "true" ]]; then
        log_info "nothing to do: rebake-disabled"
        return 0
    fi
    bake_main
}

# Spec 11.1 lists the drift check as a stage of the cycle; spec 11.4 makes the
# alarm independent of the bake pipeline "so it still fires when the pipeline is
# broken". Both are honored: the check runs last and on *every* exit path — a
# deferred bake, REBAKE_ENABLED=false, a failed GC, a gate error, a failed
# adoption, a failed reconcile — because those are precisely the broken-pipeline
# states 11.4 names. github-runner-drift.timer keeps its own 6-hourly schedule
# too, because an alarm that only fired from the cycle would go quiet exactly
# when the cycle wedges.
#
# drift_main reports only and never bakes. Its *prolonged-API-failure* warning
# is deduped through DRIFT_FAIL_FILE, but drift.warning / drift.critical are
# not deduped at all, so an in-window fleet produces one extra alert per day on
# top of the timer's four. That is the price of the 11.4 guarantee and is
# deliberate; if it becomes noise, dedupe belongs in drift_notify, not here.
maintain_drift_stage() {
    drift_main || log_warn "Drift check did not complete"
    return 0
}

maintain_usage() {
    cat <<'EOF'
Usage: runner maintain [options]

Run one unattended cycle: adopt, reconcile interrupted states, garbage
collect, gate a candidate through the canary, bake if the window allows, and
check the 30-day runner drift window. Every stage is idempotent, so an
interrupted cycle is completed by the next one.

Options:
  --skip-adopt      Do not adopt a deployed template into the generation store
  --skip-reconcile  Do not repair interrupted bakes or split-brain actives
  --skip-gc         Do not run generation garbage collection
  --skip-canary     Do not run the canary gate against a candidate
  --skip-bake       Do not detect or start a bake
  --skip-drift      Do not run the 30-day drift check
  -h, --help        Show this help

Bakes start only inside REBAKE_WINDOW and only while REBAKE_ENABLED=true.
Every other stage runs whatever the clock says.
EOF
}

maintain_main() {
    local rc=0 halt=0 before="" after=""
    local skip_adopt=0 skip_reconcile=0 skip_gc=0
    local skip_canary=0 skip_bake=0 skip_drift=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-adopt) skip_adopt=1; shift ;;
            --skip-reconcile) skip_reconcile=1; shift ;;
            --skip-gc) skip_gc=1; shift ;;
            --skip-canary) skip_canary=1; shift ;;
            --skip-bake) skip_bake=1; shift ;;
            --skip-drift) skip_drift=1; shift ;;
            -h|--help)
                maintain_usage
                return 0
                ;;
            *)
                log_error "Unknown option: $1"
                maintain_usage >&2
                return 1
                ;;
        esac
    done

    apply_generation_defaults
    MAINTAIN_MULTI_CANDIDATE_WARNED=""

    # `halt` stops the stages that would act on a store this cycle can no
    # longer trust. It never skips the drift check: spec 11.4 wants the alarm
    # firing in exactly these states, so every failure below records rc and
    # falls through rather than returning.
    if (( skip_adopt == 0 )); then
        adopt_deployed_template || {
            log_error "Adoption failed"
            rc=1
            halt=1
        }
    fi

    # Spec 15: reconciliation is at the front so every later stage reads a
    # store that means what it says.
    if (( skip_reconcile == 0 && halt == 0 )); then
        maintain_clear_stale_promotion_pause

        if maintain_reconcile_two_actives; then
            maintain_reconcile_baking || {
                log_error "Failed to reconcile interrupted bakes"
                rc=1
                halt=1
            }
        else
            log_error "Failed to reconcile multiple active generations"
            rc=1
            halt=1
        fi
    fi

    # A GC that cannot run — most often because a manual bake or upgrade holds
    # the bake lock it waits on — must not silence the stages after it. The
    # failure lands in the cycle's exit status; the cycle carries on.
    if (( skip_gc == 0 && halt == 0 )); then
        gc_main false || {
            log_error "Generation garbage collection failed"
            rc=1
        }
    fi

    if (( skip_canary == 0 && halt == 0 )); then
        maintain_canary_stage || { rc=1; halt=1; }
    fi

    # A gate error means the store is in a state this cycle does not
    # understand. Baking on top of that would only add to it.
    if (( skip_bake == 0 && halt == 0 )); then
        if maintain_read_candidate; then
            before="$MAINTAIN_CANDIDATE_VMID"
            maintain_bake_stage "$before" || rc=1
            after=""
            if maintain_read_candidate; then
                after="$MAINTAIN_CANDIDATE_VMID"
            else
                log_error "Cannot read the generation store after the bake"
                rc=1
            fi
            # Acceptance: a stale generation goes bake -> canary -> promote in
            # one unattended cycle. Only a candidate this cycle produced is
            # re-gated; re-running the gate on the one it already saw would
            # double the work and the log lines for nothing.
            if (( skip_canary == 0 )) && [[ -n "$after" && "$after" != "$before" ]]; then
                log_info "gating the candidate this cycle baked"
                maintain_canary_stage || rc=1
            fi
        else
            log_error "Cannot read the generation store before the bake decision"
            rc=1
        fi
    fi

    if (( skip_drift == 0 )); then
        maintain_drift_stage
    fi

    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root maintain
    load_infra_config
    maintain_main "$@"
fi
