#!/bin/bash
set -euo pipefail
# Destroy a stopped VM and clone a replacement with the same name/org.
# The hookscript starts this as its own systemd unit after the VM's post-stop.
# Usage: reclone.sh <vmid>

RECLONE_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=common.sh
source "$RECLONE_LIB_DIR/common.sh"
# shellcheck source=recycle.sh
source "$RECLONE_LIB_DIR/recycle.sh"

reclone_main() {
    local vmid="${1:-}" name org config lock status
    [[ -n "$vmid" ]] || { log_error "reclone: missing VMID argument"; exit 1; }

    load_infra_config

    if pool_is_draining; then
        logger -t github-runner "reclone: pool drain active, skipping VM $vmid"
        exit 0
    fi

    # Read name and org from the stopped VM's config (still exists, just stopped)
    name=$(qm config "$vmid" 2>/dev/null | awk '/^name:/{print $2}') || true
    org=$(get_vm_org "$vmid") || true

    if [[ -z "$name" || -z "$org" || "$org" == "unknown" ]]; then
        logger -t github-runner "reclone: could not identify VM $vmid (name=$name org=$org), skipping"
        exit 0
    fi

    # Per-runner lock prevents races with watch.sh on the same slot
    exec 200>"$(slot_lock_file "$name")"
    flock -n 200 || { log_info "reclone: another process is handling $name"; exit 0; }

    if pool_is_draining; then
        logger -t github-runner "reclone: pool drain active for $name, skipping"
        exit 0
    fi

    # Look again under the slot lock, before touching anything. The watcher
    # may have recycled this VM already (and reused its VMID). A VM that
    # vzdump has locked, or that is running again, is not dead yet: leave it
    # and its snippets, and the watcher reclaims it once it is stopped and
    # unlocked.
    config=$(qm config "$vmid" 200>&- 2>/dev/null) || config=""
    if [[ "$(awk '/^name:/{print $2; exit}' <<< "$config")" != "$name" ]]; then
        log_info "reclone: VM $vmid is no longer $name, skipping"
        exit 0
    fi
    lock=$(awk '/^lock:/{print $2; exit}' <<< "$config")
    if [[ -n "$lock" ]]; then
        logger -t github-runner "reclone: VM $vmid ($name) is locked ($lock); leaving it for the watcher"
        exit 0
    fi
    status=$(qm status "$vmid" 200>&- 2>/dev/null | awk '{print $2}') || status=""
    if [[ "$status" != "stopped" ]]; then
        logger -t github-runner "reclone: VM $vmid ($name) is ${status:-in an unknown state}, not stopped; leaving it for the watcher"
        exit 0
    fi

    # Hold shared pool activity for the rest of this process so `runner stop`
    # (exclusive 202) waits out destroy + mint, not just the later qm clone.
    # clone_runner sees POOL_ACTIVITY_LOCK_HELD and will not reopen fd 202.
    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -s 202
    POOL_ACTIVITY_LOCK_HELD=1

    # A single fast death is normal: a short job on a runner that picked it up
    # straight away. A run of them means the guest never got to run a job, and
    # holds the slot (recycle.sh) so the refill below waits for the watcher.
    slot_note_death "$name" "$(runner_vm_age "$vmid")"

    if ! destroy_runner_vm "$vmid"; then
        log_error "reclone: failed to destroy VM $vmid after 3 attempts, deferring to watcher"
        exit 1
    fi

    refill_runner_slot "$name" "$org" reclone "$(runner_vm_kind "$config")" || exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    reclone_main "$@"
fi
