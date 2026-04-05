#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "list-orgs"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration not found. Run 'runner setup' first."
    exit 1
fi

mapfile -t orgs < <(list_orgs)

echo ""
printf '%b=== Configured GitHub Organizations ===%b\n' "$CYAN" "$NC"
echo ""

if [[ ${#orgs[@]} -eq 0 ]]; then
    echo "(none)"
    echo ""
    echo "Add one with:"
    echo "  runner add-org"
    exit 0
fi

# Load template ID to filter it out
TEMPLATE_ID=""
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Count runners per org (only VMs with runner cloud-init config)
declare -A org_runner_counts
ALL_VMS=$(qm list 2>/dev/null | tail -n +2 || true)
if [[ -n "$ALL_VMS" ]]; then
    while read -r line; do
        VMID=$(echo "$line" | awk '{print $1}')
        # Skip template VM
        if [[ -n "$TEMPLATE_ID" && "$VMID" == "$TEMPLATE_ID" ]]; then
            continue
        fi
        # Only count VMs with runner cloud-init config
        VM_CONFIG=$(qm config "$VMID" 2>/dev/null || true)
        CICUSTOM=$(echo "$VM_CONFIG" | grep "^cicustom:" || true)
        if [[ "$CICUSTOM" == *"runner-user-data"* ]]; then
            VM_ORG=$(get_vm_org "$VMID")
            org_runner_counts[$VM_ORG]=$(( ${org_runner_counts[$VM_ORG]:-0} + 1 ))
        fi
    done <<< "$ALL_VMS"
fi

printf "%-25s %-20s %-10s\n" "ORGANIZATION" "PAT" "RUNNERS"
printf "%-25s %-20s %-10s\n" "------------" "---" "-------"

for org in "${orgs[@]}"; do
    # Read PAT for masking (safe extraction without sourcing)
    local_pat=$(grep '^GITHUB_PAT=' "$ORG_CONFIG_DIR/${org}.conf" 2>/dev/null | head -1 | sed 's/^GITHUB_PAT=//' | tr -d '"' || true)
    if [[ ${#local_pat} -ge 12 ]]; then
        masked_pat="${local_pat:0:4}...${local_pat: -4}"
    elif [[ -n "$local_pat" ]]; then
        masked_pat="${local_pat:0:4}..."
    else
        masked_pat="(missing)"
    fi
    count="${org_runner_counts[$org]:-0}"
    printf "%-25s %-20s %-10s\n" "$org" "$masked_pat" "$count"
done

echo ""
