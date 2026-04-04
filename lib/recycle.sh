#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "recycle"

# Load infrastructure config
if [[ ! -f "$CONFIG_FILE" ]]; then
    # No config = nothing to recycle
    exit 0
fi
load_infra_config

# Check if any runner state files exist
shopt -s nullglob
STATE_FILES=("$RUNNERS_DIR"/*.conf)
shopt -u nullglob

if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# Concurrency limit for parallel recycles (default 3)
MAX_CONCURRENT="${MAX_CONCURRENT_RECYCLES:-3}"

log_recycle() { log_info "[recycle] $1"; }
log_recycle_warn() { log_warn "[recycle] $1"; }
log_recycle_err() { log_error "[recycle] $1"; }

# Temp dir for collecting exit codes from background subshells
RESULT_DIR=$(mktemp -d)
trap 'rm -rf "$RESULT_DIR"' EXIT

PIDS=()

for STATE_FILE in "${STATE_FILES[@]}"; do
    RUNNER_BASE=$(basename "$STATE_FILE" .conf)

    (
        # Subshell for continue-on-error per runner
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

        # If VMID is empty, a previous recycle failed mid-way — recreate
        if [[ -z "$VMID" ]]; then
            log_recycle " $RUNNER_NAME has empty VMID (previous recycle failed) — recreating"
            # Fall through to recreate
        else
            # Check VM exists
            if ! qm status "$VMID" &>/dev/null; then
                log_recycle " $RUNNER_NAME VM $VMID not found — recreating"
                # Clean up orphaned snippets from the missing VM
                rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml" 2>/dev/null || true
                # Deregister stale runner from GitHub (best-effort)
                deregister_runner "$ORG" "$RUNNER_NAME" || true
                # Fall through to recreate
            else
                # Check VM status
                VM_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || true
                if [[ "$VM_STATUS" == "stopped" || "$VM_STATUS" == "failed" ]]; then
                    log_recycle " $RUNNER_NAME VM $VMID is $VM_STATUS — recycling"
                    # Deregister before destroy (best-effort)
                    deregister_runner "$ORG" "$RUNNER_NAME" || true
                    # Fall through to destroy+recreate
                elif [[ "$VM_STATUS" != "running" ]]; then
                    log_recycle " $RUNNER_NAME VM $VMID not running (status: ${VM_STATUS:-unknown}) — skipping"
                    exit 0
                else
                    # VM is running — check if runner service has finished a job

                    # Check if runner is ready (sentinel file exists)
                    SENTINEL_RESULT=$(qm guest exec "$VMID" -- test -f /opt/.runner-ready 2>/dev/null) || {
                        # Guest agent not available or command failed — VM still booting
                        log_recycle " $RUNNER_NAME — guest agent not ready, skipping"
                        exit 0
                    }
                    SENTINEL_EXIT=$(echo "$SENTINEL_RESULT" | jq -r '.exitcode // "1"' 2>/dev/null) || SENTINEL_EXIT="1"
                    if [[ "$SENTINEL_EXIT" != "0" ]]; then
                        # Runner not registered yet (cloud-init still running)
                        # Check for stale boot: VM running >10 min without sentinel = likely PAT or registration failure
                        UPTIME_RESULT=$(qm guest exec "$VMID" -- cat /proc/uptime 2>/dev/null) || true
                        UPTIME_SECS=$(echo "$UPTIME_RESULT" | jq -r '.["out-data"] // ""' 2>/dev/null | awk '{printf "%d", $1}') || UPTIME_SECS=0
                        if [[ "$UPTIME_SECS" -gt 1800 ]]; then
                            log_recycle_warn " $RUNNER_NAME (VM $VMID) stuck for ${UPTIME_SECS}s without becoming ready — force recycling"
                            # Fall through to destroy+recreate
                        elif [[ "$UPTIME_SECS" -gt 600 ]]; then
                            log_recycle_warn " $RUNNER_NAME (VM $VMID) has been running for ${UPTIME_SECS}s without becoming ready — possible PAT expiry or registration failure"
                            exit 0
                        else
                            log_recycle " $RUNNER_NAME — not ready yet (cloud-init in progress, uptime ${UPTIME_SECS}s), skipping"
                            exit 0
                        fi
                    fi

                    # Check runner service status
                    SERVICE_RESULT=$(qm guest exec "$VMID" -- bash -c 'systemctl is-active actions.runner.* 2>/dev/null || echo inactive' 2>/dev/null) || {
                        log_recycle_warn " $RUNNER_NAME — failed to check service status, skipping"
                        exit 0
                    }
                    SERVICE_STATUS=$(echo "$SERVICE_RESULT" | jq -r '.["out-data"] // "unknown"' 2>/dev/null | head -1 | tr -d '\n') || SERVICE_STATUS="unknown"

                    if [[ "$SERVICE_STATUS" == "active" || "$SERVICE_STATUS" == "activating" ]]; then
                        # Runner is still running or waiting for a job — nothing to do
                        exit 0
                    fi

                    log_recycle " $RUNNER_NAME — service status: $SERVICE_STATUS — recycling"
                fi

                # --- Destroy the old VM ---

                # Deregister runner from GitHub before destroying VM (best-effort)
                deregister_runner "$ORG" "$RUNNER_NAME" || true

                # Stop VM
                qm stop "$VMID" --timeout 30 2>/dev/null || {
                    qm stop "$VMID" --skiplock 2>/dev/null || true
                }
                # Wait for stopped
                for i in {1..15}; do
                    current=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || true
                    [[ "$current" == "stopped" ]] && break
                    sleep 1
                done

                # Destroy VM
                if ! qm destroy "$VMID" --purge 2>/dev/null; then
                    log_recycle_err " $RUNNER_NAME — failed to destroy VM $VMID"
                    exit 1
                fi

                # Verify destruction
                if qm status "$VMID" &>/dev/null; then
                    log_recycle_err " $RUNNER_NAME — VM $VMID still exists after destroy"
                    exit 1
                fi

                # Clean up old snippets
                rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml"
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

        # Verify org snippet exists
        if [[ ! -f "$SNIPPETS_DIR/runner-user-data-${ORG}.yaml" ]]; then
            log_recycle_err " $RUNNER_NAME — org snippet for '$ORG' not found, cannot recreate"
            exit 1
        fi

        # Acquire lock for VMID allocation only
        exec 200>"$LOCK_FILE"
        flock -w 30 200 || {
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

        # Release lock and close fd BEFORE any qm commands that spawn persistent processes.
        # VMID is allocated — that's all the lock protects.
        exec 200>&-

        # Clone template
        if ! qm clone "$TEMPLATE_ID" "$NEW_VMID" --name "$RUNNER_NAME" --full --storage "$VM_STORAGE"; then
            log_recycle_err " $RUNNER_NAME — failed to clone template"
            exit 1
        fi

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

        # Apply preserved MAC address (substitute into cloned net0 line)
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
        qm set "$NEW_VMID" --ciuser runner || {
            log_recycle_err " $RUNNER_NAME — failed to set cloud-init user"
            qm destroy "$NEW_VMID" --purge 2>/dev/null || true
            exit 1
        }

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
        # Exit 2 = successfully recycled (distinguishes from exit 0 = no action needed)
        exit 2
    ) &
    PIDS+=($!)
    echo $! > "$RESULT_DIR/$RUNNER_BASE.pid"

    # Throttle: if we've hit the concurrency limit, wait for one to finish
    while [[ ${#PIDS[@]} -ge $MAX_CONCURRENT ]]; do
        NEW_PIDS=()
        for p in "${PIDS[@]}"; do
            if kill -0 "$p" 2>/dev/null; then
                NEW_PIDS+=("$p")
            fi
        done
        PIDS=("${NEW_PIDS[@]}")
        if [[ ${#PIDS[@]} -ge $MAX_CONCURRENT ]]; then
            sleep 1
        fi
    done
done

# Wait for all jobs and collect exit codes
RECYCLE_COUNT=0
ERROR_COUNT=0
for pidfile in "$RESULT_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid=$(cat "$pidfile")
    wait "$pid" 2>/dev/null && EXIT_CODE=0 || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 2 ]]; then
        RECYCLE_COUNT=$((RECYCLE_COUNT + 1))
    elif [[ $EXIT_CODE -ne 0 ]]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
done

if [[ $RECYCLE_COUNT -gt 0 || $ERROR_COUNT -gt 0 ]]; then
    log_recycle " Recycle complete — recycled: $RECYCLE_COUNT, errors: $ERROR_COUNT"
fi
