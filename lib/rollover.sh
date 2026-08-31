#!/bin/bash
# Report and optionally recycle clones that still belong to a non-active
# generation. Destruction is deliberately fail-closed: the VM's identity,
# maintenance flag, per-org serving capacity, and GitHub busy state are all
# checked again immediately before deregistration.
set -euo pipefail

if [[ -n "${RUNNER_ROLLOVER_LOADED:-}" ]]; then
    return 0
fi
RUNNER_ROLLOVER_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=generations.sh
source "$LIB_DIR/generations.sh"

ROLLOVER_DESTROY_DELAY_SECONDS="${ROLLOVER_DESTROY_DELAY_SECONDS:-10}"

rollover_usage() {
    echo "Usage: runner rollover [--force]"
}

rollover_age() {
    local vmid="$1" path mtime now age days hours minutes
    path=$(vm_config_path "$vmid") || true
    [[ -n "$path" ]] || { printf '%s\n' unknown; return; }
    mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) || {
        printf '%s\n' unknown
        return
    }
    [[ "$mtime" =~ ^[0-9]+$ ]] || { printf '%s\n' unknown; return; }
    now=$(date +%s)
    [[ "$now" -ge "$mtime" ]] || { printf '%s\n' unknown; return; }
    age=$((now - mtime))
    days=$((age / 86400)); hours=$(((age % 86400) / 3600)); minutes=$(((age % 3600) / 60))
    if [[ "$days" -gt 0 ]]; then printf '%sd%sh\n' "$days" "$hours"
    elif [[ "$hours" -gt 0 ]]; then printf '%sh%sm\n' "$hours" "$minutes"
    else printf '%sm\n' "$minutes"
    fi
}

rollover_cfg_org() {
    local cfg="$1"
    if [[ "$cfg" =~ runner-user-data-([^.]+)\.yaml ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

# NAME|VMID|GEN|ORG|STATUS|AGE. A tagged VM is considered only when its
# cloud-init snippet proves it is managed by this installation.
rollover_collect() {
    local active_id="$1" all_vms vmid name status cfg org gen age
    all_vms=$(qm list 2>/dev/null </dev/null) || {
        log_error "rollover: failed to list VMs"
        return 1
    }
    while read -r vmid name status _; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        [[ "$vmid" != "${TEMPLATE_ID:-}" ]] || continue
        cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || {
            log_warn "rollover: could not read VMID $vmid — skipping"
            continue
        }
        grep -q '^template:[[:space:]]*1' <<< "$cfg" && continue
        org=$(rollover_cfg_org "$cfg") || continue
        gen=$(generation_id_from_tags "$(grep -m1 '^tags:' <<< "$cfg" || true)") || continue
        [[ "$gen" -ne "$active_id" ]] || continue
        age=$(rollover_age "$vmid")
        printf '%s|%s|%s|%s|%s|%s\n' "$name" "$vmid" "$gen" "$org" "$status" "$age"
    done <<< "$all_vms"
}

rollover_busy() {
    local org="$1" name="$2" lookup _id busy
    lookup=$(github_runner_lookup "$org" "$name") || { printf '%s\n' unknown; return 1; }
    IFS=$'\t' read -r _id busy <<< "$lookup"
    printf '%s\n' "$busy"
}

# Re-inventory current running managed clones for one org. Failure returns
# non-zero, never a misleading zero that could authorize a destroy.
rollover_serving_count() {
    local target="$1" all_vms vmid _name status cfg org count=0
    all_vms=$(qm list 2>/dev/null </dev/null) || return 1
    while read -r vmid _name status _; do
        [[ "$vmid" =~ ^[0-9]+$ && "$status" == running ]] || continue
        [[ "$vmid" != "${TEMPLATE_ID:-}" ]] || continue
        cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || return 1
        grep -q '^template:[[:space:]]*1' <<< "$cfg" && continue
        org=$(rollover_cfg_org "$cfg") || continue
        [[ "$org" == "$target" ]] && count=$((count + 1))
    done <<< "$all_vms"
    printf '%s\n' "$count"
}

rollover_release_slot() {
    exec 210>&- 2>/dev/null || true
}

rollover_destroy_vm() {
    "$LIB_DIR/destroy.sh" --vmid "$1" --skip-deregister \
        </dev/null 200>&- 201>&- 202>&- 203>&- 204>&-
}

# Returns 0 destroyed, 2 safely skipped, 1 actual destroy failure.
rollover_destroy_one() {
    local name="$1" vmid="$2" expected_gen="$3" org="$4"
    local cfg current_name current_org current_gen status serving lookup runner_id busy

    if pool_is_draining; then
        log_error "rollover: maintenance mode became active — stopping"
        return 2
    fi

    exec 210>"${RUNNER_SLOT_LOCK_PREFIX}-${name}.lock"
    if ! flock -n 210; then
        rollover_release_slot
        log_info "rollover: skipping $name — its slot is busy"
        return 2
    fi

    cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || {
        rollover_release_slot
        log_info "rollover: skipping $name — VMID $vmid disappeared"
        return 2
    }
    current_name=$(awk '/^name:/{print $2; exit}' <<< "$cfg")
    current_org=$(rollover_cfg_org "$cfg" || true)
    current_gen=$(generation_id_from_tags "$(grep -m1 '^tags:' <<< "$cfg" || true)" || true)
    if [[ "$current_name" != "$name" || "$current_org" != "$org" || "$current_gen" != "$expected_gen" ]]; then
        rollover_release_slot
        log_warn "rollover: skipping $name — VM identity or generation changed"
        return 2
    fi

    status=$(qm status "$vmid" 2>/dev/null </dev/null | awk '{print $2}') || {
        rollover_release_slot
        log_warn "rollover: skipping $name — status is uncertain"
        return 2
    }
    [[ -n "$status" ]] || { rollover_release_slot; return 2; }
    if [[ "$status" == running ]]; then
        serving=$(rollover_serving_count "$org") || {
            rollover_release_slot
            log_warn "rollover: skipping $name — could not verify serving capacity for $org"
            return 2
        }
        if [[ "$serving" -le 1 ]]; then
            rollover_release_slot
            log_info "rollover: skipping $name — it is the last running runner for $org"
            return 2
        fi
    fi

    # This is the safety-critical busy re-check. Nothing that may wait happens
    # between it and deregistration.
    lookup=$(github_runner_lookup "$org" "$name") || {
        rollover_release_slot
        log_warn "rollover: skipping $name — GitHub busy state is uncertain"
        return 2
    }
    IFS=$'\t' read -r runner_id busy <<< "$lookup"
    if [[ "$busy" != false ]]; then
        rollover_release_slot
        log_info "rollover: skipping $name — GitHub reports busy"
        return 2
    fi
    if ! github_runner_deregister_id "$org" "$runner_id"; then
        rollover_release_slot
        log_warn "rollover: skipping $name — GitHub deregistration failed"
        return 2
    fi

    if ! rollover_destroy_vm "$vmid"; then
        rollover_release_slot
        log_error "rollover: failed to destroy $name (VMID $vmid)"
        return 1
    fi
    rollover_release_slot
    log_info "rollover: destroyed idle old-generation runner $name (VMID $vmid, gen-$expected_gen)"
    return 0
}

rollover_main() {
    local force=false active_id active_state candidates name vmid gen org status age busy rc
    local destroyed=0 skipped=0 failed=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            -h|--help) rollover_usage; return 0 ;;
            *) log_error "Unknown option: $1"; rollover_usage >&2; return 1 ;;
        esac
    done
    if pool_is_draining; then
        log_error "Runner pool is stopped for maintenance. Run 'runner start' before rollover."
        return 1
    fi
    if [[ ! "$ROLLOVER_DESTROY_DELAY_SECONDS" =~ ^[0-9]+$ ]]; then
        log_error "ROLLOVER_DESTROY_DELAY_SECONDS must be a non-negative integer"
        return 1
    fi

    gen_read "$TEMPLATE_ID" || { log_error "Active generation record is unavailable"; return 1; }
    active_id=$(gen_require_numeric_id "$TEMPLATE_ID") || return 1
    # gen_read assigns through printf -v in this shell. The command substitution
    # above only formats the already-loaded numeric id; it cannot undo that
    # assignment, despite ShellCheck's conservative cross-function warning.
    # shellcheck disable=SC2031
    active_state="$GEN_STATE"
    if [[ "$active_state" != active ]]; then
        log_error "Generation $active_id at TEMPLATE_ID $TEMPLATE_ID is $active_state, not active"
        return 1
    fi
    candidates=$(rollover_collect "$active_id") || return 1

    printf '%-25s %-8s %-10s %-15s %-10s %-8s\n' NAME VMID GENERATION ORG AGE BUSY
    printf '%-25s %-8s %-10s %-15s %-10s %-8s\n' '----' '----' '----------' '---' '---' '----'
    while IFS='|' read -r name vmid gen org status age; do
        [[ -n "$name" ]] || continue
        busy=$(rollover_busy "$org" "$name") || true
        printf '%-25s %-8s %-10s %-15s %-10s %-8s\n' "$name" "$vmid" "gen-$gen" "$org" "$age" "$busy"
    done <<< "$candidates"

    [[ -n "$candidates" ]] || { echo "(no old-generation runners)"; return 0; }
    [[ "$force" == true ]] || return 0

    while IFS='|' read -r name vmid gen org status age; do
        [[ -n "$name" ]] || continue
        # Initial report state is advisory only; rollover_destroy_one always
        # gets a fresh authoritative answer.
        rc=0
        rollover_destroy_one "$name" "$vmid" "$gen" "$org" || rc=$?
        case "$rc" in
            0)
                destroyed=$((destroyed + 1))
                [[ "$ROLLOVER_DESTROY_DELAY_SECONDS" -eq 0 ]] || sleep "$ROLLOVER_DESTROY_DELAY_SECONDS"
                ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
        if pool_is_draining; then
            log_warn "rollover: maintenance mode is active; leaving remaining runners untouched"
            break
        fi
    done <<< "$candidates"
    log_info "rollover: destroyed $destroyed, skipped $skipped, failed $failed"
    [[ "$failed" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root rollover
    [[ -f "$CONFIG_FILE" ]] || { log_error "Runner host is not configured"; exit 1; }
    load_infra_config
    rollover_main "$@"
fi
