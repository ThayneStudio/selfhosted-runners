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
ROLLOVER_FROZEN_OWNED=false
ROLLOVER_FROZEN_COMMITTED=false
ROLLOVER_FROZEN_VMID=""
ROLLOVER_FROZEN_NAME=""
ROLLOVER_FROZEN_ORG=""
ROLLOVER_FROZEN_GEN=""
ROLLOVER_FROZEN_CGROUP=""
ROLLOVER_QUIESCE_UNCHANGED=false
ROLLOVER_PENDING_FILE=""
ROLLOVER_IDENTITY_NONCE=""
ROLLOVER_ORIGINAL_TAGS=""

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
    local target="$1" exclude_name="${2:-}" all_vms snapshot vmid _listed_name name status cfg org tags match count=0
    all_vms=$(qm list 2>/dev/null </dev/null) || return 1
    snapshot=$(github_runners_snapshot "$target") || return 1
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
        match=$(awk -F '\t' -v n="$name" '$1 == n {print $4}' <<< "$snapshot")
        [[ "$match" != *$'\n'* ]] || return 1
        [[ "$match" == online ]] && count=$((count + 1))
    done <<< "$all_vms"
    printf '%s\n' "$count"
}

rollover_release_locks() {
    exec 212>&- 2>/dev/null || true
    exec 210>&- 2>/dev/null || true
    exec 209>&- 2>/dev/null || true
}

rollover_destroy_vm() {
    RUNNER_DESTRUCTIVE_LOCKS_HELD=1 "$LIB_DIR/destroy.sh" --vmid "$1" --skip-deregister \
        </dev/null 200>&- 201>&- 202>&- 203>&- 204>&-
}

# Freeze the listener's actual cgroup before inspecting it. Once cgroup.freeze is
# acknowledged, Listener cannot accept another assignment. Busy/error paths
# thaw themselves; success deliberately leaves the guest frozen.
rollover_quiesce_guest() {
    local vmid="$1" result exitcode out ack
    # shellcheck disable=SC2016  # guest-side program must expand in the guest
    result=$(qm guest exec "$vmid" -- /bin/bash -c '
set -eu
cgroup_root=${RUNNER_CGROUP_ROOT:-/sys/fs/cgroup}
proc_root=${RUNNER_PROC_ROOT:-/proc}
marker=${RUNNER_ROLLOVER_MARKER:-/run/github-runner-rollover-cgroup}
unchanged() { echo UNCHANGED; exit 0; }
pids=$(pgrep -x Runner.Listener || true)
[ "$(printf "%s\n" "$pids" | sed "/^$/d" | wc -l)" -eq 1 ] || unchanged
pid=$pids
lines=$(grep "^0::" "${proc_root}/${pid}/cgroup" || true)
[ "$(printf "%s\n" "$lines" | sed "/^$/d" | wc -l)" -eq 1 ] || unchanged
cg=${lines#0::}
case "$cg" in /|*[!a-zA-Z0-9_./:@-]*|*..*) unchanged;; /*) ;; *) unchanged;; esac
[ -w "${cgroup_root}${cg}/cgroup.freeze" ] && [ -r "${cgroup_root}${cg}/cgroup.events" ] || unchanged
printf "%s\n" "$cg" > "$marker"
chmod 600 "$marker"
thaw() {
    if echo 0 > "${cgroup_root}${cg}/cgroup.freeze" 2>/dev/null \
        && grep -q "^0$" "${cgroup_root}${cg}/cgroup.freeze"; then
        rm -f "$marker"
    fi
}
trap thaw EXIT
echo 1 > "${cgroup_root}${cg}/cgroup.freeze"
i=0
while ! grep -q "^frozen 1$" "${cgroup_root}${cg}/cgroup.events"; do
    i=$((i + 1)); [ "$i" -lt 50 ] || { echo ERROR; exit 1; }
    sleep 0.1
done
if pgrep -x Runner.Worker >/dev/null 2>&1; then
    thaw
    [ ! -e "$marker" ] || { echo ERROR; exit 1; }
    trap - EXIT
    echo BUSY_UNFROZEN
    exit 0
fi
trap - EXIT
echo "FROZEN:${cg}"
' 2>/dev/null </dev/null) || return 1
    exitcode=$(jq -er '.exitcode | select(type == "number")' <<< "$result" 2>/dev/null) || return 1
    out=$(jq -er '.["out-data"] | select(type == "string")' <<< "$result" 2>/dev/null) || return 1
    [[ "$exitcode" -eq 0 ]] || return 1
    if [[ "$out" == BUSY_UNFROZEN || "$out" == $'BUSY_UNFROZEN\n' || "$out" == $'BUSY_UNFROZEN\r\n' ]]; then
        ROLLOVER_QUIESCE_UNCHANGED=true
        return 2
    fi
    if [[ "$out" == UNCHANGED || "$out" == $'UNCHANGED\n' || "$out" == $'UNCHANGED\r\n' ]]; then
        ROLLOVER_QUIESCE_UNCHANGED=true
        return 3
    fi
    ack=$(sed -n 's/^FROZEN:\(\/[a-zA-Z0-9_./:@-]*\)$/\1/p' <<< "$out")
    [[ "$ack" =~ ^/[a-zA-Z0-9_./:@-]+$ && "$ack" != / && "$ack" != *'..'* && "$ack" != *$'\n'* ]] || return 1
    ROLLOVER_FROZEN_CGROUP="$ack"
}

rollover_resume_guest() {
    resume_runner_cgroup "$1" "$ROLLOVER_FROZEN_CGROUP"
}

rollover_pending_write() {
    local phase="$1" vmid="$2" name="$3" org="$4" gen="$5" runner_id="$6" nonce="$7" cgroup="${8:-}" tmp
    ensure_state_dir "$ROLLOVER_PENDING_DIR"
    tmp=$(mktemp "$ROLLOVER_PENDING_DIR/.${vmid}.XXXXXX") || return 1
    chmod 600 "$tmp"
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$phase" "$vmid" "$name" "$org" "$gen" "$runner_id" "$nonce" "$cgroup" > "$tmp"
    mv -f "$tmp" "$ROLLOVER_PENDING_DIR/${vmid}.pending"
    ROLLOVER_PENDING_FILE="$ROLLOVER_PENDING_DIR/${vmid}.pending"
}

rollover_cleanup_frozen() {
    local thaw_verified=false cleanup_complete=false
    [[ "$ROLLOVER_FROZEN_OWNED" == true ]] || return 0
    if [[ "$ROLLOVER_FROZEN_COMMITTED" != true ]]; then
        if [[ "$ROLLOVER_QUIESCE_UNCHANGED" == true ]]; then
            thaw_verified=true
        elif rollover_resume_guest "$ROLLOVER_FROZEN_VMID"; then
            thaw_verified=true
        elif rollover_vmid_absent_verified "$ROLLOVER_FROZEN_VMID"; then
            thaw_verified=true
        else
            log_error "rollover: cleanup could not verify thaw of VMID $ROLLOVER_FROZEN_VMID; durable ownership retained"
        fi
        if [[ "$thaw_verified" == true ]] && rollover_vmid_absent_verified "$ROLLOVER_FROZEN_VMID"; then
            cleanup_complete=true
        elif [[ "$thaw_verified" == true && -n "$ROLLOVER_IDENTITY_NONCE" ]] && rollover_pending_identity_matches \
            "$ROLLOVER_FROZEN_VMID" "$ROLLOVER_FROZEN_NAME" "$ROLLOVER_FROZEN_ORG" "$ROLLOVER_FROZEN_GEN" "$ROLLOVER_IDENTITY_NONCE" \
            && qm set "$ROLLOVER_FROZEN_VMID" --tags "$ROLLOVER_ORIGINAL_TAGS" >/dev/null 2>&1; then
            cleanup_complete=true
        fi
        if [[ "$cleanup_complete" == true && -n "$ROLLOVER_PENDING_FILE" ]]; then rm -f "$ROLLOVER_PENDING_FILE"; fi
    fi
    ROLLOVER_FROZEN_OWNED=false
}

rollover_arm_cleanup() {
    ROLLOVER_FROZEN_VMID="$1"; ROLLOVER_FROZEN_NAME="$2"; ROLLOVER_FROZEN_ORG="$3"; ROLLOVER_FROZEN_GEN="$4"
    ROLLOVER_FROZEN_OWNED=true
    ROLLOVER_FROZEN_COMMITTED=false
    ROLLOVER_QUIESCE_UNCHANGED=false
    trap 'rollover_cleanup_frozen' EXIT
    trap 'rollover_cleanup_frozen; exit 130' INT
    trap 'rollover_cleanup_frozen; exit 143' TERM
}

rollover_mark_identity() {
    local vmid="$1" name="$2" org="$3" gen="$4" cfg
    cfg=$(qm config "$vmid" 2>/dev/null) || return 1
    ROLLOVER_ORIGINAL_TAGS=$(awk -F ': ' '/^tags:/{print $2; exit}' <<< "$cfg")
    ROLLOVER_IDENTITY_NONCE="$(date +%s)-$$-${RANDOM}"
    qm set "$vmid" --tags "${ROLLOVER_ORIGINAL_TAGS:+${ROLLOVER_ORIGINAL_TAGS},}rollover-${ROLLOVER_IDENTITY_NONCE}" >/dev/null || return 1
    rollover_pending_identity_matches "$vmid" "$name" "$org" "$gen" "$ROLLOVER_IDENTITY_NONCE"
}

rollover_disarm_cleanup() {
    ROLLOVER_FROZEN_OWNED=false
    trap - EXIT INT TERM
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

rollover_configured_count() {
    local org="$1" count
    [[ -f "$ORG_CONFIG_DIR/${org}.conf" ]] || return 1
    count=$(sed -nE 's/^[[:space:]]*RUNNER_COUNT[[:space:]]*=[[:space:]]*"?([0-9]+)"?.*/\1/p' "$ORG_CONFIG_DIR/${org}.conf")
    [[ "$count" =~ ^[1-9][0-9]*$ && "$count" != *$'\n'* ]] || return 1
    printf '%s\n' "$count"
}

# Returns 0 destroyed, 2 safely skipped, 3 deferred for replacement capacity,
# 4 destroy failed but slot was quarantined/opened, 5 unsupported singleton,
# 1 unrecovered failure.
rollover_destroy_one() {
    local name="$1" vmid="$2" expected_gen="$3" org="$4"
    local cfg current_name current_org current_gen status serving configured runner_id quiesce_rc wait_rc

    if pool_is_draining; then
        log_error "rollover: maintenance mode became active — stopping"
        return 2
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || ! validate_org_name "$org"; then
        log_error "rollover: invalid managed runner identity"
        return 2
    fi

    exec 210>"${RUNNER_SLOT_LOCK_PREFIX}-${name}.lock"
    if ! flock -n 210; then
        rollover_release_locks
        log_info "rollover: skipping $name — its slot is busy"
        return 2
    fi
    exec 209>"${ROLLOVER_ORG_LOCK_PREFIX}-${org}.lock"
    flock 209

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
        configured=$(rollover_configured_count "$org") || {
            rollover_release_locks
            log_warn "rollover: cannot verify configured pool size for $org"
            return 2
        }
        if [[ "$configured" -eq 1 ]]; then
            rollover_release_locks
            log_error "rollover: zero-downtime singleton rollover is unsupported for $org; increase RUNNER_COUNT first"
            return 5
        fi
        rollover_release_locks
        log_info "rollover: deferring $name until another GitHub-online runner for $org is available"
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

    if ! rollover_mark_identity "$vmid" "$name" "$org" "$expected_gen"; then
        rollover_release_locks
        log_error "rollover: could not bind recovery identity for $name"
        return 2
    fi
    if ! rollover_pending_write preparing "$vmid" "$name" "$org" "$expected_gen" 0 "$ROLLOVER_IDENTITY_NONCE"; then
        qm set "$vmid" --tags "$ROLLOVER_ORIGINAL_TAGS" >/dev/null 2>&1 || true
        rollover_release_locks
        log_error "rollover: could not persist pre-quiesce recovery ownership for $name"
        return 2
    fi
    rollover_arm_cleanup "$vmid" "$name" "$org" "$expected_gen"
    quiesce_rc=0
    rollover_quiesce_guest "$vmid" || quiesce_rc=$?
    if [[ "$quiesce_rc" -ne 0 ]]; then
        rollover_cleanup_frozen
        rollover_disarm_cleanup
        rollover_release_locks
        if [[ "$quiesce_rc" -eq 2 ]]; then
            log_info "rollover: skipping $name — guest reports an active Runner.Worker"
        elif [[ "$quiesce_rc" -eq 3 ]]; then
            log_info "rollover: skipping $name — guest listener topology is unchanged but not uniquely quiesceable"
        else
            log_warn "rollover: skipping $name — could not prove guest quiescence"
        fi
        return 2
    fi
    if ! rollover_pending_write owned "$vmid" "$name" "$org" "$expected_gen" 0 "$ROLLOVER_IDENTITY_NONCE" "$ROLLOVER_FROZEN_CGROUP"; then
        rollover_cleanup_frozen
        rollover_disarm_cleanup
        rollover_release_locks
        log_error "rollover: could not persist frozen cgroup identity for $name"
        return 2
    fi

    wait_rc=0
    runner_id=$(rollover_wait_offline_idle "$org" "$name") || wait_rc=$?
    if [[ "$wait_rc" -ne 0 ]]; then
        rollover_cleanup_frozen
        rollover_disarm_cleanup
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
        rollover_cleanup_frozen
        rollover_disarm_cleanup
        rollover_release_locks
        log_warn "rollover: skipping $name — online replacement capacity changed during quiesce"
        return 2
    fi

    if ! rollover_pending_identity_matches "$vmid" "$name" "$org" "$expected_gen" "$ROLLOVER_IDENTITY_NONCE"; then
        rollover_cleanup_frozen
        rollover_disarm_cleanup
        rollover_release_locks
        log_error "rollover: identity changed before commit for $name"
        return 2
    fi
    if ! rollover_pending_write committed "$vmid" "$name" "$org" "$expected_gen" "$runner_id" "$ROLLOVER_IDENTITY_NONCE" "$ROLLOVER_FROZEN_CGROUP"; then
        rollover_cleanup_frozen
        rollover_disarm_cleanup
        rollover_release_locks
        log_error "rollover: could not persist recovery intent for $name"
        return 2
    fi
    ROLLOVER_FROZEN_COMMITTED=true
    if ! github_runner_deregister_id "$org" "$runner_id"; then
        ROLLOVER_FROZEN_COMMITTED=false
        rollover_cleanup_frozen
        rollover_disarm_cleanup
        rollover_release_locks
        log_warn "rollover: skipping $name — GitHub deregistration failed"
        return 2
    fi

    if ! rollover_pending_identity_matches "$vmid" "$name" "$org" "$expected_gen" "$ROLLOVER_IDENTITY_NONCE"; then
        rollover_disarm_cleanup
        rollover_release_locks
        log_error "rollover: committed identity changed for $name; refusing destroy"
        return 1
    fi
    if ! rollover_destroy_vm "$vmid"; then
        rollover_disarm_cleanup
        rollover_release_locks
        log_error "rollover: failed to destroy $name (VMID $vmid); durable recovery will retry and the slot may refill"
        return 4
    fi
    rm -f "$ROLLOVER_PENDING_FILE"
    rollover_disarm_cleanup
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
