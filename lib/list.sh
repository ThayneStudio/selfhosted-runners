#!/bin/bash
set -euo pipefail
# List all runner VMs.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

TEMPLATE_ID=""
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

echo ""
printf "%-8s %-25s %-15s %-10s\n" "VMID" "NAME" "ORG" "STATUS"
printf "%-8s %-25s %-15s %-10s\n" "----" "----" "---" "------"

COUNT=0
ALL_VMS=$(qm list 2>/dev/null | tail -n +2) || true
while read -r line; do
    [[ -z "$line" ]] && continue
    vmid=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $3}')

    [[ -n "$TEMPLATE_ID" && "$vmid" == "$TEMPLATE_ID" ]] && continue

    # Only show VMs with a runner cloud-init snippet
    org=$(get_vm_org "$vmid")
    [[ "$org" != "unknown" ]] || continue

    printf "%-8s %-25s %-15s %-10s\n" "$vmid" "$name" "$org" "$status"
    COUNT=$((COUNT + 1))
done <<< "$ALL_VMS"

echo ""
if [[ $COUNT -gt 0 ]]; then
    echo "Total: $COUNT runner(s)"
else
    echo "(no runners found)"
fi
echo ""
