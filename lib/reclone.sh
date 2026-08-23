#!/bin/bash
set -euo pipefail
# Destroy a stopped VM and clone a replacement with the same name/org.
# Called by the hookscript AFTER it exits (runs detached from Proxmox task).
# Usage: reclone.sh <vmid>

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

VMID="${1:-}"
[[ -n "$VMID" ]] || { log_error "reclone: missing VMID argument"; exit 1; }

load_infra_config

if pool_is_draining; then
    logger -t github-runner "reclone: pool drain active, skipping VM $VMID"
    exit 0
fi

# Read name and org from the stopped VM's config (still exists, just stopped)
NAME=$(qm config "$VMID" 2>/dev/null | awk '/^name:/{print $2}') || true
ORG=$(get_vm_org "$VMID") || true

if [[ -z "$NAME" || -z "$ORG" || "$ORG" == "unknown" ]]; then
    logger -t github-runner "reclone: could not identify VM $VMID (name=$NAME org=$ORG), skipping"
    exit 0
fi

# Per-runner lock prevents races with watch.sh cloning the same slot
exec 200>"/run/lock/runner-${NAME}.lock"
flock -n 200 || { log_info "reclone: another process is handling $NAME"; exit 0; }

if pool_is_draining; then
    logger -t github-runner "reclone: pool drain active for $NAME, skipping"
    exit 0
fi

# Backoff: defer to the watcher only after N consecutive rapid deaths.
# A single fast reclone is normal — short linter jobs (~45s) complete well
# inside any time-based window, so the old 120s blanket backoff misfired on
# every short job. A *streak* of rapid deaths is what indicates a real
# config error (bad PAT, network, cloud-init failure) worth deferring.
RECLONE_TS="/run/runner-${NAME}.reclone-ts"
FAIL_STREAK_FILE="/run/runner-${NAME}.fail-streak"
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
load_org_config "$ORG"
if clone_runner "$NAME" "$ORG" >/dev/null; then
    log_info "reclone: re-cloned $NAME for org $ORG"
else
    log_error "reclone: failed to re-clone $NAME for org $ORG"
    exit 1
fi
