#!/bin/bash
set -euo pipefail
# Destroy a stopped VM and clone a replacement with the same name/org.
# Called by the hookscript AFTER it exits (runs detached from Proxmox task).
# Usage: reclone.sh <vmid>

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

VMID="${1:-}"
[[ -n "$VMID" ]] || { log_error "reclone: missing VMID argument"; exit 1; }

load_infra_config

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

# Backoff: if this slot was recloned less than 2 minutes ago, the VM likely
# has a config error (bad PAT, network) and would just fail again. Defer to
# the watcher's 30s schedule to avoid a tight boot-fail-reclone loop.
RECLONE_TS="/run/runner-${NAME}.reclone-ts"
if [[ -f "$RECLONE_TS" ]]; then
    LAST=$(cat "$RECLONE_TS" 2>/dev/null) || LAST=0
    NOW=$(date +%s)
    if (( NOW - LAST < 120 )); then
        logger -t github-runner "reclone: $NAME died within 2min of last reclone, deferring to watcher"
        # Still destroy the failed VM to free resources
        rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml"
        qm destroy "$VMID" --purge 2>/dev/null || true
        exit 0
    fi
fi

# Destroy the old VM (retry briefly in case Proxmox lock hasn't released)
rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml"
for attempt in 1 2 3; do
    destroy_output=$(qm destroy "$VMID" --purge 2>&1) && destroy_rc=0 || destroy_rc=$?
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
if qm list 2>/dev/null | awk 'NR>1{print $2}' | grep -qxF "$NAME"; then
    log_info "reclone: $NAME already exists, skipping"
    exit 0
fi

# Clone replacement
load_org_config "$ORG"
if clone_runner "$NAME" "$ORG" >/dev/null; then
    date +%s > "$RECLONE_TS"
    log_info "reclone: re-cloned $NAME for org $ORG"
else
    log_error "reclone: failed to re-clone $NAME for org $ORG"
    exit 1
fi
