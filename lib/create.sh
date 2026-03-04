#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Resolve symlinks to find real script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done

# Load configuration
CONFIG_FILE="/etc/github-runners.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration not found at $CONFIG_FILE"
    log_error "Run ./setup.sh first."
    exit 1
fi
source "$CONFIG_FILE"

# Validate required config variables
for var in GITHUB_ORG GITHUB_PAT TEMPLATE_ID VM_STORAGE; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Missing required config variable: $var"
        log_error "Re-run ./setup.sh to fix configuration."
        exit 1
    fi
done

# Validate runner name argument
RUNNER_NAME=${1:-}
if [[ -z "$RUNNER_NAME" ]]; then
    echo "Usage: ./create-runner.sh <runner-name>"
    echo ""
    echo "Examples:"
    echo "  ./create-runner.sh runner-01"
    echo "  ./create-runner.sh build-worker-1"
    exit 1
fi

# Validate runner name format
if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    log_error "Invalid runner name: $RUNNER_NAME"
    log_error "Use only letters, numbers, dots, hyphens, underscores. Must start with letter or number."
    exit 1
fi

# Check if a VM with this name already exists
EXISTING_VM=$(qm list | awk -v name="$RUNNER_NAME" '$2 == name {print $1}')
if [[ -n "$EXISTING_VM" ]]; then
    log_error "A VM named '$RUNNER_NAME' already exists (VMID: $EXISTING_VM)"
    log_error "Choose a different name or destroy the existing VM first."
    exit 1
fi

# Verify template exists
if ! qm status $TEMPLATE_ID &> /dev/null; then
    log_error "Template VM $TEMPLATE_ID does not exist"
    log_error "Run ./setup.sh to create it."
    exit 1
fi

# Lock file to prevent race conditions
LOCK_FILE="/tmp/github-runner-create.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_error "Another runner creation is in progress. Please wait."
    exit 1
fi

# Get next available VM ID (inside lock to prevent race)
VMID=$(pvesh get /cluster/nextid)

# Show confirmation
echo ""
echo "Creating runner:"
echo "  Name:     $RUNNER_NAME"
echo "  VMID:     $VMID"
echo "  Template: $TEMPLATE_ID"
echo "  Org:      $GITHUB_ORG"
echo ""
read -p "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]$ ]] || exit 0

log_info "Cloning template..."
if ! qm clone $TEMPLATE_ID $VMID --name "$RUNNER_NAME" --full; then
    log_error "Failed to clone template"
    exit 1
fi

log_info "Configuring cloud-init..."
if ! qm set $VMID --cicustom "user=local:snippets/runner-user-data.yaml"; then
    log_error "Failed to set cloud-init config"
    qm destroy $VMID --purge 2>/dev/null || true
    exit 1
fi

if ! qm set $VMID --ipconfig0 ip=dhcp; then
    log_error "Failed to set IP config"
    qm destroy $VMID --purge 2>/dev/null || true
    exit 1
fi

if ! qm set $VMID --ciuser runner; then
    log_error "Failed to set cloud-init user"
    qm destroy $VMID --purge 2>/dev/null || true
    exit 1
fi

log_info "Starting VM..."
if ! qm start $VMID; then
    log_error "Failed to start VM"
    qm destroy $VMID --purge 2>/dev/null || true
    exit 1
fi

# Wait briefly and check if VM is running
sleep 2
VM_STATUS=$(qm status $VMID 2>/dev/null | awk '{print $2}')
if [[ "$VM_STATUS" != "running" ]]; then
    log_error "VM failed to start (status: $VM_STATUS)"
    exit 1
fi

# Release lock
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
