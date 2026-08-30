#!/bin/bash
set -euo pipefail
# List all runner VMs.

if [[ -n "${RUNNER_LIST_LOADED:-}" ]]; then
    return 0
fi
RUNNER_LIST_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

TEMPLATE_ID=""
# shellcheck source=/dev/null  # host config, written by setup at runtime
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

list_runners() {
    local COUNT=0 ALL_VMS line vmid name status org gen

    echo ""
    printf "%-8s %-25s %-15s %-10s %-8s\n" "VMID" "NAME" "ORG" "STATUS" "GEN"
    printf "%-8s %-25s %-15s %-10s %-8s\n" "----" "----" "---" "------" "---"

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

        gen=$(get_vm_generation "$vmid")
        [[ -n "$gen" ]] || gen="-"

        printf "%-8s %-25s %-15s %-10s %-8s\n" "$vmid" "$name" "$org" "$status" "$gen"
        COUNT=$((COUNT + 1))
    done <<< "$ALL_VMS"

    echo ""
    if [[ $COUNT -gt 0 ]]; then
        echo "Total: $COUNT runner(s)"
    else
        echo "(no runners found)"
    fi
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    list_runners "$@"
fi
