#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "remove-org"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration not found. Run 'runner setup' first."
    exit 1
fi

ORG_NAME=${1:-}

# Validate org name if provided as argument
if [[ -n "$ORG_NAME" ]] && ! validate_org_name "$ORG_NAME"; then
    log_error "Invalid organization name: $ORG_NAME"
    exit 1
fi

# If no arg, prompt from list
if [[ -z "$ORG_NAME" ]]; then
    mapfile -t orgs < <(list_orgs)
    if [[ ${#orgs[@]} -eq 0 ]]; then
        log_error "No organizations configured."
        exit 1
    fi
    echo ""
    echo "Configured organizations:"
    for i in "${!orgs[@]}"; do
        echo "  $((i + 1))) ${orgs[$i]}"
    done
    echo ""
    while true; do
        read -rp "Select organization to remove (number or name): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#orgs[@]} ]]; then
            ORG_NAME="${orgs[$((choice - 1))]}"
            break
        fi
        for org in "${orgs[@]}"; do
            if [[ "$org" == "$choice" ]]; then
                ORG_NAME="$choice"
                break 2
            fi
        done
        log_error "Invalid selection: $choice"
    done
fi

# Validate org exists
if [[ ! -f "$ORG_CONFIG_DIR/${ORG_NAME}.conf" ]]; then
    log_error "Organization '$ORG_NAME' not found in $ORG_CONFIG_DIR"
    exit 1
fi

# Check for active runners belonging to this org
RUNNER_COUNT=0
ALL_VMS=$(qm list 2>/dev/null | tail -n +2 || true)
if [[ -n "$ALL_VMS" ]]; then
    while read -r line; do
        VMID=$(echo "$line" | awk '{print $1}')
        VM_NAME=$(echo "$line" | awk '{print $2}')
        VM_ORG=$(get_vm_org "$VMID")
        if [[ "$VM_ORG" == "$ORG_NAME" ]]; then
            if [[ $RUNNER_COUNT -eq 0 ]]; then
                log_warn "Active runners found for '$ORG_NAME':"
            fi
            echo "  $VM_NAME (VMID: $VMID)"
            RUNNER_COUNT=$((RUNNER_COUNT + 1))
        fi
    done <<< "$ALL_VMS"
fi

echo ""
if [[ $RUNNER_COUNT -gt 0 ]]; then
    log_warn "$RUNNER_COUNT runner(s) still registered with '$ORG_NAME'."
    log_warn "They will become unmanaged — destroy them first, or remove them from GitHub manually."
    echo ""
fi

echo "This will remove:"
echo "  Config:         $ORG_CONFIG_DIR/${ORG_NAME}.conf"
echo "  Legacy snippet: $SNIPPETS_DIR/runner-user-data-${ORG_NAME}.yaml (if present)"
echo ""
echo "Per-VM snippets are cleaned up when each runner is destroyed."
echo ""
read -rp "Type 'yes' to confirm removal of '$ORG_NAME': " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    log_info "Aborted."
    exit 0
fi

rm -f "$ORG_CONFIG_DIR/${ORG_NAME}.conf"
rm -f "$SNIPPETS_DIR/runner-user-data-${ORG_NAME}.yaml"  # legacy per-org snippet (no-op on new installs)

echo ""
log_info "Organization '$ORG_NAME' removed."
echo ""
