#!/bin/bash
set -euo pipefail
# Pool watcher: ensures each org has its target number of runner VMs.
# Runs via systemd timer every 30s. Clones ONE VM per org per tick.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "watch"

[[ -f "$CONFIG_FILE" ]] || exit 0
load_infra_config

# Template must exist and be a template (not still baking)
qm config "$TEMPLATE_ID" 2>/dev/null | grep -q "^template: 1" || exit 0

# Snapshot all VMs once: "VMID NAME"
ALL_VMS=$(qm list 2>/dev/null | awk 'NR>1 {print $1, $2}') || exit 0
# Extract just names for slot checks
ALL_VM_NAMES=$(echo "$ALL_VMS" | awk '{print $2}')

# Process each org
mapfile -t ORGS < <(list_orgs)
for org in "${ORGS[@]}"; do
    org_file="$ORG_CONFIG_DIR/${org}.conf"
    [[ -f "$org_file" ]] || continue

    count=$(grep '^RUNNER_COUNT=' "$org_file" | head -1 | sed 's/^RUNNER_COUNT=//' | tr -d '"') || true
    prefix=$(grep '^RUNNER_PREFIX=' "$org_file" | head -1 | sed 's/^RUNNER_PREFIX=//' | tr -d '"') || true
    count="${count:-0}"
    prefix="${prefix:-runner}"
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || continue

    # Check snippet exists
    [[ -f "$SNIPPETS_DIR/runner-user-data-${org}.yaml" ]] || continue

    # Find first missing slot
    missing_slot=""
    for n in $(seq 1 "$count"); do
        slot="${prefix}-${n}"
        if ! echo "$ALL_VM_NAMES" | grep -qxF "$slot"; then
            missing_slot="$slot"
            break
        fi
    done

    # Clone ONE missing slot per org per tick
    if [[ -n "$missing_slot" ]]; then
        log_info "[watch] Creating $missing_slot for org $org"
        # Load org config in subshell first to avoid crashing the watcher
        if ! ( load_org_config "$org" ) 2>/dev/null; then
            log_warn "[watch] Org config for '$org' is invalid, skipping"
            continue
        fi
        load_org_config "$org"
        clone_runner "$missing_slot" "$org" >/dev/null \
            || log_warn "[watch] Failed to create $missing_slot"
    fi
done

# Stuck VM detection: force-stop VMs running >30 min without the runner-ready sentinel.
# The hookscript auto-destroys them on stop, and next tick fills the gap.
while read -r vm_id vm_name; do
    [[ -z "$vm_id" ]] && continue

    vm_org=$(get_vm_org "$vm_id")
    [[ -n "$vm_org" && "$vm_org" != "unknown" ]] || continue

    vm_status=$(qm status "$vm_id" 2>/dev/null | awk '{print $2}') || continue
    [[ "$vm_status" == "running" ]] || continue

    sentinel=$(timeout 10 qm guest exec "$vm_id" -- test -f /opt/.runner-ready 2>/dev/null) || continue
    sentinel_exit=$(echo "$sentinel" | jq -r '.exitcode // "1"' 2>/dev/null) || sentinel_exit="1"
    [[ "$sentinel_exit" == "0" ]] && continue

    uptime_result=$(timeout 10 qm guest exec "$vm_id" -- cat /proc/uptime 2>/dev/null) || continue
    uptime_secs=$(echo "$uptime_result" | jq -r '.["out-data"] // ""' 2>/dev/null | awk 'NR==1{printf "%d", $1}') || uptime_secs=0

    if [[ "$uptime_secs" -gt 1800 ]]; then
        log_warn "[watch] $vm_name (VM $vm_id) stuck for ${uptime_secs}s — force stopping"
        qm stop "$vm_id" --timeout 10 2>/dev/null || qm stop "$vm_id" --skiplock 2>/dev/null || true
    fi
done <<< "$ALL_VMS"
