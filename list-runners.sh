#!/bin/bash
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load configuration (optional - for GitHub URL)
CONFIG_FILE="/etc/github-runners.conf"
GITHUB_ORG=""
TEMPLATE_ID=""
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

echo ""
echo -e "${CYAN}=== GitHub Actions Runner VMs ===${NC}"
echo ""

# Get all VMs and filter for likely runners
# Exclude the template VM
ALL_VMS=$(qm list 2>/dev/null | tail -n +2 || true)

if [[ -z "$ALL_VMS" ]]; then
    echo "No VMs found."
    echo ""
    echo "Create a runner with:"
    echo "  ./create-runner.sh runner-01"
    exit 0
fi

# Print header
printf "%-8s %-20s %-10s %-10s %-10s\n" "VMID" "NAME" "STATUS" "CORES" "MEMORY"
printf "%-8s %-20s %-10s %-10s %-10s\n" "----" "----" "------" "-----" "------"

RUNNER_COUNT=0
while read -r line; do
    VMID=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | awk '{print $2}')
    STATUS=$(echo "$line" | awk '{print $3}')

    # Skip the template
    if [[ -n "$TEMPLATE_ID" && "$VMID" == "$TEMPLATE_ID" ]]; then
        continue
    fi

    # Skip if it's clearly not a runner (template keyword)
    if [[ "$NAME" == *"template"* ]]; then
        continue
    fi

    # Get VM config for details
    VM_CONFIG=$(qm config $VMID 2>/dev/null || true)
    CORES=$(echo "$VM_CONFIG" | grep "^cores:" | awk '{print $2}')
    MEMORY=$(echo "$VM_CONFIG" | grep "^memory:" | awk '{print $2}')

    # Check if it has our cloud-init config (likely a runner)
    CICUSTOM=$(echo "$VM_CONFIG" | grep "^cicustom:" || true)
    if [[ "$CICUSTOM" == *"runner-user-data"* ]]; then
        # Definitely a runner
        printf "%-8s %-20s " "$VMID" "$NAME"
        if [[ "$STATUS" == "running" ]]; then
            echo -e "${GREEN}%-10s${NC} %-10s %-10s\n" "$STATUS" "${CORES:-?}" "${MEMORY:-?}MB" | xargs printf "%-10s %-10s %-10s\n"
        else
            printf "%-10s %-10s %-10s\n" "$STATUS" "${CORES:-?}" "${MEMORY:-?}MB"
        fi
        ((RUNNER_COUNT++))
    fi
done <<< "$ALL_VMS"

if [[ "$RUNNER_COUNT" -eq 0 ]]; then
    echo "(no runners found)"
    echo ""
    echo "Create a runner with:"
    echo "  ./create-runner.sh runner-01"
else
    echo ""
    echo -e "${GREEN}Total: $RUNNER_COUNT runner(s)${NC}"
fi

echo ""

# Show GitHub link if we have the org
if [[ -n "$GITHUB_ORG" ]]; then
    echo "View in GitHub:"
    echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
    echo ""
fi
