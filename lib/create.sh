#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "create"

load_infra_config

# Parse arguments: [--org <org>] [--labels <labels>] <runner-name>
ORG_FLAG=""
LABELS_FLAG=""
RUNNER_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --org) [[ $# -ge 2 ]] || { log_error "--org requires a value"; exit 1; }; ORG_FLAG="$2"; shift 2 ;;
        --org=*) ORG_FLAG="${1#--org=}"; [[ -n "$ORG_FLAG" ]] || { log_error "--org requires a value"; exit 1; }; shift ;;
        --labels) [[ $# -ge 2 ]] || { log_error "--labels requires a value"; exit 1; }; LABELS_FLAG="$2"; shift 2 ;;
        --labels=*) LABELS_FLAG="${1#--labels=}"; [[ -n "$LABELS_FLAG" ]] || { log_error "--labels requires a value"; exit 1; }; shift ;;
        -*) log_error "Unknown option: $1"; exit 1 ;;
        *) [[ -z "$RUNNER_NAME" ]] || { log_error "Unexpected argument: $1"; exit 1; }; RUNNER_NAME="$1"; shift ;;
    esac
done

if [[ -z "$RUNNER_NAME" ]]; then
    echo "Usage: runner create [--org <org>] [--labels <labels>] <runner-name>"
    echo ""
    echo "Examples:"
    echo "  runner create runner-01"
    echo "  runner create --org MyOrg runner-01"
    echo "  runner create --labels docker,gpu runner-01"
    exit 1
fi

# Validate labels format (comma-separated alphanumeric with hyphens/underscores)
if [[ -n "$LABELS_FLAG" && ! "$LABELS_FLAG" =~ ^[a-zA-Z0-9_-]+(,[a-zA-Z0-9_-]+)*$ ]]; then
    log_error "Invalid labels format: $LABELS_FLAG"
    log_error "Use comma-separated labels with letters, numbers, hyphens, underscores."
    exit 1
fi

# Validate runner name format
if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    log_error "Invalid runner name: $RUNNER_NAME"
    log_error "Use only letters, numbers, dots, hyphens, underscores. Must start with letter or number."
    exit 1
fi

# Select and load org
SELECTED_ORG=$(select_org "$ORG_FLAG") || exit 1
load_org_config "$SELECTED_ORG"

# Validate required config variables
for var in GITHUB_ORG GITHUB_PAT TEMPLATE_ID VM_STORAGE; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Missing required config variable: $var"
        log_error "Re-run 'runner setup' to fix configuration."
        exit 1
    fi
done

# Verify template exists
if ! qm status "$TEMPLATE_ID" &> /dev/null; then
    log_error "Template VM $TEMPLATE_ID does not exist"
    log_error "Run 'runner setup' to create it."
    exit 1
fi

# Verify org cloud-init snippet exists
if [[ ! -f "$SNIPPETS_DIR/runner-user-data-${SELECTED_ORG}.yaml" ]]; then
    log_error "Cloud-init snippet for org '$SELECTED_ORG' not found"
    log_error "Run 'runner add-org' to regenerate it."
    exit 1
fi

# Lock file to prevent race conditions
LOCK_FILE="/var/lock/github-runner-create.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_error "Another runner creation is in progress. Please wait."
    exit 1
fi

# Check if a VM with this name already exists (inside lock to prevent race)
QM_LIST=$(qm list) || { log_error "Failed to list VMs — is Proxmox running?"; exit 1; }
EXISTING_VM=$(echo "$QM_LIST" | awk -v name="$RUNNER_NAME" '$2 == name {print $1}')
if [[ -n "$EXISTING_VM" ]]; then
    log_error "A VM named '$RUNNER_NAME' already exists (VMID: $EXISTING_VM)"
    log_error "Choose a different name or destroy the existing VM first."
    exit 1
fi

# Get next available VM ID (inside lock to prevent race)
if ! NEXT_ID=$(pvesh get /cluster/nextid 2>&1); then
    log_error "Failed to get next VM ID from Proxmox: $NEXT_ID"
    exit 1
fi
read -rp "VM ID [$NEXT_ID]: " VMID
VMID=${VMID:-$NEXT_ID}

# Validate VMID
if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    log_error "VM ID must be a number"
    exit 1
fi
if [[ "$VMID" -lt 100 || "$VMID" -gt 999999999 ]]; then
    log_error "VM ID must be between 100 and 999999999"
    exit 1
fi

# Check if VMID is already in use
if qm status "$VMID" &> /dev/null; then
    log_error "VM ID $VMID is already in use"
    exit 1
fi

# Show confirmation
echo ""
echo "Creating runner:"
echo "  Name:     $RUNNER_NAME"
echo "  VMID:     $VMID"
echo "  Template: $TEMPLATE_ID"
echo "  Org:      $GITHUB_ORG"
if [[ -n "$LABELS_FLAG" ]]; then
    echo "  Labels:   self-hosted,linux,x64,$LABELS_FLAG"
else
    echo "  Labels:   self-hosted,linux,x64 (default)"
fi
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 0

# Cleanup on failure after VM is cloned
VM_CLONED=false
cleanup_vm() {
    if [[ "$VM_CLONED" == true ]]; then
        log_warn "Cleaning up failed VM $VMID..."
        rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml"
        qm stop "$VMID" --timeout 10 2>/dev/null || true
        qm destroy "$VMID" --purge 2>/dev/null || true
    fi
}
trap cleanup_vm EXIT

log_info "Cloning template..."
if ! qm clone "$TEMPLATE_ID" "$VMID" --name "$RUNNER_NAME" --full --storage "$VM_STORAGE"; then
    log_error "Failed to clone template"
    exit 1
fi
VM_CLONED=true

log_info "Configuring cloud-init..."

# Create per-VM meta-data for hostname
cat > "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" << METAEOF
instance-id: "$RUNNER_NAME"
local-hostname: "$RUNNER_NAME"
METAEOF

# Create per-VM vendor-data to override labels if custom labels provided
CICUSTOM="user=local:snippets/runner-user-data-${SELECTED_ORG}.yaml,meta=local:snippets/runner-${VMID}-meta.yaml"
if [[ -n "$LABELS_FLAG" ]]; then
    cat > "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml" << VENDOREOF
#cloud-config
write_files:
  - path: /etc/github-runner/labels.env
    permissions: '0600'
    content: |
      RUNNER_LABELS="self-hosted,linux,x64,$LABELS_FLAG"
VENDOREOF
    CICUSTOM="${CICUSTOM},vendor=local:snippets/runner-${VMID}-vendor.yaml"
fi

if ! qm set "$VMID" --cicustom "$CICUSTOM"; then
    log_error "Failed to set cloud-init config"
    exit 1
fi

if ! qm set "$VMID" --ipconfig0 ip=dhcp; then
    log_error "Failed to set IP config"
    exit 1
fi

if ! qm set "$VMID" --ciuser runner; then
    log_error "Failed to set cloud-init user"
    exit 1
fi

log_info "Starting VM..."
if ! qm start "$VMID"; then
    log_error "Failed to start VM"
    exit 1
fi

# VM start was accepted by Proxmox — disable destructive cleanup trap
# from this point on. A transient status-check failure should not destroy
# a VM that Proxmox already acknowledged starting.
trap - EXIT

# Wait briefly and verify VM is running (advisory check only)
sleep 2
VM_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || true
if [[ "$VM_STATUS" != "running" ]]; then
    log_warn "VM may not be running yet (status: ${VM_STATUS:-unknown})"
    log_warn "Check manually: qm status $VMID"
fi
flock -u 200

echo ""
log_info "Runner '$RUNNER_NAME' created successfully (VMID: $VMID)"
echo ""
echo "The runner will appear in GitHub in ~2-3 minutes:"
echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
echo ""
echo "To watch setup progress:"
echo "  qm guest exec $VMID -- tail -f /var/log/cloud-init-output.log"
echo ""
echo "To check runner service status:"
echo "  qm guest exec $VMID -- systemctl status actions.runner.*"
echo ""
