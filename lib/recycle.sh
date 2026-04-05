#!/bin/bash
set -euo pipefail
# Safety-net recycler: catches runners that the hookscript missed.
# Normally, the post-stop hookscript handles recycling instantly.
# This timer-based script runs every ~10 minutes as a fallback for:
#   - VMs stuck in mid-recycle state (VMID="")
#   - VMs that stopped but hookscript didn't fire
#   - VMs stuck booting for >30 minutes

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "recycle"

if [[ ! -f "$CONFIG_FILE" ]]; then
    exit 0
fi
load_infra_config

shopt -s nullglob
STATE_FILES=("$RUNNERS_DIR"/*.conf)
shopt -u nullglob

if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
    exit 0
fi

MAX_CONCURRENT="${MAX_CONCURRENT_RECYCLES:-3}"

log_recycle() { log_info "[recycle] $1"; }
log_recycle_warn() { log_warn "[recycle] $1"; }

RESULT_DIR=$(mktemp -d)
trap 'rm -rf "$RESULT_DIR"' EXIT

PIDS=()

for STATE_FILE in "${STATE_FILES[@]}"; do
    RUNNER_BASE=$(basename "$STATE_FILE" .conf)

    (
        # State file may have been deleted by a concurrent destroy
        [[ -f "$STATE_FILE" ]] || exit 0

        RUNNER_NAME=""
        VMID=""
        FORCE_STUCK=false

        source "$STATE_FILE"

        if [[ -z "$RUNNER_NAME" ]]; then
            exit 0
        fi

        NEEDS_RECYCLE=false

        if [[ -z "$VMID" ]]; then
            # Previous recycle failed mid-way
            log_recycle " $RUNNER_NAME has empty VMID — safety-net recreating"
            NEEDS_RECYCLE=true
        elif VM_CHECK=$(qm status "$VMID" 2>&1); then
            VM_STATUS=$(echo "$VM_CHECK" | awk '{print $2}')
            if [[ "$VM_STATUS" == "stopped" || "$VM_STATUS" == "failed" ]]; then
                # Hookscript should have caught this — recycle as fallback
                log_recycle " $RUNNER_NAME VM $VMID is $VM_STATUS — safety-net recycling"
                NEEDS_RECYCLE=true
            elif [[ "$VM_STATUS" == "running" ]]; then
                # Check for stuck boot (>30 min without becoming ready)
                UPTIME_RESULT=$(qm guest exec "$VMID" -- cat /proc/uptime 2>/dev/null) || true
                UPTIME_SECS=0
                UPTIME_SECS=$(echo "$UPTIME_RESULT" | jq -r '.["out-data"] // ""' 2>/dev/null | awk 'NR==1{printf "%d", $1}') || UPTIME_SECS=0
                if [[ "$UPTIME_SECS" -gt 1800 ]]; then
                    log_recycle_warn " $RUNNER_NAME (VM $VMID) stuck for ${UPTIME_SECS}s — safety-net force recycling"
                    FORCE_STUCK=true
                    NEEDS_RECYCLE=true
                fi
            fi
        else
            if [[ "$VM_CHECK" == *"does not exist"* ]]; then
                log_recycle " $RUNNER_NAME VM $VMID not found — safety-net recreating"
                NEEDS_RECYCLE=true
            fi
            # API error → skip (don't create duplicates)
        fi

        if [[ "$NEEDS_RECYCLE" != true ]]; then
            exit 0
        fi

        # Delegate to recycle-one.sh (LIB_DIR inherited from common.sh)
        if [[ "$FORCE_STUCK" == true ]]; then
            exec "$LIB_DIR/recycle-one.sh" --force "$STATE_FILE"
        else
            exec "$LIB_DIR/recycle-one.sh" "$STATE_FILE"
        fi
    ) &
    PIDS+=($!)
    echo $! > "$RESULT_DIR/$RUNNER_BASE.pid"

    # Throttle concurrency
    while [[ ${#PIDS[@]} -ge $MAX_CONCURRENT ]]; do
        NEW_PIDS=()
        for p in "${PIDS[@]}"; do
            if kill -0 "$p" 2>/dev/null; then
                NEW_PIDS+=("$p")
            fi
        done
        if [[ ${#NEW_PIDS[@]} -gt 0 ]]; then
            PIDS=("${NEW_PIDS[@]}")
        else
            PIDS=()
        fi
        if [[ ${#PIDS[@]} -ge $MAX_CONCURRENT ]]; then
            sleep 1
        fi
    done
done

# Collect results
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
    log_recycle " Safety-net complete — recycled: $RECYCLE_COUNT, errors: $ERROR_COUNT"
fi
