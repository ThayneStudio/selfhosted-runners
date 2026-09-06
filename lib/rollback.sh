#!/bin/bash
# Roll active back to the retained previous generation: exclusive pool lock,
# rewrite the TEMPLATE_ID pointer, reject the generation being left.
#
# Library: functions only at source time. Tests load_lib rollback.sh and call
# rollback_generation. When executed as the CLI (`BASH_SOURCE == $0`),
# require_root, load_infra_config, then rollback_generation. Do not require_root
# at source time.
#
# Reuses PROMOTION_PAUSE_FILE and exclusive POOL_ACTIVITY_LOCK_FILE (same
# starvation control as promote). --yes is for tests; an operator confirm
# requires a tty, like promote --skip-canary.
#
# GEN_* fields are loaded via gen_read in this shell; gen_transition is a
# subshell, so SC2030/SC2031 are false positives here as in generations.sh.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_ROLLBACK_LOADED:-}" ]]; then
    return 0
fi
RUNNER_ROLLBACK_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=generations.sh
source "$LIB_DIR/generations.sh"

rollback_usage() {
    echo "Usage: runner rollback [--reason <text>]"
}

_rollback_release() {
    # Drop the EXIT trap first so a later process EXIT cannot re-enter after
    # a normal release. Proven by "_rollback_release clears the EXIT trap".
    trap - EXIT
    exec 211>&- 2>/dev/null || true
    rm -f "$PROMOTION_PAUSE_FILE"
    exec 202>&- 2>/dev/null || true
}

# Superseded former actives demoted during the retained target's most recent
# reign as active — leftovers from a crash after the pointer moved, before
# reject (spec 15). Anchored to gen_rollback_target's own pick, not to
# <current-id> directly: a plain "GEN_ID above <current-id>" comparison stops
# seeing the leftover as soon as any later, unrelated promotion raises the
# active id past it (issue #19 review round 1) -- the retained target's own
# GEN_PROMOTED_AT does not move just because a later promotion happens, so a
# leftover demoted at or after it is found regardless of how many
# promotions have happened since. Strictly after, not at-or-after: an
# ordinary immediate predecessor is superseded in the very same instant the
# retained target was promoted (same promote_generation transaction), and
# must not be mistaken for a leftover. Falls back to <current-promoted>
# itself only when nothing is retained below <current-id> at all. Same
# eligibility test as GC and gen_rollback_target
# (gen_record_is_rollback_eligible), so there is exactly one definition of
# "was this ever a clone target". Never a rollback target itself (that would
# undo the rollback).
_rollback_leftover_vmids() (
    local current_id="${1:-}" current_promoted="${2:-}" vmid list sup anchor picked

    gen_is_uint "$current_id" || return 1
    picked=$(gen_rollback_target "$current_id" 2>/dev/null) || picked=""
    if [[ -n "$picked" ]]; then
        gen_read "$picked" || return 1
        # A legacy-adopted retained target (spec 8) was created directly in
        # active and never passed through gen_transition ... active, so it
        # has no GEN_PROMOTED_AT of its own -- fall back to <current-promoted>
        # rather than disabling leftover detection entirely (issue #19 review
        # round 2).
        anchor="${GEN_PROMOTED_AT:-$current_promoted}"
    else
        anchor="$current_promoted"
    fi
    [[ -n "$anchor" ]] || return 0

    list=$(gen_list superseded) || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        [[ "$vmid" != "$picked" ]] || continue
        gen_read "$vmid" || return 1
        gen_record_is_rollback_eligible || continue
        sup="${GEN_SUPERSEDED_AT:-}"
        [[ -n "$sup" ]] || continue
        # if/fi, not `[[ ... ]] && printf`: the loop body's exit status is the
        # function's own exit status (this is a subshell, not a caller-visible
        # `return`), so a false condition on the LAST record examined must not
        # make the whole scan look like a failure. gen_list sorts by VMID, and
        # allocate_generation_vmid hands out the lowest free one in the band,
        # so an old, still-blocked superseded generation routinely holds a
        # HIGHER VMID than the retained target -- this is not a rare ordering.
        # Proven by "an ordinary rollback succeeds when an older superseded
        # generation has a higher VMID than the retained target" (issue #19
        # review round 2).
        if [[ "$sup" > "$anchor" ]]; then
            printf '%s\n' "$vmid"
        fi
    done <<< "$list"
    return 0
)

_rollback_collect_vmids() {
    local list vmid
    list=$(gen_list "${1:-}") || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        printf '%s\n' "$vmid"
    done <<< "$list"
}

_rollback_confirm() {
    local prompt="$1" confirm=""

    if [[ ! -t 0 ]]; then
        log_error "Refusing rollback without confirmation (stdin is not a tty)"
        return 1
    fi
    read -rp "$prompt" confirm || return 1
    if [[ ! "${confirm:-}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        log_error "Rollback aborted"
        return 1
    fi
    return 0
}

# Usage: rollback_generation [--reason <text>] [--yes]
rollback_generation() {
    local yes=0 reason="" reason_set=0
    local pointer current_vmid current_id target="" target_id=""
    local leftover_list active_list vmid rc leftover_id="" plan="" lock_wait
    local current_promoted=""
    local -a leftovers=() actives=() rejected_ids=() rejected_vmids=()
    local restored_id restored_vmid confirm_prompt

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) yes=1; shift ;;
            --reason)
                if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
                    log_error "Missing value for --reason"
                    rollback_usage >&2
                    return 1
                fi
                reason="$2"
                reason_set=1
                shift 2
                ;;
            --reason=*)
                reason="${1#--reason=}"
                reason_set=1
                shift
                ;;
            -h|--help)
                rollback_usage
                return 0
                ;;
            --*)
                log_error "Unknown option: $1"
                rollback_usage >&2
                return 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                rollback_usage >&2
                return 1
                ;;
        esac
    done

    if [[ "$reason_set" -eq 1 && -z "$reason" ]]; then
        log_error "Rollback reason must not be empty"
        return 1
    fi
    [[ -n "$reason" ]] || reason="operator rollback"

    pointer=$(reload_active_template_id) || return 1
    if ! gen_exists "$pointer"; then
        log_error "TEMPLATE_ID $pointer is not a known generation"
        return 1
    fi
    gen_read "$pointer" || return 1
    if [[ "$GEN_STATE" != "active" ]]; then
        log_error "TEMPLATE_ID $pointer is $GEN_STATE, not active — refusing to rollback"
        return 1
    fi
    current_vmid="$pointer"
    current_id=$(gen_require_numeric_id "$current_vmid") || return 1
    current_promoted="${GEN_PROMOTED_AT:-}"

    active_list=$(_rollback_collect_vmids active) || return 1
    actives=()
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        actives+=("$vmid")
    done <<< "$active_list"
    if ((${#actives[@]} != 1)); then
        log_error "Refusing to rollback while ${#actives[@]} generations are active — run runner maintain"
        return 1
    fi
    if [[ "${actives[0]}" != "$current_vmid" ]]; then
        log_error "TEMPLATE_ID $current_vmid is not the active generation (VMID ${actives[0]}) — run runner maintain"
        return 1
    fi

    leftover_list=$(_rollback_leftover_vmids "$current_id" "$current_promoted") || {
        log_error "Could not scan for an incomplete prior rollback"
        return 1
    }
    leftovers=()
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        leftovers+=("$vmid")
    done <<< "$leftover_list"

    if ((${#leftovers[@]} == 0)); then
        target=$(gen_rollback_target "$current_id") || {
            log_error "Nothing retained to roll back to"
            return 1
        }
        if [[ "$target" == "$current_vmid" ]]; then
            log_error "Rollback target VMID $target is already the active pointer"
            return 1
        fi
        gen_read "$target" || return 1
        target_id=$(gen_require_numeric_id "$target") || return 1
        plan=rollback
        confirm_prompt="Roll back generation $current_id to generation $target_id? [y/N] "
    else
        plan=complete
        confirm_prompt="Reject leftover generation(s) ${leftovers[*]} (incomplete rollback)? [y/N] "
    fi

    if [[ "$yes" -eq 0 ]]; then
        # Without --yes or a tty confirm, abort. Proven by
        # "rollback without --yes on a non-tty fails".
        _rollback_confirm "$confirm_prompt" || return 1
    fi

    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")" "$(dirname "$POOL_ACTIVITY_LOCK_FILE")" || {
        log_error "Cannot create lock directory"
        return 1
    }
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
    # INT/TERM here: a handler that returns would let rollback continue
    # with pause and lock already dropped.
    # Proven by "rollback_generation traps EXIT to clear PROMOTION_PAUSE_FILE before flock waits".
    trap '_rollback_release' EXIT

    exec 202>"$POOL_ACTIVITY_LOCK_FILE" || {
        _rollback_release
        log_error "Cannot open $POOL_ACTIVITY_LOCK_FILE"
        return 1
    }
    lock_wait="${ROLLBACK_LOCK_WAIT_SECONDS:-120}"
    [[ "$lock_wait" =~ ^[0-9]+$ ]] || lock_wait=120
    if ! flock -w "$lock_wait" -x 202; then
        log_warn "Timed out waiting for the pool activity lock — rollback abandoned"
        _rollback_release
        notify warn rollback.timeout "Timed out waiting for the pool activity lock — rollback abandoned"
        return 1
    fi

    pointer=$(reload_active_template_id) || {
        _rollback_release
        return 1
    }
    gen_read "$pointer" || {
        _rollback_release
        return 1
    }
    if [[ "$GEN_STATE" != "active" ]]; then
        log_error "TEMPLATE_ID $pointer is $GEN_STATE, not active — refusing to rollback"
        _rollback_release
        return 1
    fi
    current_vmid="$pointer"
    current_id=$(gen_require_numeric_id "$current_vmid") || {
        _rollback_release
        return 1
    }
    current_promoted="${GEN_PROMOTED_AT:-}"

    active_list=$(_rollback_collect_vmids active) || {
        _rollback_release
        return 1
    }
    actives=()
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        actives+=("$vmid")
    done <<< "$active_list"
    if ((${#actives[@]} != 1)) || [[ "${actives[0]}" != "$current_vmid" ]]; then
        log_error "Active generation changed under the lock — refusing to rollback"
        _rollback_release
        return 1
    fi

    leftover_list=$(_rollback_leftover_vmids "$current_id" "$current_promoted") || {
        log_error "Could not scan for an incomplete prior rollback"
        _rollback_release
        return 1
    }
    leftovers=()
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        leftovers+=("$vmid")
    done <<< "$leftover_list"

    rejected_ids=()
    rejected_vmids=()

    if ((${#leftovers[@]} > 0)); then
        if [[ "$plan" != "complete" ]]; then
            log_error "Generation store changed under the lock — refusing to rollback"
            _rollback_release
            return 1
        fi
        for vmid in "${leftovers[@]}"; do
            gen_read "$vmid" || {
                _rollback_release
                return 1
            }
            leftover_id=$(gen_require_numeric_id "$vmid") || {
                _rollback_release
                return 1
            }
            rejected_ids+=("$leftover_id")
            rejected_vmids+=("$vmid")
            rc=0
            gen_transition "$vmid" rejected "$reason" || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                log_error "Failed to reject leftover VMID $vmid (exit $rc)"
                _rollback_release
                return 1
            fi
        done
        restored_vmid="$current_vmid"
        restored_id="$current_id"
    else
        if [[ "$plan" != "rollback" ]]; then
            log_error "Generation store changed under the lock — refusing to rollback"
            _rollback_release
            return 1
        fi
        target=$(gen_rollback_target "$current_id") || {
            log_error "Nothing retained to roll back to"
            _rollback_release
            return 1
        }
        gen_read "$target" || {
            _rollback_release
            return 1
        }
        target_id=$(gen_require_numeric_id "$target") || {
            _rollback_release
            return 1
        }

        # Record can say superseded after an out-of-band qm destroy. Never
        # rewrite TEMPLATE_ID onto a VM that is not a Proxmox template.
        # Proven by "rollback refuses a target that is not a Proxmox template".
        if ! qm config "$target" 2>/dev/null | grep -q '^template:[[:space:]]*1'; then
            log_error "Generation $target_id (VMID $target) is not a template in Proxmox — refusing to rollback"
            _rollback_release
            return 1
        fi

        # Promote-before-demote: a crash after this transition leaves two
        # actives (maintain reconciles), never zero. The loser is the higher
        # GEN_ID — never re-activated, because TEMPLATE_ID already names the
        # restored generation once rewrite_template_id succeeds.
        rc=0
        gen_transition "$target" active || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            log_error "Failed to mark generation $target_id active (exit $rc)"
            _rollback_release
            return 1
        fi

        if ! rewrite_template_id "$target"; then
            log_error "Generation $target_id is active but TEMPLATE_ID was not rewritten"
            _rollback_release
            return 1
        fi

        rc=0
        gen_transition "$current_vmid" rejected "$reason" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            log_error "Failed to reject generation $current_id (VMID $current_vmid) (exit $rc)"
            _rollback_release
            return 1
        fi
        restored_vmid="$target"
        restored_id="$target_id"
        rejected_ids+=("$current_id")
        rejected_vmids+=("$current_vmid")
    fi

    _rollback_release

    NOTIFY_GENERATION="$restored_id" notify info generation.rolled_back \
        "Rolled back to generation $restored_id (VMID $restored_vmid)" \
        "rejected generation ${rejected_ids[*]} (VMID ${rejected_vmids[*]}): $reason"
    log_info "Rolled back to generation $restored_id (VMID $restored_vmid)"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root rollback
    load_infra_config
    rollback_generation "$@"
fi
