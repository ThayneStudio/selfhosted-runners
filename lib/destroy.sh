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
    qm list | awk 'NR==1 || $2 ~ /^runner-/ || $2 ~ /^build-/'
    exit 1
fi

# Validate runner name format (reject clearly malicious input)
if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    log_error "Invalid runner name: $RUNNER_NAME"
    log_error "Use only letters, numbers, dots, hyphens, underscores. Must start with letter or number."
    exit 1
fi

# Find VM ID by exact name match
VMID=$(qm list | awk -v name="$RUNNER_NAME" '$2 == name {print $1}')

if [[ -z "$VMID" ]]; then
    log_error "Runner '$RUNNER_NAME' not found"
    echo ""
    echo "Available VMs:"
    qm list | head -1
    qm list | tail -n +2 | sort -k2
    exit 1
fi

# Check for multiple matches (shouldn't happen with exact match, but be safe)
MATCH_COUNT=$(echo "$VMID" | wc -l)
if [[ "$MATCH_COUNT" -gt 1 ]]; then
    log_error "Multiple VMs found matching '$RUNNER_NAME'. This shouldn't happen."
    echo "Matches:"
    echo "$VMID"
    exit 1
fi

# Resolve org from VM's cloud-init config
VM_ORG=$(get_vm_org "$VMID")

# Get VM status for display
VM_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || VM_STATUS="unknown"
[[ -z "$VM_STATUS" ]] && VM_STATUS="unknown"
VM_CONFIG=$(qm config "$VMID" 2>/dev/null || true)
VM_MEMORY=$(echo "$VM_CONFIG" | grep "^memory:" | awk '{print $2}' || true)
VM_CORES=$(echo "$VM_CONFIG" | grep "^cores:" | awk '{print $2}' || true)

echo ""
echo "Runner to destroy:"
echo "  Name:   $RUNNER_NAME"
echo "  VMID:   $VMID"
echo "  Status: $VM_STATUS"
echo "  Org:    $VM_ORG"
echo "  Spec:   ${VM_CORES:-?} cores, ${VM_MEMORY:-?} MB RAM"
echo ""
log_warn "This action cannot be undone!"
echo ""
read -rp "Type 'yes' to confirm destruction: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    log_info "Aborted."
    exit 0
fi

# Stop VM if not already stopped
if [[ "$VM_STATUS" != "stopped" && "$VM_STATUS" != "unknown" ]]; then
    log_info "Stopping VM (status: $VM_STATUS)..."
    if ! qm stop "$VMID" --timeout 30; then
        log_warn "Graceful stop failed, forcing..."
        qm stop "$VMID" --skiplock 2>/dev/null || true
    fi
    # Wait for VM to actually stop
    current_status=""
    for i in {1..15}; do
        current_status=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || true
        if [[ "$current_status" == "stopped" ]]; then
            break
        fi
        sleep 1
    done
    if [[ "$current_status" != "stopped" ]]; then
        log_warn "VM may not be fully stopped (status: ${current_status:-unknown}), attempting destroy anyway"
    fi
fi

# Destroy VM
log_info "Destroying VM..."
if ! qm destroy "$VMID" --purge; then
    log_error "Failed to destroy VM $VMID"
    log_error "You may need to manually stop it first: qm stop $VMID --skiplock"
    exit 1
fi

# Clean up per-VM meta-data snippet
rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml"

echo ""
log_info "Runner '$RUNNER_NAME' (VMID: $VMID) destroyed."
echo ""
if [[ "$VM_ORG" != "unknown" ]]; then
    log_warn "The runner may still appear as 'Offline' in GitHub."
    echo "Remove it manually at:"
    echo "  https://github.com/organizations/$VM_ORG/settings/actions/runners"
else
    log_warn "The runner may still appear as 'Offline' in GitHub."
    echo "Remove it manually from your organization's Actions settings."
fi
echo ""
