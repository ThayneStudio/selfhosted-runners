#!/bin/bash
set -euo pipefail
# Host-side termination guard for managed runner VMs.
#
# Two failure modes leave a pool slot permanently dead, and neither is visible
# to the watcher because `qm list` still reports the slot as filled:
#
#   - A managed VM stopped and nothing reaped it — the hookscript skips reclone
#     while the drain flag is set, and a host reboot brings VMs back stopped
#     with any hookscript-spawned reclone long dead.
#   - A managed VM outlived the guest's `shutdown -h +360` ceiling. That ceiling
#     is cooperative: the runner user has NOPASSWD:ALL so a job can cancel it,
#     and a wedged guest never runs it at all — precisely the case a ceiling
#     exists for. Enforcement has to live on the host.
#
# Scoping is the safety-critical part of this script, because it destroys VMs.
# A VM is a candidate only when get_vm_org() recognises its cloud-init snippet
# (the same predicate `runner stop` and `runner destroy` use), it sits at or
# above MIN_VMID, it is not TEMPLATE_ID, and it is not itself a template.
# Anything else on the host is untouchable.
#
# Usage: runner guard [--stopped-only] [--now] [--wait <seconds>]

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "guard"

[[ -f "$CONFIG_FILE" ]] || exit 0
load_infra_config

STOPPED_ONLY=false
REAP_NOW=false
LOCK_WAIT=0

usage() {
    echo "Usage: runner guard [--stopped-only] [--now] [--wait <seconds>]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stopped-only)
            STOPPED_ONLY=true
            shift
            ;;
        --now)
            REAP_NOW=true
            shift
            ;;
        --wait)
            [[ $# -ge 2 ]] || { log_error "--wait requires a value in seconds"; exit 1; }
            LOCK_WAIT="$2"
            shift 2
            ;;
        --wait=*)
            LOCK_WAIT="${1#--wait=}"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ ! "$LOCK_WAIT" =~ ^[0-9]+$ ]]; then
    log_error "--wait must be a non-negative number of seconds"
    exit 1
fi

# A bad value in the config must not disable the guard — fall back to the
# default instead, since the failure mode of "no guard" is a dead pool slot.
guard_setting() {
    local value="${1:-}" default="$2"
    if [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

LIFETIME_HOURS=$(guard_setting "${MAX_VM_LIFETIME_HOURS:-}" "$DEFAULT_MAX_VM_LIFETIME_HOURS")
STOPPED_MINUTES=$(guard_setting "${STOPPED_REAP_MINUTES:-}" "$DEFAULT_STOPPED_REAP_MINUTES")
LIFETIME_SECONDS=$((LIFETIME_HOURS * 3600))
STOPPED_SECONDS=$((STOPPED_MINUTES * 60))
[[ "$REAP_NOW" == true ]] && STOPPED_SECONDS=0

# MIN_VMID=0 means "let Proxmox pick", so runner VMIDs can legitimately land
# anywhere — treat it as no floor rather than inventing one, or the guard would
# silently skip the very VMs it exists to reap.
MIN_RUNNER_VMID="${MIN_VMID:-0}"
[[ "$MIN_RUNNER_VMID" =~ ^[0-9]+$ ]] || MIN_RUNNER_VMID=0

vm_is_template() {
    qm config "$1" 2>/dev/null | grep -q '^template:[[:space:]]*1'
}

# Managed runner VMs only. Every exclusion here is load-bearing.
collect_guard_candidates() {
    local all_vms line vmid vm_name status

    all_vms=$(qm list 2>/dev/null | tail -n +2 || true)
    [[ -n "$all_vms" ]] || return 0

    while read -r line; do
        [[ -n "$line" ]] || continue
        vmid=$(echo "$line" | awk '{print $1}')
        vm_name=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')

        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        [[ "$vmid" != "$TEMPLATE_ID" ]] || continue
        [[ "$vmid" -ge "$MIN_RUNNER_VMID" ]] || continue
        [[ "$(get_vm_org "$vmid")" != "unknown" ]] || continue
        vm_is_template "$vmid" && continue

        printf '%s|%s|%s\n' "$vmid" "$vm_name" "$status"
    done <<< "$all_vms"
}

vm_uptime_seconds() {
    qm status "$1" --verbose 2>/dev/null | awk '$1 == "uptime:" { print $2; exit }'
}

vm_config_mtime() {
    local path=""
    path=$(vm_config_path "$1") || true
    [[ -n "$path" ]] || { echo 0; return; }
    stat -c %Y "$path" 2>/dev/null || echo 0
}

stopped_marker_file() {
    printf '%s/%s.stopped\n' "$GUARD_STATE_DIR" "$1"
}

# Seconds this VMID has been observed stopped. A stopped VM has no uptime to
# read, so the guard records first sighting itself. The config mtime is stored
# alongside it: a recycled VMID gets a rewritten config, which invalidates the
# marker and restarts the clock rather than inheriting the old VM's age.
stopped_seconds() {
    local vmid="$1" now="$2"
    local marker first_seen seen_mtime mtime

    marker=$(stopped_marker_file "$vmid")
    mtime=$(vm_config_mtime "$vmid")

    if [[ -f "$marker" ]]; then
        read -r first_seen seen_mtime < "$marker" || true
        if [[ "$first_seen" =~ ^[0-9]+$ && "$seen_mtime" == "$mtime" && "$now" -ge "$first_seen" ]]; then
            echo $((now - first_seen))
            return
        fi
    fi

    printf '%s %s\n' "$now" "$mtime" > "$marker"
    echo 0
}

# 0 = destroyed, 1 = destroy failed, 2 = already gone.
reap_vm() {
    local vmid="$1" vm_name="$2" reason="$3"
    local status=""

    # Re-check under the pool lock: reclone.sh may already have destroyed it.
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}') || true
    [[ -n "$status" ]] || return 2

    log_warn "[guard] destroying $vm_name (VMID $vmid): $reason"
    logger -t github-runner "[guard] forcing destroy of $vm_name (VMID $vmid): $reason"

    if ! "$LIB_DIR/destroy.sh" --vmid "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&-; then
        # reclone.sh destroys before it takes the pool lock, so it can still
        # win the race between our re-check above and the destroy itself.
        qm status "$vmid" >/dev/null 2>&1 || return 2
        log_error "[guard] failed to destroy $vm_name (VMID $vmid)"
        logger -t github-runner "[guard] FAILED to destroy $vm_name (VMID $vmid)"
        return 1
    fi

    rm -f "$(stopped_marker_file "$vmid")"
    logger -t github-runner "[guard] destroyed $vm_name (VMID $vmid)"
}

install -d -m 700 "$GUARD_STATE_DIR"

skip_run() {
    log_info "[guard] clone activity in progress — skipping this run"
    logger -t github-runner "[guard] skipped: clone activity in progress"
    exec 202>&-
    exit 0
}

# Hold the pool activity lock exclusively for the whole run. clone_runner holds
# it shared for its full lifecycle, which covers the window where a freshly
# cloned VM exists but has not been started yet — exactly the window in which a
# stopped-VM reaper would otherwise eat a brand-new runner.
exec 202>"$POOL_ACTIVITY_LOCK_FILE"
if [[ "$LOCK_WAIT" -gt 0 ]]; then
    flock -w "$LOCK_WAIT" -x 202 || skip_run
else
    flock -n -x 202 || skip_run
fi

NOW=$(date +%s)
mapfile -t CANDIDATES < <(collect_guard_candidates)

declare -A STILL_STOPPED=()
REAPED=0
FAILED=0

for entry in "${CANDIDATES[@]}"; do
    [[ -n "$entry" ]] || continue
    IFS='|' read -r VMID VM_NAME STATUS <<< "$entry"

    case "$STATUS" in
        stopped)
            STILL_STOPPED["$VMID"]=1
            AGE=$(stopped_seconds "$VMID" "$NOW")
            [[ "$AGE" -ge "$STOPPED_SECONDS" ]] || continue
            if [[ "$REAP_NOW" == true ]]; then
                REASON="stopped and no longer wanted"
            else
                REASON="stopped for $((AGE / 60))m (limit ${STOPPED_MINUTES}m)"
            fi
            ;;
        running)
            [[ "$STOPPED_ONLY" == true ]] && continue
            UPTIME=$(vm_uptime_seconds "$VMID")
            # No readable uptime means no evidence — never destroy on a guess.
            [[ "$UPTIME" =~ ^[0-9]+$ ]] || continue
            [[ "$UPTIME" -ge "$LIFETIME_SECONDS" ]] || continue
            REASON="uptime $((UPTIME / 3600))h exceeds ${LIFETIME_HOURS}h ceiling"
            ;;
        *)
            # paused, suspended, prelaunch: no reliable age, leave it alone.
            continue
            ;;
    esac

    RC=0
    reap_vm "$VMID" "$VM_NAME" "$REASON" || RC=$?
    case "$RC" in
        0) REAPED=$((REAPED + 1)) ;;
        2) : ;;  # vanished under us — reclone.sh got there first
        *) FAILED=$((FAILED + 1)) ;;
    esac
done

# Drop markers for VMIDs that are no longer stopped managed runners, so nothing
# accumulates and a recycled VMID starts from a clean slate.
for marker in "$GUARD_STATE_DIR"/*.stopped; do
    [[ -e "$marker" ]] || continue
    marker_vmid=$(basename "$marker" .stopped)
    [[ -n "${STILL_STOPPED[$marker_vmid]:-}" ]] || rm -f "$marker"
done

logger -t github-runner "[guard] checked ${#CANDIDATES[@]} managed VM(s): destroyed $REAPED, failed $FAILED"
[[ "$REAPED" -eq 0 && "$FAILED" -eq 0 ]] || log_info "[guard] destroyed $REAPED VM(s), $FAILED failure(s)"

exec 202>&-
[[ "$FAILED" -eq 0 ]] || exit 1
