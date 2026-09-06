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
# above MIN_VMID, it is not TEMPLATE_ID, it is not itself a template, it is
# neither protected nor locked, and it is not listed in GUARD_EXCLUDE_VMIDS.
# Anything else on the host is untouchable.
#
# Concurrency: per-slot locks only (/run/lock/runner-<name>.lock, the same lock
# reclone.sh and watch.sh take before cloning a slot). The guard deliberately
# does NOT take the global pool activity lock: destroying holds locks for tens
# of seconds per VM — deregistration talks to api.github.com — and a global
# exclusive hold would stall every clone_runner worker until watch.service hits
# TimeoutStartSec and gets SIGKILLed mid-clone. A stopped VM is additionally
# protected by a structural freshness check (see STOPPED_FRESH_SECONDS below),
# so the mid-clone window is safe without any global serialization.
#
# Usage: runner guard [--stopped-only] [--now] [--dry-run] [--wait <seconds>]

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "guard"

[[ -f "$CONFIG_FILE" ]] || exit 0
load_infra_config

STOPPED_ONLY=false
REAP_NOW=false
DRY_RUN=false
LOCK_WAIT=0

usage() {
    echo "Usage: runner guard [--stopped-only] [--now] [--dry-run] [--wait <seconds>]"
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
        --dry-run)
            DRY_RUN=true
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

# --now drops both age checks, so the only thing left standing between it and a
# clone in progress is the per-slot lock. Maintenance mode closes that gap by
# stopping new clones at the source, so require it rather than assume it.
if [[ "$REAP_NOW" == true && "$DRY_RUN" != true ]] && ! pool_is_draining; then
    log_error "--now requires maintenance mode (the pool is not draining)"
    log_error "Run 'runner stop --watch-only' first, or drop --now to use STOPPED_REAP_MINUTES."
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

# Structural freshness: independent of any state file, a stopped VM is only
# reapable once its config has sat untouched for this long. `qm clone` writes
# the config, so a VM created seconds ago can never satisfy it — that is what
# makes reaping safe without holding the pool activity lock. The absolute floor
# still applies under --now, where the age thresholds are zero.
STOPPED_FRESH_SECONDS="$STOPPED_SECONDS"
[[ "$STOPPED_FRESH_SECONDS" -ge "$GUARD_MIN_CONFIG_AGE_SECONDS" ]] \
    || STOPPED_FRESH_SECONDS="$GUARD_MIN_CONFIG_AGE_SECONDS"

# An unset MIN_VMID predates the key, so assume the same floor
# cleanup_runner_orphan_volumes() assumes. An explicit 0 means "let Proxmox
# pick", where runner VMIDs can legitimately land anywhere, so it means no
# floor — anything else would leave those VMs unreapable.
MIN_RUNNER_VMID="${MIN_VMID-$((TEMPLATE_ID + 1))}"
[[ "$MIN_RUNNER_VMID" =~ ^[0-9]+$ ]] || MIN_RUNNER_VMID=$((TEMPLATE_ID + 1))

declare -a CANDIDATES=()
declare -a NOTIFICATIONS=()
declare -A MARKER_KEEP=()
declare -A DEFER_KEEP=()
LIST_OK=false
LIST_ROWS=0
REAPED=0
FAILED=0
DEFERRED=0
SKIPPED=0
NO_UPTIME=0
NO_MTIME=0
UNREADABLE=0
WOULD_REAP=0

vm_is_excluded() {
    local vmid="$1" excluded raw="${GUARD_EXCLUDE_VMIDS:-}"
    local -a excludes=()
    read -ra excludes <<< "${raw//,/ }"
    for excluded in "${excludes[@]}"; do
        [[ "$excluded" == "$vmid" ]] && return 0
    done
    return 1
}

# Raw mtime of the VM's Proxmox config, or empty when it cannot be read. Empty
# is never treated as "old": without this evidence the guard does not destroy.
vm_config_mtime() {
    local path="" mtime=""
    path=$(vm_config_path "$1") || true
    [[ -n "$path" ]] || return 0
    mtime=$(stat -c %Y "$path" 2>/dev/null) || return 0
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 0
    printf '%s\n' "$mtime"
}

vm_uptime_seconds() {
    qm status "$1" --verbose 2>/dev/null </dev/null | awk '$1 == "uptime:" { print $2; exit }'
}

stopped_marker_file() {
    printf '%s/%s.stopped\n' "$GUARD_STATE_DIR" "$1"
}

deferred_file() {
    printf '%s/%s.deferred\n' "$GUARD_STATE_DIR" "$1"
}

# Seconds this VMID has been observed stopped. A stopped VM has no uptime to
# read, so the guard records first sighting itself. The config mtime is stored
# alongside it: a recycled VMID gets a rewritten config, which invalidates the
# marker and restarts the clock rather than inheriting the old VM's age.
stopped_seconds() {
    local vmid="$1" now="$2" mtime="$3"
    local marker first_seen seen_mtime

    marker=$(stopped_marker_file "$vmid")
    if [[ -f "$marker" ]]; then
        read -r first_seen seen_mtime < "$marker" || true
        if [[ "$first_seen" =~ ^[0-9]+$ && "$seen_mtime" == "$mtime" && "$now" -ge "$first_seen" ]]; then
            echo $((now - first_seen))
            return
        fi
    fi

    [[ "$DRY_RUN" == true ]] || printf '%s %s\n' "$now" "$mtime" > "$marker"
    echo 0
}

# Per-slot lock, the same one reclone.sh and watch.sh hold across a clone. Held
# only around a single VM's destroy, so one busy slot cannot stall the others.
acquire_slot_lock() {
    local remaining
    exec 200>"${RUNNER_SLOT_LOCK_PREFIX}-${1}.lock"
    remaining=$((LOCK_DEADLINE - $(date +%s)))
    if [[ "$remaining" -gt 0 ]]; then
        flock -w "$remaining" 200 && return 0
    else
        flock -n 200 && return 0
    fi
    exec 200>&-
    return 1
}

release_slot_lock() {
    exec 200>&- || true
}

note_deferral() {
    local vmid="$1" vm_name="$2" reason="$3" file count=0
    file=$(deferred_file "$vmid")
    [[ -f "$file" ]] && count=$(cat "$file" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))
    echo "$count" > "$file"
    DEFERRED=$((DEFERRED + 1))

    # Deferring forever is indistinguishable from a healthy run unless it is
    # said out loud: a slot lock nobody releases means the VM is never reaped.
    if [[ "$count" -ge "$GUARD_DEFER_WARN_RUNS" ]]; then
        log_warn "[guard] $vm_name (VMID $vmid) deferred $count runs in a row — its slot lock is held: $reason"
        logger -t github-runner "[guard] $vm_name (VMID $vmid) deferred $count consecutive runs: $reason"
    else
        log_info "[guard] $vm_name (VMID $vmid) slot is busy, deferring: $reason"
    fi
}

queue_notification() {
    local event="$1" vm_name="$2" vmid="$3" reason="$4" severity="warn"

    # Spec 10.1 mandates warn for a forced lifetime destroy. A stopped-VM reap
    # is equally abnormal on the timer path — a slot died and nothing recycled
    # it — but routine when an operator asked for it through `runner start`.
    [[ "$event" == "stopped_vm.reaped" && "$REAP_NOW" == true ]] && severity="info"

    NOTIFICATIONS+=("${severity}|${event}|forced destroy of ${vm_name} (VMID ${vmid}): ${reason}|${reason}")
}

# Always the last thing the guard does, after every lock is released. A
# black-holed webhook costs seconds per event and must never extend a critical
# section. lib/notify.sh arrives with the notification library; until then, and
# if it is ever missing, the guard has to keep working without it.
flush_notifications() {
    [[ ${#NOTIFICATIONS[@]} -gt 0 ]] || return 0

    if [[ ! -f "$LIB_DIR/notify.sh" ]]; then
        log_info "[guard] notification library not installed — ${#NOTIFICATIONS[@]} event(s) not sent"
        return 0
    fi

    (
        # shellcheck source=/dev/null
        source "$LIB_DIR/notify.sh" 2>/dev/null || exit 0
        command -v notify >/dev/null 2>&1 || exit 0
        local queued severity event message detail
        for queued in "${NOTIFICATIONS[@]}"; do
            IFS='|' read -r severity event message detail <<< "$queued"
            notify "$severity" "$event" "$message" "$detail" || true
        done
    ) || true
}

# 0 = destroyed, 1 = destroy failed, 2 = already gone.
reap_vm() {
    local vmid="$1" vm_name="$2" reason="$3" event="$4"
    local status=""

    # Re-check under the slot lock: reclone.sh may already have destroyed it.
    status=$(qm status "$vmid" 2>/dev/null </dev/null | awk '{print $2}') || true
    [[ -n "$status" ]] || return 2

    log_warn "[guard] destroying $vm_name (VMID $vmid): $reason"
    logger -t github-runner "[guard] forcing destroy of $vm_name (VMID $vmid): $reason"

    if ! "$LIB_DIR/destroy.sh" --vmid "$vmid" </dev/null 200>&- 201>&- 202>&- 203>&- 204>&-; then
        # reclone.sh destroys before it takes the slot lock, so it can still win
        # the race between our re-check above and the destroy itself.
        qm status "$vmid" >/dev/null 2>&1 </dev/null || return 2
        log_error "[guard] failed to destroy $vm_name (VMID $vmid)"
        logger -t github-runner "[guard] FAILED to destroy $vm_name (VMID $vmid)"
        return 1
    fi

    rm -f "$(stopped_marker_file "$vmid")" "$(deferred_file "$vmid")"
    logger -t github-runner "[guard] destroyed $vm_name (VMID $vmid)"
    queue_notification "$event" "$vm_name" "$vmid" "$reason"
}

# Populates CANDIDATES plus the marker/deferral keep-sets. Runs in this shell,
# not a subshell, so a failed `qm list` can stop the marker sweep instead of
# letting it mistake "could not look" for "no longer there".
collect_candidates() {
    local all_vms vmid vm_name status cfg org lock_line

    if ! all_vms=$(qm list 2>/dev/null </dev/null); then
        return 1
    fi
    LIST_OK=true

    while read -r vmid vm_name status _; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        LIST_ROWS=$((LIST_ROWS + 1))

        [[ "$vmid" != "$TEMPLATE_ID" ]] || continue
        [[ "$vmid" -ge "$MIN_RUNNER_VMID" ]] || continue

        # An unreadable config is not evidence of anything: never a candidate,
        # and its state files must survive the sweep.
        if ! cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || [[ -z "$cfg" ]]; then
            MARKER_KEEP["$vmid"]=1
            DEFER_KEEP["$vmid"]=1
            UNREADABLE=$((UNREADABLE + 1))
            log_warn "[guard] could not read config for VMID $vmid — skipping it this run"
            continue
        fi

        org=$(get_vm_org "$vmid")
        [[ "$org" != "unknown" ]] || continue
        grep -q '^template:[[:space:]]*1' <<< "$cfg" && continue

        DEFER_KEEP["$vmid"]=1
        [[ "$status" != "stopped" ]] || MARKER_KEEP["$vmid"]=1

        if vm_is_excluded "$vmid"; then
            log_info "[guard] skipping $vm_name (VMID $vmid): listed in GUARD_EXCLUDE_VMIDS"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # An operator keeping a wedged runner for forensics sets protection, or
        # suspends it to disk (which reports stopped with a lock line). Both are
        # explicit "hands off" signals, and qm destroy refuses them anyway —
        # obeying them is what keeps the unit out of a permanent failed state.
        if grep -q '^protection:[[:space:]]*1' <<< "$cfg"; then
            log_info "[guard] skipping $vm_name (VMID $vmid): protection is set"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        if lock_line=$(grep -m1 '^lock:' <<< "$cfg"); then
            log_info "[guard] skipping $vm_name (VMID $vmid): ${lock_line}"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # The slot lock is keyed by name. A name we cannot safely turn into a
        # lock path is a VM we cannot coordinate on, so leave it alone.
        if [[ ! "$vm_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
            log_warn "[guard] skipping VMID $vmid: unusable runner name '$vm_name'"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        CANDIDATES+=("$vmid|$vm_name|$status|$org")
    done <<< "$(tail -n +2 <<< "$all_vms")"
}

install -d -m 700 "$GUARD_STATE_DIR"
recover_rollover_pending

NOW=$(date +%s)
LOCK_DEADLINE=$((NOW + LOCK_WAIT))

if ! collect_candidates; then
    log_error "[guard] qm list failed — nothing checked this run"
    logger -t github-runner "[guard] qm list failed; nothing checked"
    exit 1
fi

for entry in "${CANDIDATES[@]}"; do
    IFS='|' read -r VMID VM_NAME STATUS VM_ORG <<< "$entry"
    REASON=""
    EVENT=""

    case "$STATUS" in
        stopped)
            MTIME=$(vm_config_mtime "$VMID")
            if [[ -z "$MTIME" ]]; then
                # Fail closed: without a config mtime the freshness check cannot
                # rule out a clone in progress, so this VM is never destroyed.
                NO_MTIME=$((NO_MTIME + 1))
                log_warn "[guard] no readable config mtime for $VM_NAME (VMID $VMID) — not reaping it"
                logger -t github-runner "[guard] no config mtime for $VM_NAME (VMID $VMID); stopped reap suspended"
                continue
            fi
            CONFIG_AGE=$((NOW - MTIME))
            [[ "$CONFIG_AGE" -ge 0 ]] || CONFIG_AGE=0
            AGE=$(stopped_seconds "$VMID" "$NOW" "$MTIME")
            [[ "$AGE" -ge "$STOPPED_SECONDS" ]] || continue
            [[ "$CONFIG_AGE" -ge "$STOPPED_FRESH_SECONDS" ]] || continue
            EVENT="stopped_vm.reaped"
            if [[ "$REAP_NOW" == true ]]; then
                REASON="stopped and no longer wanted"
            else
                REASON="stopped for $((AGE / 60))m (limit ${STOPPED_MINUTES}m)"
            fi
            ;;
        running)
            [[ "$STOPPED_ONLY" == true ]] && continue
            UPTIME=$(vm_uptime_seconds "$VMID")
            # Fail open on the destroy, but never silently: a Proxmox upgrade
            # that renames this field would otherwise turn the ceiling off.
            if [[ ! "$UPTIME" =~ ^[0-9]+$ ]]; then
                NO_UPTIME=$((NO_UPTIME + 1))
                log_warn "[guard] no readable uptime for $VM_NAME (VMID $VMID) — lifetime ceiling not enforced"
                logger -t github-runner "[guard] no readable uptime for $VM_NAME (VMID $VMID); ceiling not enforced"
                continue
            fi
            [[ "$UPTIME" -ge "$LIFETIME_SECONDS" ]] || continue
            EVENT="lifetime.forced_destroy"
            REASON="uptime $((UPTIME / 3600))h exceeds ${LIFETIME_HOURS}h ceiling"
            ;;
        *)
            # paused, suspended, prelaunch: no reliable age, leave it alone.
            continue
            ;;
    esac

    if [[ "$DRY_RUN" == true ]]; then
        WOULD_REAP=$((WOULD_REAP + 1))
        log_info "[guard] would destroy $VM_NAME (VMID $VMID): $REASON"
        continue
    fi

    if ! acquire_slot_lock "$VM_NAME"; then
        note_deferral "$VMID" "$VM_NAME" "$REASON"
        continue
    fi
    rm -f "$(deferred_file "$VMID")"
    exec 209>"${ROLLOVER_ORG_LOCK_PREFIX}-${VM_ORG}.lock"
    flock 209

    RC=0
    RUNNER_DESTRUCTIVE_LOCKS_HELD=1 reap_vm "$VMID" "$VM_NAME" "$REASON" "$EVENT" || RC=$?
    exec 209>&-
    release_slot_lock

    case "$RC" in
        0) REAPED=$((REAPED + 1)) ;;
        2) : ;;  # vanished under us — reclone.sh got there first
        *) FAILED=$((FAILED + 1)) ;;
    esac
done

# Sweep state for VMIDs that are no longer stopped managed runners. Only ever
# on positive evidence: a marker deleted by mistake silently restarts that VM's
# clock, so "could not read it" must never look like "it is gone".
if [[ "$DRY_RUN" != true && "$LIST_OK" == true && "$LIST_ROWS" -gt 0 ]]; then
    for state_file in "$GUARD_STATE_DIR"/*.stopped; do
        [[ -e "$state_file" ]] || continue
        state_vmid=$(basename "$state_file" .stopped)
        [[ -n "${MARKER_KEEP[$state_vmid]:-}" ]] || rm -f "$state_file"
    done
    for state_file in "$GUARD_STATE_DIR"/*.deferred; do
        [[ -e "$state_file" ]] || continue
        state_vmid=$(basename "$state_file" .deferred)
        [[ -n "${DEFER_KEEP[$state_vmid]:-}" ]] || rm -f "$state_file"
    done
fi

if [[ "$DRY_RUN" == true ]]; then
    log_info "[guard] dry run: ${#CANDIDATES[@]} managed VM(s) checked, would destroy $WOULD_REAP"
    logger -t github-runner "[guard] dry run: checked ${#CANDIDATES[@]} managed VM(s), would destroy $WOULD_REAP"
    exit 0
fi

SUMMARY="checked ${#CANDIDATES[@]} managed VM(s): destroyed $REAPED, failed $FAILED"
SUMMARY="$SUMMARY, deferred $DEFERRED, skipped $SKIPPED"
SUMMARY="$SUMMARY, no-uptime $NO_UPTIME, no-mtime $NO_MTIME, unreadable $UNREADABLE"
logger -t github-runner "[guard] $SUMMARY"
[[ "$REAPED" -eq 0 && "$FAILED" -eq 0 ]] || log_info "[guard] destroyed $REAPED VM(s), $FAILED failure(s)"

flush_notifications

[[ "$FAILED" -eq 0 ]] || exit 1
# The caller asked us to wait for busy slots and we still could not finish, so
# do not report success — `runner start` warns on this and the timer retries.
[[ "$LOCK_WAIT" -eq 0 || "$DEFERRED" -eq 0 ]] || exit 1
exit 0
