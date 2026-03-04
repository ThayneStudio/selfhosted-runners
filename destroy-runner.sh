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

# Load configuration (optional - for GitHub URL display)
CONFIG_FILE="/etc/github-runners.conf"
GITHUB_ORG=""
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Validate runner name argument
RUNNER_NAME=${1:-}
if [[ -z "$RUNNER_NAME" ]]; then
    echo "Usage: ./destroy-runner.sh <runner-name>"
    echo ""
    echo "Current runners:"
    qm list | awk 'NR==1 || $2 ~ /^runner-/ || $2 ~ /^build-/'
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

# Get VM status for display
VM_STATUS=$(qm status $VMID 2>/dev/null | awk '{print $2}' || echo "unknown")
VM_CONFIG=$(qm config $VMID 2>/dev/null || true)
VM_MEMORY=$(echo "$VM_CONFIG" | grep "^memory:" | awk '{print $2}')
VM_CORES=$(echo "$VM_CONFIG" | grep "^cores:" | awk '{print $2}')

echo ""
echo "Runner to destroy:"
echo "  Name:   $RUNNER_NAME"
echo "  VMID:   $VMID"
echo "  Status: $VM_STATUS"
echo "  Spec:   ${VM_CORES:-?} cores, ${VM_MEMORY:-?} MB RAM"
echo ""
log_warn "This action cannot be undone!"
echo ""
read -p "Type 'yes' to confirm destruction: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    log_info "Aborted."
    exit 0
fi

# Stop VM if running
if [[ "$VM_STATUS" == "running" ]]; then
    log_info "Stopping VM..."
    if ! qm stop $VMID --timeout 30; then
        log_warn "Graceful stop failed, forcing..."
        qm stop $VMID --skiplock 2>/dev/null || true
    fi
    sleep 2
fi

# Destroy VM
log_info "Destroying VM..."
if ! qm destroy $VMID --purge; then
    log_error "Failed to destroy VM"
    exit 1
fi

echo ""
log_info "Runner '$RUNNER_NAME' (VMID: $VMID) destroyed."
echo ""
if [[ -n "$GITHUB_ORG" ]]; then
    log_warn "The runner may still appear as 'Offline' in GitHub."
    echo "Remove it manually at:"
    echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
else
    log_warn "The runner may still appear as 'Offline' in GitHub."
    echo "Remove it manually from your organization's Actions settings."
fi
echo ""
