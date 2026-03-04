#!/bin/bash
set -euo pipefail

RUNNER_NAME=${1:?Usage: ./destroy-runner.sh <runner-name>}

# Find VM ID by name
VMID=$(qm list | grep -w "$RUNNER_NAME" | awk '{print $1}')

if [[ -z "$VMID" ]]; then
    echo "Error: Runner '$RUNNER_NAME' not found"
    echo ""
    echo "Available runners:"
    qm list | grep -E 'runner-|VMID'
    exit 1
fi

echo "Destroying runner: $RUNNER_NAME (VMID: $VMID)"
read -p "Are you sure? [y/N]: " CONFIRM
[[ "${CONFIRM:-N}" =~ ^[Yy]$ ]] || exit 0

# Stop and destroy
qm stop $VMID --skiplock 2>/dev/null || true
sleep 2
qm destroy $VMID --purge

echo ""
echo "Runner '$RUNNER_NAME' destroyed."
echo ""
echo "Note: The runner may still appear in GitHub settings as 'Offline'."
echo "      You can remove it manually from:"
echo "      https://github.com/organizations/<org>/settings/actions/runners"
echo ""
