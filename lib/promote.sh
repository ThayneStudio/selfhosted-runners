#!/bin/bash
# Promote a candidate generation to active: exclusive pool lock, rewrite the
# TEMPLATE_ID pointer, demote the previous active.
#
# Library: functions only at source time. Tests load_lib promote.sh and call
# promote_generation. When executed as the CLI (`BASH_SOURCE == $0`),
# require_root, load_infra_config, then promote_generation. Do not require_root
# at source time.
#
# --yes is for setup bootstrap, tests, and `runner upgrade` (an operator-invoked
# verb). It is not a way to bypass canary from unattended maintain.
#
# --canary-passed is the opposite of --skip-canary: it says the gate ran and
# the run concluded success, so there is nothing to confirm. lib/canary.sh is
# its only caller (proven by "only the canary gate passes --canary-passed"),
# and it is deliberately absent from promote_usage — an operator promoting by
# hand has --skip-canary, which asks.
#
# It is not a bare assertion: the flag is refused unless the generation record
# carries the evidence the gate writes — GEN_CANARY_RUN_URL and at least one
# GEN_CANARY_ATTEMPTS — so a hand-typed `runner promote <id> --canary-passed`
# cannot skip both the canary and the confirmation on a generation no canary
# ever ran against. Accepting it is notified at info, because a promotion that
# no human confirmed should still be visible.
# Proven by "promote --canary-passed refuses a generation with no recorded
# canary run" and "promote --canary-passed proceeds on a recorded canary run".
#
# GEN_* fields are loaded via gen_read in this shell; gen_transition is a
# subshell, so SC2030/SC2031 are false positives here as in generations.sh.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_PROMOTE_LOADED:-}" ]]; then
    return 0
fi
RUNNER_PROMOTE_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=generations.sh
source "$LIB_DIR/generations.sh"

promote_usage() {
    echo "Usage: runner promote <generation-id> [--skip-canary]"
}

_promote_release() {
    # Drop the EXIT trap first so a later process EXIT cannot re-enter after
    # a normal release. Proven by "_promote_release clears the EXIT trap".
    trap - EXIT
    exec 211>&- 2>/dev/null || true
    rm -f "$PROMOTION_PAUSE_FILE"
    exec 202>&- 2>/dev/null || true
}

# Usage: promote_generation <gen_id> [--skip-canary] [--yes] [--canary-passed]
promote_generation() {
    local gen_id="" skip_canary=0 yes=0 canary_passed=0
    local new_vmid state rc confirm="" pointer="" prev_list
    local -a previous=()
    local prev

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-canary) skip_canary=1; shift ;;
            --yes) yes=1; shift ;;
            --canary-passed) canary_passed=1; shift ;;
            -h|--help)
                promote_usage
                return 0
                ;;
            --*)
                log_error "Unknown option: $1"
                promote_usage >&2
                return 1
                ;;
            *)
                if [[ -n "$gen_id" ]]; then
                    log_error "Unexpected argument: $1"
                    promote_usage >&2
                    return 1
                fi
                gen_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$gen_id" ]]; then
        log_error "Missing generation id"
        promote_usage >&2
        return 1
    fi

    new_vmid=$(gen_vmid_for_id "$gen_id") || return 1
    gen_read "$new_vmid" || return 1
    state="$GEN_STATE"

    if [[ "$state" == "active" ]]; then
        # Pointer may still name the previous VMID after a crash between
        # gen_transition active and rewrite_template_id. Only no-op when
        # record and pointer already agree.
        pointer=$(reload_active_template_id) || return 1
        if [[ "$pointer" == "$new_vmid" ]]; then
            log_info "Generation $gen_id is already active"
            return 0
        fi
    elif [[ "$state" != "candidate" ]]; then
        log_error "Generation $gen_id is $state, not candidate — refusing to promote"
        return 1
    fi

    if [[ "$skip_canary" -eq 0 && "$canary_passed" -eq 0 ]]; then
        log_error "Generation $gen_id has not passed a canary — run 'runner canary $gen_id', or pass --skip-canary to promote without one"
        return 1
    fi
    if [[ "$canary_passed" -eq 1 && "$skip_canary" -eq 0 ]]; then
        # GEN_* are in scope from the gen_read above.
        if [[ -z "${GEN_CANARY_RUN_URL:-}" ]] || [[ ! "${GEN_CANARY_ATTEMPTS:-0}" =~ ^[1-9][0-9]*$ ]]; then
            log_error "Generation $gen_id carries no canary evidence (GEN_CANARY_RUN_URL='${GEN_CANARY_RUN_URL:-}', GEN_CANARY_ATTEMPTS='${GEN_CANARY_ATTEMPTS:-}') — refusing --canary-passed; run 'runner canary $gen_id'"
            return 1
        fi
        NOTIFY_GENERATION="$gen_id" notify info promote.canary_passed \
            "Promoting generation $gen_id on a passed canary (attempt ${GEN_CANARY_ATTEMPTS})" \
            "run ${GEN_CANARY_RUN_URL}"
    fi
    # The canary gate is the confirmation: it just watched a real job succeed
    # on this image, so there is no question to ask an operator.
    if [[ "$skip_canary" -eq 1 && "$yes" -eq 0 ]]; then
        # --skip-canary without --yes or a tty confirm aborts. Proven by
        # "promote --skip-canary without --yes on a non-tty fails".
        if [[ ! -t 0 ]]; then
            log_error "Refusing --skip-canary without confirmation (stdin is not a tty)"
            return 1
        fi
        read -rp "Promote generation $gen_id without a canary? [y/N] " confirm || return 1
        if [[ ! "${confirm:-}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            log_error "Promotion aborted"
            return 1
        fi
    fi

    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")" "$(dirname "$POOL_ACTIVITY_LOCK_FILE")" || {
        log_error "Cannot create lock directory"
        return 1
    }
    # fd 211: exclusive flock on the pause file itself. maintain used to treat
    # "exclusive 202 is free" as stale, which is true while this process is
    # still in flock -w 202. Proven by "promotion pause is left when the pause
    # file is flocked".
    exec 211>"$PROMOTION_PAUSE_FILE" || {
        log_error "Failed to write $PROMOTION_PAUSE_FILE"
        return 1
    }
    if ! flock -n 211; then
        exec 211>&- 2>/dev/null || true
        log_error "Another promotion already holds $PROMOTION_PAUSE_FILE"
        return 1
    fi
    # Ctrl-C / SIGTERM abort the process; EXIT still runs. Do not trap
    # INT/TERM here: a handler that returns would let promote continue
    # with pause and lock already dropped.
    # Proven by "promote_generation traps EXIT to clear PROMOTION_PAUSE_FILE before flock waits".
    trap '_promote_release' EXIT

    exec 202>"$POOL_ACTIVITY_LOCK_FILE" || {
        _promote_release
        log_error "Cannot open $POOL_ACTIVITY_LOCK_FILE"
        return 1
    }
    local lock_wait="${PROMOTE_LOCK_WAIT_SECONDS:-120}"
    [[ "$lock_wait" =~ ^[0-9]+$ ]] || lock_wait=120
    if ! flock -w "$lock_wait" -x 202; then
        log_warn "Timed out waiting for the pool activity lock — promotion abandoned"
        _promote_release
        notify warn promote.timeout "Timed out waiting for the pool activity lock — promotion abandoned"
        return 1
    fi

    gen_read "$new_vmid" || {
        _promote_release
        return 1
    }
    if [[ "$GEN_STATE" == "active" ]]; then
        pointer=$(reload_active_template_id) || {
            _promote_release
            return 1
        }
        if [[ "$pointer" == "$new_vmid" ]]; then
            log_info "Generation $gen_id is already active"
            _promote_release
            return 0
        fi
    elif [[ "$GEN_STATE" != "candidate" ]]; then
        log_error "Generation $gen_id is $GEN_STATE, not candidate — refusing to promote"
        _promote_release
        return 1
    fi

    # Record can say candidate/active after an out-of-band qm destroy. Never
    # rewrite TEMPLATE_ID onto a VM that is not a Proxmox template.
    # Proven by "promote refuses a VMID that is not a Proxmox template".
    if ! qm config "$new_vmid" 2>/dev/null | grep -q '^template:[[:space:]]*1'; then
        log_error "Generation $gen_id (VMID $new_vmid) is not a template in Proxmox — refusing to promote"
        _promote_release
        return 1
    fi

    previous=()
    prev_list=$(gen_list active) || {
        log_error "Failed to list active generations"
        _promote_release
        return 1
    }
    while read -r prev; do
        [[ -n "$prev" && "$prev" != "$new_vmid" ]] || continue
        previous+=("$prev")
    done <<< "$prev_list"

    # Promote-before-demote: a crash after this transition leaves two actives
    # (Task 8 reconciles), never zero. Distinguish gen_transition code 4 (write
    # failed) from 1 (refused) so TEMPLATE_ID is not rewritten on a refusal.
    # Already-active with a stale pointer skips the transition and still
    # rewrites TEMPLATE_ID below.
    if [[ "$GEN_STATE" != "active" ]]; then
        rc=0
        gen_transition "$new_vmid" active || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            log_error "Failed to mark generation $gen_id active (exit $rc)"
            _promote_release
            return 1
        fi
    fi

    if ! rewrite_template_id "$new_vmid"; then
        log_error "Generation $gen_id is active but TEMPLATE_ID was not rewritten"
        _promote_release
        return 1
    fi

    if ((${#previous[@]} > 0)); then
        for prev in "${previous[@]}"; do
            rc=0
            gen_transition "$prev" superseded || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                log_error "Failed to supersede previous active VMID $prev (exit $rc)"
                _promote_release
                return 1
            fi
        done
    fi

    _promote_release

    NOTIFY_GENERATION="$gen_id" notify info generation.promoted \
        "Promoted generation $gen_id (VMID $new_vmid) to active"
    log_info "Generation $gen_id is now active (VMID $new_vmid)"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root promote
    load_infra_config
    promote_generation "$@"
fi
