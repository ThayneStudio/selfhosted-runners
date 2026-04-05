#!/bin/bash
set -uo pipefail
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

# Destroy the old VM
rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml"
qm destroy "$VMID" --purge 2>&1 | logger -t github-runner || true

# Check if someone else already filled this slot (watcher, manual create)
if qm list 2>/dev/null | awk '{print $2}' | grep -qxF "$NAME"; then
    log_info "reclone: $NAME already exists, skipping"
    exit 0
fi

# Clone replacement
load_org_config "$ORG"
clone_runner "$NAME" "$ORG" >/dev/null \
    && log_info "reclone: re-cloned $NAME for org $ORG" \
    || log_error "reclone: failed to re-clone $NAME for org $ORG"
