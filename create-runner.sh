#!/bin/bash
set -euo pipefail

# Load configuration
if [[ ! -f /etc/github-runners.conf ]]; then
    echo "Error: Configuration not found. Run ./setup.sh first."
    exit 1
fi
source /etc/github-runners.conf

RUNNER_NAME=${1:?Usage: ./create-runner.sh <runner-name>}

# Get next available VM ID
VMID=$(pvesh get /cluster/nextid)

echo "Creating runner: $RUNNER_NAME (VMID: $VMID)"

# Clone template
qm clone $TEMPLATE_ID $VMID --name "$RUNNER_NAME" --full

# Configure cloud-init
qm set $VMID --cicustom "user=local:snippets/runner-user-data.yaml"
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --ciuser runner

# Start VM
qm start $VMID

echo ""
echo "Runner '$RUNNER_NAME' starting (VMID: $VMID)"
echo ""
echo "It will appear in GitHub org settings in ~2-3 minutes."
echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
echo ""
echo "To watch setup progress:"
echo "  qm guest exec $VMID -- tail -f /var/log/cloud-init-output.log"
echo ""
