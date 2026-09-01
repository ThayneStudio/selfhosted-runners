#!/bin/bash
set -euo pipefail
# Destroy a stopped VM and clone a replacement with the same name/org.
# Called by the hookscript AFTER it exits (runs detached from Proxmox task).
# Usage: reclone.sh <vmid>

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

# A partially-loaded common.sh leaves pool_is_draining undefined, and every
# drain gate below is an `if` condition — where errexit is suppressed, so a
# missing command reads as "not draining" and this script would destroy and
# reclone a VM mid-maintenance. Refuse to run instead.
if ! declare -F pool_is_draining >/dev/null; then
    logger -t github-runner "reclone: common.sh did not load, refusing to touch VM ${1:-unknown}"
    exit 1
fi

VMID="${1:-}"
[[ -n "$VMID" ]] || { log_error "reclone: missing VMID argument"; exit 1; }

load_infra_config

if pool_is_draining; then
    logger -t github-runner "reclone: pool drain active, skipping VM $VMID"
    exit 0
fi

# Read name and org from the stopped VM's config (still exists, just stopped)
VM_CFG=$(qm config "$VMID" 2>/dev/null) || true
NAME=$(awk '/^name:/{print $2}' <<< "$VM_CFG") || true
ORG=$(get_vm_org "$VMID") || true

if [[ -z "$NAME" || -z "$ORG" || "$ORG" == "unknown" ]]; then
    logger -t github-runner "reclone: could not identify VM $VMID (name=$NAME org=$ORG), skipping"
    exit 0
fi

# Per-runner lock prevents races with watch.sh cloning the same slot
exec 200>"${RUNNER_SLOT_LOCK_PREFIX}-${NAME}.lock"
flock -n 200 || { log_info "reclone: another process is handling $NAME"; exit 0; }

exec 209>"${ROLLOVER_ORG_LOCK_PREFIX}-${ORG}.lock"
flock 209

if pool_is_draining; then
    logger -t github-runner "reclone: pool drain active for $NAME, skipping"
    exit 0
fi

# Backoff: defer to the watcher only after N consecutive rapid deaths.
# A single fast reclone is normal — short linter jobs (~45s) complete well
# inside any time-based window, so the old 120s blanket backoff misfired on
# every short job. A *streak* of rapid deaths is what indicates a real
# config error (bad PAT, network, cloud-init failure) worth deferring.
RECLONE_TS="${RECLONE_STATE_PREFIX}-${NAME}.reclone-ts"
FAIL_STREAK_FILE="${RECLONE_STATE_PREFIX}-${NAME}.fail-streak"
FAIL_THRESHOLD=3

NOW=$(date +%s)
LAST=0
[[ -f "$RECLONE_TS" ]] && LAST=$(cat "$RECLONE_TS" 2>/dev/null || echo 0)
STREAK=0
[[ -f "$FAIL_STREAK_FILE" ]] && STREAK=$(cat "$FAIL_STREAK_FILE" 2>/dev/null || echo 0)
[[ "$LAST"   =~ ^[0-9]+$ ]] || LAST=0
[[ "$STREAK" =~ ^[0-9]+$ ]] || STREAK=0

# RECLONE_TS means "time this slot was last processed by reclone.sh". Write
# it unconditionally so the streak check on the next invocation reflects
# time-since-last-death, not time-since-last-success. Without this, a
# deferred slot stays stuck — LAST never updates and every subsequent
# death within 120s of the stale value keeps incrementing STREAK.
echo "$NOW" > "$RECLONE_TS"

if (( LAST > 0 && NOW - LAST < 120 )); then
    STREAK=$((STREAK + 1))
else
    STREAK=0
fi
echo "$STREAK" > "$FAIL_STREAK_FILE"

if (( STREAK >= FAIL_THRESHOLD )); then
    logger -t github-runner "reclone: $NAME hit $STREAK rapid deaths in a row, deferring to watcher"
    # Reset the streak so the next invocation starts fresh. If the underlying
    # problem persists, we'll re-accumulate to threshold and defer again
    # (bounded-rate backoff). If it resolved, we proceed normally.
    echo 0 > "$FAIL_STREAK_FILE"
    rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml"
    qm destroy "$VMID" --purge 200>&- 2>/dev/null || true
    exit 0
fi

# Destroy the old VM (retry briefly in case Proxmox lock hasn't released)
rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml"
for attempt in 1 2 3; do
    destroy_output=$(qm destroy "$VMID" --purge 200>&- 2>&1) && destroy_rc=0 || destroy_rc=$?
    printf '%s\n' "$destroy_output" | logger -t github-runner || true
    if [[ $destroy_rc -eq 0 ]]; then
        break
    fi
    if [[ $attempt -eq 3 ]]; then
        log_error "reclone: failed to destroy VM $VMID after 3 attempts, deferring to watcher"
        exit 1
    fi
    sleep 2
done

# Check if someone else already filled this slot (watcher, manual create)
if qm list 200>&- 2>/dev/null | awk 'NR>1{print $2}' | grep -qxF "$NAME"; then
    log_info "reclone: $NAME already exists, skipping"
    exit 0
fi

if pool_is_draining; then
    logger -t github-runner "reclone: pool drain active after destroy for $NAME, leaving slot empty"
    exit 0
fi

# Clone replacement. RECLONE_TS was already written at the top of this
# script — no need to update it again on success.
# clone_runner 3 = promotion pause after a bounded wait; the slot is empty and
# the watcher (or the next death) retries. Must not notify clone.failed.
load_org_config "$ORG"
clone_rc=0
clone_runner "$NAME" "$ORG" >/dev/null || clone_rc=$?
if [[ "$clone_rc" -eq 0 ]]; then
    log_info "reclone: re-cloned $NAME for org $ORG"
elif [[ "$clone_rc" -eq 3 ]]; then
    log_info "reclone: promotion in progress, will retry"
    exit 0
else
    log_error "reclone: failed to re-clone $NAME for org $ORG"
    # Drop the per-slot lock before notifying. The work is over either way, and
    # a black-holed webhook would otherwise hold it for another ~33s, costing
    # the watcher a refill cycle on a slot that is already empty.
    exec 200>&-
    notify error clone.failed \
        "re-clone of runner $NAME failed, slot left empty for the watcher" \
        "org=$ORG, previous vmid=$VMID"
    exit 1
fi
