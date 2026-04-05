#!/bin/bash
set -euo pipefail
# Pool watcher: ensures each org has its target number of runner VMs.
# Runs via systemd timer every 30s. Clones ONE VM per org per tick.
# Also detects stuck VMs (running >30 min without becoming ready).

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "watch"

if [[ ! -f "$CONFIG_FILE" ]]; then
    exit 0
fi
load_infra_config

RUNNER_PREFIX="${RUNNER_PREFIX:-runner}"

log_watch() { log_info "[watch] $1"; }
log_watch_warn() { log_warn "[watch] $1"; }

# Generate a deterministic MAC address from a runner name.
# Uses locally-administered unicast prefix (02:xx:xx:xx:xx:xx).
generate_mac() {
    echo -n "$1" | md5sum | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\).*/02:\1:\2:\3:\4:\5/'
}

# Get all VMs as "VMID NAME" pairs (excluding header)
get_all_vms() {
    qm list 2>/dev/null | awk 'NR>1 {print $1, $2}'
}

# Get the org for a VM from its cicustom config
vm_org() {
    local cicustom
    cicustom=$(qm config "$1" 2>/dev/null | grep "^cicustom:" || true)
    if [[ "$cicustom" =~ runner-user-data-([^.]+)\.yaml ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Clone a new runner VM
clone_runner() {
    local name="$1" org="$2"

    # Validate org config in subshell so a bad config doesn't kill the watcher
    if ! ( load_org_config "$org" ) 2>/dev/null; then
        log_watch_warn "Org config for '$org' is invalid, skipping"
        return 1
    fi
    load_org_config "$org"

    if [[ ! -f "$SNIPPETS_DIR/runner-user-data-${org}.yaml" ]]; then
        log_watch_warn "Org snippet for '$org' not found, skipping"
        return 1
    fi

    # Acquire global lock for VMID allocation + clone
    exec 200>"$LOCK_FILE"
    flock -w 180 200 || {
        log_watch_warn "Could not acquire lock, skipping clone"
        return 1
    }

    # Re-check name uniqueness under lock (race with manual `runner create`)
    if qm list 2>/dev/null | awk '{print $2}' | grep -qxF "$name"; then
        log_watch "$name already exists, skipping"
        exec 200>&-
        return 0
    fi

    # Find next free VMID
    local vmid
    if [[ "${MIN_VMID:-0}" -gt 0 ]]; then
        vmid="$MIN_VMID"
        while qm status "$vmid" &>/dev/null; do
            vmid=$((vmid + 1))
        done
    else
        vmid=$(pvesh get /cluster/nextid 2>&1) || {
            log_watch_warn "Failed to get next VM ID: $vmid"
            exec 200>&-
            return 1
        }
    fi

    # Clone under lock (close lock fd for child to prevent KVM inheritance)
    if ! qm clone "$TEMPLATE_ID" "$vmid" --name "$name" --full --storage "$VM_STORAGE" 200>&-; then
        log_watch_warn "$name — clone failed"
        exec 200>&-
        return 1
    fi
    exec 200>&-

    # Apply deterministic MAC address
    local mac
    mac=$(generate_mac "$name")
    local net0
    net0=$(qm config "$vmid" | grep '^net0:' | sed 's/^net0: //') || true
    if [[ -n "$net0" ]]; then
        net0=$(echo "$net0" | sed "s/virtio=[^,]*/virtio=$mac/")
        qm set "$vmid" --net0 "$net0" || {
            log_watch_warn "$name — failed to set MAC, destroying"
            qm destroy "$vmid" --purge 2>/dev/null || true
            return 1
        }
    fi

    # Configure cloud-init
    cat > "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" << EOF
instance-id: "$name"
local-hostname: "$name"
EOF
    chmod 600 "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml"

    local cicustom="user=local:snippets/runner-user-data-${org}.yaml,meta=local:snippets/runner-${vmid}-meta.yaml"

    qm set "$vmid" --cicustom "$cicustom" || { log_watch_warn "$name — failed to set cicustom"; qm destroy "$vmid" --purge 2>/dev/null || true; return 1; }
    qm set "$vmid" --ipconfig0 ip=dhcp || { log_watch_warn "$name — failed to set ipconfig"; qm destroy "$vmid" --purge 2>/dev/null || true; return 1; }
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        qm set "$vmid" --nameserver "$DNS_SERVERS" || { log_watch_warn "$name — failed to set DNS"; qm destroy "$vmid" --purge 2>/dev/null || true; return 1; }
    fi
    qm set "$vmid" --ciuser runner || { log_watch_warn "$name — failed to set ciuser"; qm destroy "$vmid" --purge 2>/dev/null || true; return 1; }

    # Set hookscript for auto-destroy on shutdown
    if [[ -f "$SNIPPETS_DIR/runner-hookscript.sh" ]]; then
        qm set "$vmid" --hookscript "local:snippets/runner-hookscript.sh" || true
    fi

    # Start
    if ! qm start "$vmid"; then
        log_watch_warn "$name (VM $vmid) — failed to start"
        return 1
    fi

    log_watch "Created $name (VM $vmid) for org $org [MAC $mac]"
    return 0
}

# --- Main ---

# Verify template exists and is actually a template (not still baking)
TEMPLATE_STATUS=$(qm status "$TEMPLATE_ID" 2>/dev/null | awk '{print $2}') || true
if [[ "$TEMPLATE_STATUS" != "stopped" ]]; then
    # Template is missing, running (still baking), or in a bad state — skip this tick
    if [[ -n "$TEMPLATE_STATUS" ]]; then
        log_watch "Template VM $TEMPLATE_ID is $TEMPLATE_STATUS (not ready), skipping"
    fi
    exit 0
fi
# Verify it's actually a template (not a regular VM)
if ! qm config "$TEMPLATE_ID" 2>/dev/null | grep -q "^template: 1"; then
    log_watch "VM $TEMPLATE_ID is not a template yet, skipping"
    exit 0
fi

# Snapshot all VMs (filtering happens per-org by prefix)
ALL_VMS=$(get_all_vms)

# Iterate each org and fill its pool
mapfile -t ORGS < <(list_orgs)

CREATED=0
for org_name in "${ORGS[@]}"; do
    # Load per-org RUNNER_COUNT and RUNNER_PREFIX
    local_count=$(grep '^RUNNER_COUNT=' "$ORG_CONFIG_DIR/${org_name}.conf" 2>/dev/null | head -1 | sed 's/^RUNNER_COUNT=//' | tr -d '"') || true
    local_prefix=$(grep '^RUNNER_PREFIX=' "$ORG_CONFIG_DIR/${org_name}.conf" 2>/dev/null | head -1 | sed 's/^RUNNER_PREFIX=//' | tr -d '"') || true
    local_count="${local_count:-0}"
    local_prefix="${local_prefix:-${RUNNER_PREFIX}}"

    # Skip if RUNNER_COUNT is missing, non-numeric, or zero
    if [[ ! "$local_count" =~ ^[0-9]+$ ]] || [[ "$local_count" -le 0 ]]; then
        continue
    fi

    # Count existing VMs for this org
    existing=0
    while read -r vm_id vm_name; do
        [[ -z "$vm_id" ]] && continue
        if [[ "$(vm_org "$vm_id")" == "$org_name" ]]; then
            existing=$((existing + 1))
        fi
    done <<< "$ALL_VMS"

    if [[ $existing -ge $local_count ]]; then
        continue
    fi

    # Find first missing slot name and clone ONE VM
    for n in $(seq 1 "$local_count"); do
        slot_name="${local_prefix}-${n}"
        # Check if this name exists in the VM list
        if ! echo "$ALL_VMS" | awk '{print $2}' | grep -qxF "$slot_name"; then
            if clone_runner "$slot_name" "$org_name"; then
                CREATED=$((CREATED + 1))
            fi
            break  # One clone per org per tick
        fi
    done
done

# --- Stuck VM detection ---
# Force-stop runner VMs running >30 min without the runner-ready sentinel.
# The hookscript auto-destroys them on stop, and next tick fills the gap.
# Only check VMs that have a runner cloud-init snippet (actual runners).
while read -r vm_id vm_name; do
    [[ -z "$vm_id" ]] && continue
    [[ -n "$(vm_org "$vm_id")" ]] || continue
    vm_status=$(qm status "$vm_id" 2>/dev/null | awk '{print $2}') || continue
    [[ "$vm_status" == "running" ]] || continue

    # Check sentinel via guest agent
    sentinel=$(timeout 10 qm guest exec "$vm_id" -- test -f /opt/.runner-ready 2>/dev/null) || continue
    sentinel_exit=$(echo "$sentinel" | jq -r '.exitcode // "1"' 2>/dev/null) || sentinel_exit="1"
    [[ "$sentinel_exit" == "0" ]] && continue

    # No sentinel — check uptime
    uptime_result=$(timeout 10 qm guest exec "$vm_id" -- cat /proc/uptime 2>/dev/null) || continue
    uptime_secs=$(echo "$uptime_result" | jq -r '.["out-data"] // ""' 2>/dev/null | awk 'NR==1{printf "%d", $1}') || uptime_secs=0

    if [[ "$uptime_secs" -gt 1800 ]]; then
        log_watch_warn "$vm_name (VM $vm_id) stuck for ${uptime_secs}s — force stopping"
        qm stop "$vm_id" --timeout 10 2>/dev/null || qm stop "$vm_id" --skiplock 2>/dev/null || true
        # Hookscript will auto-destroy on post-stop, watcher fills the gap next tick
    fi
done <<< "$ALL_VMS"

if [[ $CREATED -gt 0 ]]; then
    log_watch "Created $CREATED runner(s)"
fi
