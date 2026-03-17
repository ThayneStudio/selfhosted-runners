#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

# Load config (optional)
TEMPLATE_ID=""
if [[ -f "$CONFIG_FILE" ]]; then
    migrate_config_if_needed
    source "$CONFIG_FILE"
fi

echo ""
printf '%b=== GitHub Actions Runner VMs ===%b\n' "$CYAN" "$NC"
echo ""

# Get all VMs and filter for likely runners
# Exclude the template VM
ALL_VMS=$(qm list 2>/dev/null | tail -n +2 || true)

if [[ -z "$ALL_VMS" ]]; then
    echo "No VMs found."
    echo ""
    echo "Create a runner with:"
    echo "  runner create runner-01"
    exit 0
fi

# Print header
printf "%-8s %-20s %-15s %-10s %-10s %-10s\n" "VMID" "NAME" "ORG" "STATUS" "CORES" "MEMORY"
printf "%-8s %-20s %-15s %-10s %-10s %-10s\n" "----" "----" "---" "------" "-----" "------"

RUNNER_COUNT=0
declare -A seen_orgs
while read -r line; do
    [[ -z "$line" ]] && continue
    VMID=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | awk '{print $2}')
    STATUS=$(echo "$line" | awk '{print $3}')

    # Skip the template
    if [[ -n "$TEMPLATE_ID" && "$VMID" == "$TEMPLATE_ID" ]]; then
        continue
    fi

    # Get VM config for details
    VM_CONFIG=$(qm config "$VMID" 2>/dev/null || true)
    CORES=$(echo "$VM_CONFIG" | grep "^cores:" | awk '{print $2}' || true)
    MEMORY=$(echo "$VM_CONFIG" | grep "^memory:" | awk '{print $2}' || true)

    # Check if it has our cloud-init config (likely a runner)
    CICUSTOM=$(echo "$VM_CONFIG" | grep "^cicustom:" || true)
    if [[ "$CICUSTOM" == *"runner-user-data"* ]]; then
        VM_ORG=$(get_vm_org "$VMID")
        seen_orgs[$VM_ORG]=1
        printf "%-8s %-20s %-15s %-10s %-10s %-10s\n" "$VMID" "$NAME" "$VM_ORG" "$STATUS" "${CORES:-?}" "${MEMORY:-?}MB"
        RUNNER_COUNT=$((RUNNER_COUNT + 1))
    fi
done <<< "$ALL_VMS"

if [[ "$RUNNER_COUNT" -eq 0 ]]; then
    echo "(no runners found)"
    echo ""
    echo "Create a runner with:"
    echo "  runner create runner-01"
else
    echo ""
    printf '%bTotal: %s runner(s)%b\n' "$GREEN" "$RUNNER_COUNT" "$NC"
fi

echo ""

# Show GitHub links for each org that has runners
for org in "${!seen_orgs[@]}"; do
    if [[ "$org" != "unknown" ]]; then
        echo "View $org runners in GitHub:"
        echo "  https://github.com/organizations/$org/settings/actions/runners"
    fi
done
if [[ ${#seen_orgs[@]} -gt 0 ]]; then
    echo ""
fi
