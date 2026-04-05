#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "destroy"

# Load config (optional — for org resolution)
if [[ -f "$CONFIG_FILE" ]]; then
    migrate_config_if_needed
fi

# Reject flags
if [[ "${1:-}" == -* ]]; then
    log_error "Unknown option: $1"
    echo "Usage: runner destroy <runner-name>"
    exit 1
fi

# Reject extra arguments
if [[ $# -gt 1 ]]; then
    log_error "Unexpected argument: $2"
    echo "Usage: runner destroy <runner-name>"
    exit 1
fi

# Validate runner name argument
RUNNER_NAME=${1:-}
if [[ -z "$RUNNER_NAME" ]]; then
    echo "Usage: runner destroy <runner-name>"
    echo ""
    echo "Current runners:"
    qm list | awk 'NR==1 || /runner/'
    exit 1
fi

if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    log_error "Invalid runner name: $RUNNER_NAME"
    exit 1
fi

# Find VM ID by exact name match
VMID=$(qm list | awk -v name="$RUNNER_NAME" '$2 == name {print $1}')

if [[ -z "$VMID" ]]; then
    log_error "Runner '$RUNNER_NAME' not found"
    echo ""
    echo "Available VMs:"
    qm list
    exit 1
fi

MATCH_COUNT=$(echo "$VMID" | wc -l)
if [[ "$MATCH_COUNT" -gt 1 ]]; then
    log_error "Multiple VMs found matching '$RUNNER_NAME':"
    echo "$VMID"
    exit 1
fi

# Resolve org from VM's cloud-init config
VM_ORG=$(get_vm_org "$VMID")

# Get VM info for display
VM_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || VM_STATUS="unknown"

echo ""
echo "Runner to destroy:"
echo "  Name:   $RUNNER_NAME"
echo "  VMID:   $VMID"
echo "  Status: $VM_STATUS"
echo "  Org:    $VM_ORG"
echo ""
log_warn "This action cannot be undone!"
echo ""
read -rp "Type 'yes' to confirm destruction: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    log_info "Aborted."
    exit 0
fi

# Remove hookscript BEFORE stopping to prevent auto-destroy from racing
qm set "$VMID" --delete hookscript 2>/dev/null || true

# Stop VM if not already stopped
if [[ "$VM_STATUS" != "stopped" && "$VM_STATUS" != "unknown" ]]; then
    log_info "Stopping VM..."
    qm stop "$VMID" --timeout 30 2>/dev/null || {
        qm stop "$VMID" --skiplock 2>/dev/null || true
    }
    for i in {1..15}; do
        current=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || true
        [[ "$current" == "stopped" ]] && break
        sleep 1
    done
fi

# Deregister from GitHub (best-effort)
if [[ "$VM_ORG" != "unknown" ]]; then
    log_info "Deregistering runner from GitHub..."
    deregister_runner "$VM_ORG" "$RUNNER_NAME" || true
fi

# Destroy VM
log_info "Destroying VM..."
if ! qm destroy "$VMID" --purge; then
    log_error "Failed to destroy VM $VMID"
    exit 1
fi

# Clean up snippets
rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml"

echo ""
log_info "Runner '$RUNNER_NAME' (VMID: $VMID) destroyed."
echo "The pool watcher will automatically replace it on the next tick (~30s)."
echo ""
