#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/recycle.sh"

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
    # The org's VMs are retired, not orphaned: reclone.sh and the watcher
    # destroy a VM of an org that is no longer configured and clone nothing
    # in its place (runner_slot_retired in recycle.sh). Destroying a slot
    # before the removal only makes the watcher clone it again. GitHub
    # removes an ephemeral runner that has been offline for a day.
    log_warn "$RUNNER_COUNT runner VM(s) of '$ORG_NAME' remain. Once the org is removed, each one is destroyed,"
    log_warn "not re-cloned, when it stops: after the one job it runs, or at its 6-hour idle shutdown."
    log_warn "To remove them sooner, run 'runner destroy <name>' for each once the org is removed."
    log_warn "GitHub removes an idle runner's registration a day after it goes offline."
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
# The org's extra runners from `runner create` end with it. The watcher fills
# none of an org that is not configured, so a leftover entry waits harmlessly.
forget_extra_runners "" "$ORG_NAME" \
    || log_warn "Could not remove the extra runners of '$ORG_NAME' from $EXTRA_RUNNERS_FILE"

echo ""
log_info "Organization '$ORG_NAME' removed."
echo ""
