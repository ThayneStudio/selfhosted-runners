#!/bin/bash
# Unattended maintain cycle: adopt, reconcile, detect, maybe bake.
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

# True (0) when local time is inside REBAKE_WINDOW (HH:MM-HH:MM, inclusive).
# Invalid window, wrap-past-midnight, or an unreadable clock → log_error and
# return 1 (outside): fail closed for bake starts. v1 does not wrap midnight.
in_rebake_window() {
    local window now
    local sh sm eh em nh nm
    local start_min end_min now_min

    apply_generation_defaults
    window="${REBAKE_WINDOW:-}"
    window="${window//[[:space:]]/}"

    if [[ ! "$window" =~ ^([0-9]{2}):([0-9]{2})-([0-9]{2}):([0-9]{2})$ ]]; then
        log_error "Invalid REBAKE_WINDOW '${REBAKE_WINDOW:-<empty>}' (expected HH:MM-HH:MM)"
        return 1
    fi
    sh="${BASH_REMATCH[1]}"
    sm="${BASH_REMATCH[2]}"
    eh="${BASH_REMATCH[3]}"
    em="${BASH_REMATCH[4]}"

    if ((10#$sh > 23 || 10#$eh > 23 || 10#$sm > 59 || 10#$em > 59)); then
        log_error "Invalid REBAKE_WINDOW '$window' (hour/minute out of range)"
        return 1
    fi

    start_min=$((10#$sh * 60 + 10#$sm))
    end_min=$((10#$eh * 60 + 10#$em))
    if ((start_min > end_min)); then
        log_error "Invalid REBAKE_WINDOW '$window' (wrap-past-midnight is not supported)"
        return 1
    fi
    if ((start_min == end_min)); then
        log_error "Invalid REBAKE_WINDOW '$window' (zero-width window)"
        return 1
    fi

    if [[ -n "${MAINTAIN_NOW_HHMM:-}" ]]; then
        now="$MAINTAIN_NOW_HHMM"
    else
        now=$(date +%H:%M) || {
            log_error "Failed to read local time for REBAKE_WINDOW"
            return 1
        }
    fi
    now="${now//[[:space:]]/}"
    if [[ ! "$now" =~ ^([0-9]{2}):([0-9]{2})$ ]]; then
        log_error "Invalid clock value for rebake window: ${now:-<empty>}"
        return 1
    fi
    nh="${BASH_REMATCH[1]}"
    nm="${BASH_REMATCH[2]}"
    if ((10#$nh > 23 || 10#$nm > 59)); then
        log_error "Invalid clock value for rebake window: $now"
        return 1
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
    local digest="" gen_id=""
    local reason="host reboot or interrupted bake"

    gen_read "$vmid" || return 1
    digest="${GEN_TEMPLATE_DIGEST:-}"
    gen_id="${GEN_ID:-}"

    if [[ "$vmid" == "${TEMPLATE_ID:-}" ]]; then
        log_error "Refusing to destroy TEMPLATE_ID $TEMPLATE_ID on dead-bake reconcile"
    else
        if qm status "$vmid" >/dev/null 2>&1; then
            # Proxmox refuses destroy of a running VM. Match bake_fail: stop
            # then destroy. Proven by "dead baking record with free bake lock
            # is failed and the VM destroyed".
            qm stop "$vmid" --timeout 30 2>/dev/null || true
            if ! qm destroy "$vmid" --purge; then
                log_error "Failed to destroy interrupted-bake VM $vmid"
            fi
        fi
        # Config can be gone after a reboot while vm-${vmid}-disk-* remains.
        # Proven by "dead baking with no VM still frees leftover volumes".
        bake_free_vmid_volumes "$vmid"
    fi

    gen_transition "$vmid" failed "$reason" || true
    if [[ -n "$digest" && "$digest" != "unknown" ]]; then
        memo_failed_digest "$digest" || true
    fi
    NOTIFY_GENERATION="$gen_id" notify error bake.failed "$reason"
    return 0
}

# If BAKE_LOCK_FILE is taken, a live bake owns these records — leave them.
# Proven by "baking record is left alone when the bake lock is held".
# fd 208: 207 is bake_main's exclusive lock.
maintain_reconcile_baking() {
    local vmid
    local -a baking=()

    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        baking+=("$vmid")
    done < <(gen_list baking)
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

# Split-brain active records: TEMPLATE_ID wins; if that is ambiguous, newest
# GEN_PROMOTED_AT. Never the highest GEN_ID. Proven by "two actives:
# TEMPLATE_ID wins, not the higher GEN_ID".
maintain_reconcile_two_actives() {
    local vmid keep="" best_ts="" ts
    local -a actives=()
    local -a losers=()

    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        actives+=("$vmid")
    done < <(gen_list active)
    ((${#actives[@]} > 1)) || return 0

    for vmid in "${actives[@]}"; do
        if [[ -n "${TEMPLATE_ID:-}" && "$vmid" == "$TEMPLATE_ID" ]]; then
            keep="$vmid"
            break
        fi
    done

    if [[ -z "$keep" ]]; then
        for vmid in "${actives[@]}"; do
            gen_read "$vmid" || return 1
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
    [[ -n "$keep" ]] || return 1

    for vmid in "${actives[@]}"; do
        [[ "$vmid" != "$keep" ]] || continue
        losers+=("$vmid")
        gen_transition "$vmid" superseded || return 1
    done
    ((${#losers[@]} > 0)) || return 0

    notify warn generation.reconciled \
        "Multiple active generations; kept VMID $keep" \
        "demoted ${losers[*]} to superseded"
    log_warn "Reconciled $((${#actives[@]})) active generations; kept VMID $keep"
    return 0
}

_canary_repo_configured() {
    local repo="${CANARY_REPO:-}"
    repo="${repo//[[:space:]]/}"
    [[ -n "$repo" ]]
}

# Ordered cycle. Does not canary, promote, or GC. bake_main is not --force.
maintain_main() {
    local decision

    apply_generation_defaults

    adopt_deployed_template || {
        log_error "Adoption failed"
        return 1
    }

    maintain_reconcile_two_actives || {
        log_error "Failed to reconcile multiple active generations"
        return 1
    }
    maintain_reconcile_baking || {
        log_error "Failed to reconcile interrupted bakes"
        return 1
    }

    decision=$(detect_should_bake) || {
        log_error "detect_should_bake failed"
        return 1
    }
    case "$decision" in
        yes\ *)
            log_info "bake needed: ${decision#yes }"
            if ! in_rebake_window; then
                log_info "deferring bake until REBAKE_WINDOW"
                return 0
            fi
            if [[ "${REBAKE_ENABLED}" != "true" ]]; then
                log_info "nothing to do: rebake-disabled"
                return 0
            fi
            if [[ "${CANARY_ENABLED}" == "true" ]] && ! _canary_repo_configured; then
                notify warn canary.unconfigured \
                    "CANARY_ENABLED=true but CANARY_REPO is empty — refusing to bake"
                log_warn "Refusing to start a bake: CANARY_ENABLED=true but CANARY_REPO is empty"
                return 0
            fi
            bake_main
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root maintain
    load_infra_config
    maintain_main "$@"
fi
