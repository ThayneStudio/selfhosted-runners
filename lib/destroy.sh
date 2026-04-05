#!/bin/bash
set -euo pipefail
# Manually destroy a runner VM.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "destroy"

RUNNER_NAME=${1:-}
if [[ -z "$RUNNER_NAME" ]]; then
    echo "Usage: runner destroy <runner-name>"
    exit 1
fi

if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    log_error "Invalid runner name: $RUNNER_NAME"
    exit 1
fi

# Find VM by exact name
VMID=$(qm list | awk -v n="$RUNNER_NAME" '$2==n {print $1}')
[[ -n "$VMID" ]] || { log_error "'$RUNNER_NAME' not found"; exit 1; }

VM_ORG=$(get_vm_org "$VMID")

# Remove hookscript to prevent auto-destroy from racing with us
qm set "$VMID" --delete hookscript 2>/dev/null || true

# Stop if running
STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || true
if [[ "$STATUS" == "running" ]]; then
    log_info "Stopping $RUNNER_NAME..."
    qm stop "$VMID" --timeout 30 2>/dev/null || qm stop "$VMID" --skiplock 2>/dev/null || true
fi

# Deregister from GitHub (best-effort)
[[ "$VM_ORG" == "unknown" ]] || deregister_runner "$VM_ORG" "$RUNNER_NAME" || true

# Destroy
log_info "Destroying $RUNNER_NAME (VMID $VMID)..."
qm destroy "$VMID" --purge || { log_error "Failed to destroy $VMID"; exit 1; }

# Clean up snippets
rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml"

log_info "$RUNNER_NAME destroyed. Watcher will recreate on next tick."
