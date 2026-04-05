#!/bin/bash
set -euo pipefail
# Recycle a single runner: destroy old VM (if any) and clone a fresh one.
# Usage: recycle-one.sh <state-file-path>
# Exit codes: 0 = no action, 1 = error, 2 = recycled successfully

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "recycle-one"

STATE_FILE="${1:-}"
if [[ -z "$STATE_FILE" || ! -f "$STATE_FILE" ]]; then
    log_error "Usage: recycle-one.sh <state-file-path>"
    exit 1
fi

load_infra_config

log_recycle() { log_info "[recycle] $1"; }
log_recycle_warn() { log_warn "[recycle] $1"; }
log_recycle_err() { log_error "[recycle] $1"; }

# Source state file with pre-initialized variables
RUNNER_NAME=""
VMID=""
ORG=""
MAC_ADDRESS=""
LABELS=""
CREATED_AT=""
LAST_RECYCLED_AT=""

source "$STATE_FILE"

if [[ -z "$RUNNER_NAME" ]]; then
    log_recycle_warn " Skipping $STATE_FILE — no RUNNER_NAME"
    exit 0
fi

# Per-runner lock: prevent hookscript + safety timer from recycling simultaneously
RUNNER_LOCK="/var/lock/github-runner-${RUNNER_NAME}.lock"
exec 201>"$RUNNER_LOCK"
if ! flock -n 201; then
    log_recycle " $RUNNER_NAME — another recycle is in progress, skipping"
    exit 0
fi

# --- Determine if recycle is needed and destroy old VM if it exists ---

if [[ -z "$VMID" ]]; then
    log_recycle " $RUNNER_NAME has empty VMID (previous recycle failed) — recreating"
    # Fall through to recreate
else
    # Check VM exists — distinguish "not found" from transient API errors
    if VM_CHECK=$(qm status "$VMID" 2>&1); then
        VM_STATUS=$(echo "$VM_CHECK" | awk '{print $2}')
        if [[ "$VM_STATUS" == "stopped" || "$VM_STATUS" == "failed" ]]; then
            log_recycle " $RUNNER_NAME VM $VMID is $VM_STATUS — recycling"
            # Fall through to destroy+recreate
        elif [[ "$VM_STATUS" != "running" ]]; then
            log_recycle " $RUNNER_NAME VM $VMID not running (status: ${VM_STATUS:-unknown}) — skipping"
            exit 0
        else
            # VM is running — caller must decide whether to force-recycle.
            # When invoked from hookscript (post-stop), we never reach here.
            # When invoked from safety timer, caller only invokes us for VMs
            # that are stopped or need force-recycle.
            log_recycle " $RUNNER_NAME VM $VMID is running — skipping"
            exit 0
        fi

        # --- Destroy the old VM ---

        deregister_runner "$ORG" "$RUNNER_NAME" || true

        qm stop "$VMID" --timeout 30 2>/dev/null || {
            qm stop "$VMID" --skiplock 2>/dev/null || true
        }
        for i in {1..15}; do
            current=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || true
            [[ "$current" == "stopped" ]] && break
            sleep 1
        done

        if ! qm destroy "$VMID" --purge 2>/dev/null; then
            log_recycle_err " $RUNNER_NAME — failed to destroy VM $VMID"
            exit 1
        fi

        if qm status "$VMID" &>/dev/null; then
            log_recycle_err " $RUNNER_NAME — VM $VMID still exists after destroy"
            exit 1
        fi

        rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml"
    else
        if [[ "$VM_CHECK" == *"does not exist"* ]]; then
            log_recycle " $RUNNER_NAME VM $VMID not found — recreating"
            rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml" 2>/dev/null || true
            deregister_runner "$ORG" "$RUNNER_NAME" || true
        else
            log_recycle_warn " $RUNNER_NAME — failed to query VM $VMID (${VM_CHECK%%$'\n'*}) — skipping"
            exit 0
        fi
    fi
fi

OLD_VMID="$VMID"

# Preserve original creation timestamp
ORIG_CREATED_AT="${CREATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Mark state as mid-recycle (empty VMID) so next cycle retries if clone fails
STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX")
cat > "$STATE_TMP" << STATEEOF
RUNNER_NAME="$RUNNER_NAME"
VMID=""
ORG="$ORG"
MAC_ADDRESS="$MAC_ADDRESS"
LABELS="$LABELS"
CREATED_AT="$ORIG_CREATED_AT"
LAST_RECYCLED_AT=""
STATEEOF
chmod 600 "$STATE_TMP"
mv "$STATE_TMP" "$STATE_FILE"

# --- Recreate from template ---

if [[ ! -f "$SNIPPETS_DIR/runner-user-data-${ORG}.yaml" ]]; then
    log_recycle_err " $RUNNER_NAME — org snippet for '$ORG' not found, cannot recreate"
    exit 1
fi

# Acquire lock for VMID allocation + clone (clone takes ~60s, so allow 180s)
exec 200>"$LOCK_FILE"
flock -w 180 200 || {
    log_recycle_err " $RUNNER_NAME — could not acquire lock, skipping"
    exit 1
}

# Get next available VM ID
if [[ "${MIN_VMID:-0}" -gt 0 ]]; then
    NEW_VMID="$MIN_VMID"
    while qm status "$NEW_VMID" &>/dev/null 2>&1; do
        NEW_VMID=$((NEW_VMID + 1))
    done
else
    NEW_VMID=$(pvesh get /cluster/nextid 2>&1) || {
        log_recycle_err " $RUNNER_NAME — failed to get next VM ID: $NEW_VMID"
        exit 1
    }
fi

# Clone template under lock. Close lock fd for child to prevent KVM inheritance.
if ! qm clone "$TEMPLATE_ID" "$NEW_VMID" --name "$RUNNER_NAME" --full --storage "$VM_STORAGE" 200>&-; then
    log_recycle_err " $RUNNER_NAME — failed to clone template"
    exec 200>&-
    exit 1
fi

# Release lock — VMID is now claimed in Proxmox
exec 200>&-

# Configure cloud-init
cat > "${SNIPPETS_DIR}/runner-${NEW_VMID}-meta.yaml" << METAEOF
instance-id: "$RUNNER_NAME"
local-hostname: "$RUNNER_NAME"
METAEOF
chmod 600 "${SNIPPETS_DIR}/runner-${NEW_VMID}-meta.yaml"

CICUSTOM="user=local:snippets/runner-user-data-${ORG}.yaml,meta=local:snippets/runner-${NEW_VMID}-meta.yaml"
if [[ -n "$LABELS" ]]; then
    cat > "${SNIPPETS_DIR}/runner-${NEW_VMID}-vendor.yaml" << VENDOREOF
#cloud-config
write_files:
  - path: /etc/github-runner/labels.env
    permissions: '0600'
    content: |
      RUNNER_LABELS="self-hosted,linux,x64,$LABELS"
VENDOREOF
    chmod 600 "${SNIPPETS_DIR}/runner-${NEW_VMID}-vendor.yaml"
    CICUSTOM="${CICUSTOM},vendor=local:snippets/runner-${NEW_VMID}-vendor.yaml"
fi

qm set "$NEW_VMID" --cicustom "$CICUSTOM" || {
    log_recycle_err " $RUNNER_NAME — failed to set cloud-init"
    qm destroy "$NEW_VMID" --purge 2>/dev/null || true
    exit 1
}

# Apply preserved MAC address
if [[ -n "$MAC_ADDRESS" ]]; then
    NEW_NET0=$(qm config "$NEW_VMID" | grep '^net0:' | sed 's/^net0: //') || true
    if [[ -n "$NEW_NET0" ]]; then
        NEW_NET0=$(echo "$NEW_NET0" | sed "s/virtio=[^,]*/virtio=$MAC_ADDRESS/")
        qm set "$NEW_VMID" --net0 "$NEW_NET0" || {
            log_recycle_err " $RUNNER_NAME — failed to set MAC address, aborting"
            qm destroy "$NEW_VMID" --purge 2>/dev/null || true
            exit 1
        }
    fi
fi

qm set "$NEW_VMID" --ipconfig0 ip=dhcp || {
    log_recycle_err " $RUNNER_NAME — failed to set IP config"
    qm destroy "$NEW_VMID" --purge 2>/dev/null || true
    exit 1
}
if [[ -n "${DNS_SERVERS:-}" ]]; then
    qm set "$NEW_VMID" --nameserver "$DNS_SERVERS" || {
        log_recycle_err " $RUNNER_NAME — failed to set DNS servers"
        qm destroy "$NEW_VMID" --purge 2>/dev/null || true
        exit 1
    }
fi
qm set "$NEW_VMID" --ciuser runner || {
    log_recycle_err " $RUNNER_NAME — failed to set cloud-init user"
    qm destroy "$NEW_VMID" --purge 2>/dev/null || true
    exit 1
}

# Set hookscript for event-driven recycling (if hookscript is installed)
if [[ -f "$SNIPPETS_DIR/runner-hookscript.sh" ]]; then
    qm set "$NEW_VMID" --hookscript "local:snippets/runner-hookscript.sh" || {
        log_recycle_warn " $RUNNER_NAME — failed to set hookscript (safety timer will handle recycling)"
    }
fi

# Write VMID to state BEFORE start so a failed start doesn't orphan the clone
STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX")
cat > "$STATE_TMP" << STATEEOF
RUNNER_NAME="$RUNNER_NAME"
VMID="$NEW_VMID"
ORG="$ORG"
MAC_ADDRESS="$MAC_ADDRESS"
LABELS="$LABELS"
CREATED_AT="$ORIG_CREATED_AT"
LAST_RECYCLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STATEEOF
chmod 600 "$STATE_TMP"
mv "$STATE_TMP" "$STATE_FILE"

# Start VM
if ! qm start "$NEW_VMID"; then
    log_recycle_err " $RUNNER_NAME — failed to start VM $NEW_VMID"
    exit 1
fi

log_recycle " Recycled $RUNNER_NAME (VMID: ${OLD_VMID:-none} → $NEW_VMID)"
exit 2
