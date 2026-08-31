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
ROLLOVER_OFFLINE_TIMEOUT_SECONDS="${ROLLOVER_OFFLINE_TIMEOUT_SECONDS:-90}"
ROLLOVER_OFFLINE_POLL_SECONDS="${ROLLOVER_OFFLINE_POLL_SECONDS:-3}"
ROLLOVER_REPLACEMENT_WAIT_SECONDS="${ROLLOVER_REPLACEMENT_WAIT_SECONDS:-120}"

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
    local cfg="$1" org
    if [[ "$cfg" =~ runner-user-data-([^.]+)\.yaml ]]; then
        org="${BASH_REMATCH[1]}"
        validate_org_name "$org" || return 1
        printf '%s\n' "$org"
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
    local org="$1" name="$2" lookup _id busy _status
    lookup=$(github_runner_lookup_details "$org" "$name") || { printf '%s\n' unknown; return 1; }
    IFS=$'\t' read -r _id busy _status <<< "$lookup"
    printf '%s\n' "$busy"
}

# Re-inventory current running managed clones for one org. Failure returns
# non-zero, never a misleading zero that could authorize a destroy.
rollover_serving_count() {
    local target="$1" exclude_name="${2:-}" all_vms vmid _listed_name name status cfg org tags details _id _busy gh_status count=0
    all_vms=$(qm list 2>/dev/null </dev/null) || return 1
    while read -r vmid _listed_name status _; do
        [[ "$vmid" =~ ^[0-9]+$ && "$status" == running ]] || continue
        [[ "$vmid" != "${TEMPLATE_ID:-}" ]] || continue
        cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || return 1
        grep -q '^template:[[:space:]]*1' <<< "$cfg" && continue
        name=$(awk '/^name:/{print $2; exit}' <<< "$cfg")
        [[ -n "$name" ]] || return 1
        tags=$(grep -m1 '^tags:' <<< "$cfg" || true)
        [[ "$tags" != *runner-retired* ]] || continue
        org=$(rollover_cfg_org "$cfg") || continue
        [[ "$org" == "$target" && "$name" != "$exclude_name" ]] || continue
        details=$(github_runner_lookup_details "$org" "$name") || return 1
        IFS=$'\t' read -r _id _busy gh_status <<< "$details"
        [[ "$gh_status" == online ]] && count=$((count + 1))
    done <<< "$all_vms"
    printf '%s\n' "$count"
}

rollover_release_locks() {
    exec 212>&- 2>/dev/null || true
    exec 210>&- 2>/dev/null || true
    exec 209>&- 2>/dev/null || true
}

rollover_destroy_vm() {
    "$LIB_DIR/destroy.sh" --vmid "$1" --skip-deregister \
        </dev/null 200>&- 201>&- 202>&- 203>&- 204>&-
}

# Freeze the runner service cgroup before inspecting it. Once cgroup.freeze is
# acknowledged, Listener cannot accept another assignment. Busy/error paths
# thaw themselves; success deliberately leaves the guest frozen.
rollover_quiesce_guest() {
    local vmid="$1" result
    # shellcheck disable=SC2016  # guest-side program must expand in the guest
    result=$(qm guest exec "$vmid" -- /bin/bash -c '
set -eu
units=$(systemctl list-units --type=service --all --no-legend "actions.runner.*.service" | awk "{print \$1}")
[ "$(printf "%s\n" "$units" | sed "/^$/d" | wc -l)" -eq 1 ] || { echo ERROR; exit 1; }
unit=$units
cg=$(systemctl show -p ControlGroup --value "$unit")
[ -n "$cg" ] && [ -w "/sys/fs/cgroup${cg}/cgroup.freeze" ] || { echo ERROR; exit 1; }
thaw() { echo 0 > "/sys/fs/cgroup${cg}/cgroup.freeze" 2>/dev/null || true; }
trap thaw EXIT
echo 1 > "/sys/fs/cgroup${cg}/cgroup.freeze"
i=0
while ! grep -q "^frozen 1$" "/sys/fs/cgroup${cg}/cgroup.events"; do
    i=$((i + 1)); [ "$i" -lt 50 ] || { echo ERROR; exit 1; }
    sleep 0.1
done
for pid in $(cat "/sys/fs/cgroup${cg}/cgroup.procs"); do
    comm=$(cat "/proc/${pid}/comm" 2>/dev/null || true)
    case "$comm" in Runner.Worker*) thaw; echo BUSY; exit 20;; esac
done
trap - EXIT
echo QUIESCED
' 2>/dev/null </dev/null) || {
        [[ "$result" == *BUSY* ]] && return 2
        return 1
    }
    [[ "$result" == *QUIESCED* ]] || return 1
}

rollover_resume_guest() {
    local vmid="$1"
    # shellcheck disable=SC2016  # guest-side program must expand in the guest
    qm guest exec "$vmid" -- /bin/bash -c '
set -eu
units=$(systemctl list-units --type=service --all --no-legend "actions.runner.*.service" | awk "{print \$1}")
[ "$(printf "%s\n" "$units" | sed "/^$/d" | wc -l)" -eq 1
cg=$(systemctl show -p ControlGroup --value "$units")
[ -n "$cg" ]
echo 0 > "/sys/fs/cgroup${cg}/cgroup.freeze"
' >/dev/null 2>&1
}

# Wait for GitHub to acknowledge the already-frozen listener as offline. A job
# assigned just before the freeze will remain busy and is never destroyed.
rollover_wait_offline_idle() {
    local org="$1" name="$2" deadline now details id busy status
    deadline=$(($(date +%s) + ROLLOVER_OFFLINE_TIMEOUT_SECONDS))
    while :; do
        details=$(github_runner_lookup_details "$org" "$name") || return 1
        IFS=$'\t' read -r id busy status <<< "$details"
        if [[ "$status" == offline ]]; then
            [[ "$busy" == false ]] || return 2
            printf '%s\n' "$id"
            return 0
        fi
        now=$(date +%s)
        (( now < deadline )) || return 1
        sleep "$ROLLOVER_OFFLINE_POLL_SECONDS"
    done
}

# Deregistration is irreversible for this ephemeral runner. If its VM cannot
# be destroyed, quarantine the frozen residual under a non-slot name/tag so
# the watcher can refill the original slot. Keeping gen-N blocks unsafe GC.
rollover_quarantine_vm() {
    local vmid="$1" gen="$2"
    qm set "$vmid" --name "retired-rollover-${vmid}" \
        200>&- 209>&- 210>&- 212>&- </dev/null >/dev/null 2>&1 || return 1
    qm set "$vmid" --tags "runner-retired,gen-${gen}" \
        200>&- 209>&- 210>&- 212>&- </dev/null >/dev/null 2>&1 || true
}

# Returns 0 destroyed, 2 safely skipped, 3 deferred for replacement capacity,
# 4 destroy failed but slot was quarantined/opened, 1 unrecovered failure.
rollover_destroy_one() {
    local name="$1" vmid="$2" expected_gen="$3" org="$4"
    local cfg current_name current_org current_gen status serving runner_id quiesce_rc wait_rc

    if pool_is_draining; then
        log_error "rollover: maintenance mode became active — stopping"
        return 2
    fi

    exec 209>"${ROLLOVER_ORG_LOCK_PREFIX}-${org}.lock"
    flock 209
    exec 210>"${RUNNER_SLOT_LOCK_PREFIX}-${name}.lock"
    if ! flock -n 210; then
        rollover_release_locks
        log_info "rollover: skipping $name — its slot is busy"
        return 2
    fi

    cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || {
        rollover_release_locks
        log_info "rollover: skipping $name — VMID $vmid disappeared"
        return 2
    }
    current_name=$(awk '/^name:/{print $2; exit}' <<< "$cfg")
    current_org=$(rollover_cfg_org "$cfg" || true)
    current_gen=$(generation_id_from_tags "$(grep -m1 '^tags:' <<< "$cfg" || true)" || true)
    if [[ "$current_name" != "$name" || "$current_org" != "$org" || "$current_gen" != "$expected_gen" ]]; then
        rollover_release_locks
        log_warn "rollover: skipping $name — VM identity or generation changed"
        return 2
    fi

    status=$(qm status "$vmid" 2>/dev/null </dev/null | awk '{print $2}') || {
        rollover_release_locks
        log_warn "rollover: skipping $name — status is uncertain"
        return 2
    }
    [[ -n "$status" ]] || { rollover_release_locks; return 2; }

    serving=$(rollover_serving_count "$org" "$name") || {
        rollover_release_locks
        log_warn "rollover: skipping $name — could not verify online replacement capacity for $org"
        return 2
    }
    if [[ "$serving" -lt 1 ]]; then
        rollover_release_locks
        log_info "rollover: deferring $name — no other GitHub-online runner serves $org"
        return 3
    fi

    # Shared drain coordination makes this check atomic with maintenance entry:
    # either maintenance published its flag first, or this transaction finishes
    # before enable_pool_drain can publish it.
    exec 212>"$POOL_DRAIN_COORD_LOCK_FILE"
    flock -s 212
    if pool_is_draining; then
        rollover_release_locks
        log_error "rollover: maintenance mode became active — stopping"
        return 2
    fi

    quiesce_rc=0
    rollover_quiesce_guest "$vmid" || quiesce_rc=$?
    if [[ "$quiesce_rc" -ne 0 ]]; then
        rollover_resume_guest "$vmid" || log_error "rollover: failed to resume $name after an uncertain quiesce"
        rollover_release_locks
        if [[ "$quiesce_rc" -eq 2 ]]; then
            log_info "rollover: skipping $name — guest reports an active Runner.Worker"
        else
            log_warn "rollover: skipping $name — could not prove guest quiescence"
        fi
        return 2
    fi

    wait_rc=0
    runner_id=$(rollover_wait_offline_idle "$org" "$name") || wait_rc=$?
    if [[ "$wait_rc" -ne 0 ]]; then
        rollover_resume_guest "$vmid" || log_error "rollover: failed to resume $name after quiesce"
        rollover_release_locks
        if [[ "$wait_rc" -eq 2 ]]; then
            log_info "rollover: skipping $name — GitHub reports an assignment after quiesce"
        else
            log_warn "rollover: skipping $name — GitHub did not acknowledge safe offline state"
        fi
        return 2
    fi

    # Quiescence can take up to the GitHub offline timeout. Re-inventory under
    # the org lock after that wait so a replacement that completed its own job
    # in the meantime cannot disappear unnoticed before this DELETE.
    serving=$(rollover_serving_count "$org" "$name") || serving=-1
    if [[ "$serving" -lt 1 ]]; then
        rollover_resume_guest "$vmid" || log_error "rollover: failed to resume $name after replacement capacity changed"
        rollover_release_locks
        log_warn "rollover: skipping $name — online replacement capacity changed during quiesce"
        return 2
    fi

    if ! github_runner_deregister_id "$org" "$runner_id"; then
        rollover_resume_guest "$vmid" || log_error "rollover: failed to resume $name after deregistration failure"
        rollover_release_locks
        log_warn "rollover: skipping $name — GitHub deregistration failed"
        return 2
    fi

    if ! rollover_destroy_vm "$vmid"; then
        if rollover_quarantine_vm "$vmid" "$expected_gen"; then
            rollover_release_locks
            log_error "rollover: failed to destroy $name (VMID $vmid); quarantined residual so the slot can refill"
            return 4
        fi
        rollover_release_locks
        log_error "rollover: failed to destroy or quarantine $name (VMID $vmid); frozen residual needs operator repair"
        return 1
    fi
    rollover_release_locks
    log_info "rollover: destroyed idle old-generation runner $name (VMID $vmid, gen-$expected_gen)"
    return 0
}

rollover_main() {
    local force=false active_id active_state candidates name vmid gen org status age busy rc
    local destroyed=0 skipped=0 failed=0 refill_opened=0 deferred="" deadline now
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
    if [[ ! "$ROLLOVER_DESTROY_DELAY_SECONDS" =~ ^[0-9]+$ \
        || ! "$ROLLOVER_OFFLINE_TIMEOUT_SECONDS" =~ ^[0-9]+$ \
        || ! "$ROLLOVER_OFFLINE_POLL_SECONDS" =~ ^[0-9]+$ \
        || ! "$ROLLOVER_REPLACEMENT_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
        log_error "rollover timeout/delay settings must be non-negative integers"
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
                refill_opened=$((refill_opened + 1))
                [[ "$ROLLOVER_DESTROY_DELAY_SECONDS" -eq 0 ]] || sleep "$ROLLOVER_DESTROY_DELAY_SECONDS"
                ;;
            2) skipped=$((skipped + 1)) ;;
            3) deferred+="${name}|${vmid}|${gen}|${org}|${status}|${age}"$'\n' ;;
            4) failed=$((failed + 1)); refill_opened=$((refill_opened + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
        if pool_is_draining; then
            log_warn "rollover: maintenance mode is active; leaving remaining runners untouched"
            break
        fi
    done <<< "$candidates"

    # The first old runner destroyed opens a slot that the watcher fills from
    # the active generation. Revisit candidates deferred solely for capacity
    # until that replacement is verifiably online (checked inside destroy_one).
    if [[ -n "$deferred" && "$refill_opened" -gt 0 ]]; then
        while IFS='|' read -r name vmid gen org status age; do
            [[ -n "$name" ]] || continue
            deadline=$(($(date +%s) + ROLLOVER_REPLACEMENT_WAIT_SECONDS))
            while :; do
                rc=0
                rollover_destroy_one "$name" "$vmid" "$gen" "$org" || rc=$?
                [[ "$rc" -ne 3 ]] && break
                now=$(date +%s)
                (( now < deadline )) || break
                sleep "$ROLLOVER_OFFLINE_POLL_SECONDS"
            done
            case "$rc" in
                0) destroyed=$((destroyed + 1)) ;;
                1|4) failed=$((failed + 1)) ;;
                *) skipped=$((skipped + 1)) ;;
            esac
        done <<< "$deferred"
    elif [[ -n "$deferred" ]]; then
        while IFS= read -r name; do [[ -n "$name" ]] && skipped=$((skipped + 1)); done <<< "$deferred"
    fi
    log_info "rollover: destroyed $destroyed, skipped $skipped, failed $failed"
    [[ "$failed" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root rollover
    [[ -f "$CONFIG_FILE" ]] || { log_error "Runner host is not configured"; exit 1; }
    load_infra_config
    rollover_main "$@"
fi
