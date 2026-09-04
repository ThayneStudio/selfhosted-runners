#!/bin/bash
set -euo pipefail
# Stop the watcher and optionally destroy managed runner VMs.

# shellcheck source=generations.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/generations.sh"

require_root "stop"
load_infra_config

VMID_RANGE=""
VMID_MIN=""
VMID_MAX=""
WATCH_ONLY=false
ASSUME_YES=false

collect_managed_runners() {
    local vmid_min="${1:-}"
    local vmid_max="${2:-}"
    local all_vms vmid vm_name status vm_org

    all_vms=$(qm list 2>/dev/null | tail -n +2 || true)
    [[ -n "$all_vms" ]] || return 0

    while read -r line; do
        [[ -n "$line" ]] || continue
        vmid=$(echo "$line" | awk '{print $1}')
        vm_name=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')

        # Every generation is a template, not a disposable runner. Checking
        # the store rather than only TEMPLATE_ID also protects superseded,
        # candidate, rejected, and failed templates during maintenance.
        gen_exists "$vmid" && continue

        if [[ -n "$vmid_min" ]]; then
            [[ "$vmid" -ge "$vmid_min" && "$vmid" -le "$vmid_max" ]] || continue
        fi

        vm_org=$(get_vm_org "$vmid")
        [[ "$vm_org" != "unknown" ]] || continue

        printf '%s|%s|%s|%s\n' "$vmid" "$vm_name" "$vm_org" "$status"
    done <<< "$all_vms"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid-range)
            [[ $# -ge 2 ]] || { log_error "--vmid-range requires MIN:MAX"; exit 1; }
            VMID_RANGE="$2"
            shift 2
            ;;
        --vmid-range=*)
            VMID_RANGE="${1#--vmid-range=}"
            shift
            ;;
        --watch-only)
            WATCH_ONLY=true
            shift
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            echo "Usage: runner stop [--watch-only] [--vmid-range <min:max>] [--yes]"
            exit 1
            ;;
        *)
            log_error "Unexpected argument: $1"
            echo "Usage: runner stop [--watch-only] [--vmid-range <min:max>] [--yes]"
            exit 1
            ;;
    esac
done

if [[ -n "$VMID_RANGE" ]]; then
    if [[ ! "$VMID_RANGE" =~ ^([0-9]+):([0-9]+)$ ]]; then
        log_error "Invalid VMID range: $VMID_RANGE (expected MIN:MAX)"
        exit 1
    fi
    VMID_MIN="${BASH_REMATCH[1]}"
    VMID_MAX="${BASH_REMATCH[2]}"
    if [[ "$VMID_MIN" -gt "$VMID_MAX" ]]; then
        log_error "Invalid VMID range: min must be <= max"
        exit 1
    fi
fi

mapfile -t RUNNERS < <(collect_managed_runners "$VMID_MIN" "$VMID_MAX")

echo ""
echo "This will:"
echo "  - stop github-runner-watch.timer and github-runner-watch.service"
if [[ "$WATCH_ONLY" == true ]]; then
    echo "  - leave running runner VMs in place to finish their jobs"
    echo "  - still let the lifetime guard reap them once they stop or age out,"
    echo "    with no watcher running to refill the slots"
elif [[ ${#RUNNERS[@]} -gt 0 ]]; then
    echo "  - destroy ${#RUNNERS[@]} managed runner VM(s)"
else
    echo "  - destroy 0 managed runner VMs"
fi
if [[ "$WATCH_ONLY" != true && -z "$VMID_MIN" ]]; then
    echo "  - free orphaned linked-clone child volumes for all generations when safe"
fi
if [[ -n "$VMID_MIN" ]]; then
    echo "  - limit runner destruction to VMIDs ${VMID_MIN}-${VMID_MAX}"
fi
echo ""

if [[ "$WATCH_ONLY" != true && ${#RUNNERS[@]} -gt 0 ]]; then
    echo "Managed runners selected:"
    for entry in "${RUNNERS[@]}"; do
        IFS='|' read -r VMID VM_NAME VM_ORG STATUS <<< "$entry"
        printf "  %-8s %-25s %-15s %-10s\n" "$VMID" "$VM_NAME" "$VM_ORG" "$STATUS"
    done
    echo ""
fi

if [[ "$ASSUME_YES" != true ]]; then
    echo -n "Type 'yes' to continue: " >&2
    read -r CONFIRM </dev/tty || { log_error "No input"; exit 1; }
    [[ "$CONFIRM" == "yes" ]] || { log_info "Aborted."; exit 0; }
fi

log_info "Stopping runner watcher timer..."
enable_pool_drain
systemctl stop github-runner-watch.timer 2>/dev/null || true

log_info "Waiting for in-flight clone activity to drain..."
exec 202>"$POOL_ACTIVITY_LOCK_FILE"
flock 202

log_info "Stopping runner watcher service..."
systemctl stop github-runner-watch.service 2>/dev/null || true

mapfile -t RUNNERS < <(collect_managed_runners "$VMID_MIN" "$VMID_MAX")

if [[ "$WATCH_ONLY" == true ]]; then
    log_info "Watcher stopped. Pool drain remains active; running runner VMs left in place."
    log_warn "The lifetime guard still reaps them once they stop or exceed MAX_VM_LIFETIME_HOURS."
    log_warn "To keep one for inspection: qm set <vmid> --protection 1"
    echo "Resume later with:"
    echo "  runner start"
    echo ""
    exec 202>&-
    exit 0
fi

FAILURES=()
while true; do
    [[ ${#RUNNERS[@]} -gt 0 ]] || break

    for entry in "${RUNNERS[@]}"; do
        IFS='|' read -r VMID VM_NAME _ _ <<< "$entry"
        if ! "$LIB_DIR/destroy.sh" --vmid "$VMID" 200>&- 201>&- 202>&-; then
            # reclone.sh and the lifetime guard destroy without this lock, so a
            # VM can legitimately disappear mid-loop. Only a VM that is still
            # here after a failed destroy is an actual failure.
            if qm status "$VMID" >/dev/null 2>&1; then
                FAILURES+=("$VM_NAME (VMID $VMID)")
            fi
        fi
    done

    [[ ${#FAILURES[@]} -eq 0 ]] || break
    mapfile -t RUNNERS < <(collect_managed_runners "$VMID_MIN" "$VMID_MAX")
done

echo ""
if [[ ${#FAILURES[@]} -gt 0 ]]; then
    log_error "Failed to destroy: ${FAILURES[*]}"
    log_warn "Watcher remains stopped and pool drain remains active. Resolve the failures before resuming."
    exec 202>&-
    exit 1
fi

if [[ -z "$VMID_MIN" ]]; then
    generation_list=$(gen_list) || {
        log_warn "Watcher remains stopped and pool drain remains active. Could not read generation records."
        exec 202>&-
        exit 1
    }
    if [[ -z "$generation_list" ]]; then
        generation_list="$TEMPLATE_ID"
    fi
    while read -r generation_vmid; do
        [[ -n "$generation_vmid" ]] || continue
        cleanup_rc=0
        cleanup_template_orphan_volumes "$generation_vmid" || cleanup_rc=$?
        if [[ $cleanup_rc -ne 0 ]]; then
            log_warn "Watcher remains stopped and pool drain remains active. Resolve the template storage issue before resuming."
            exec 202>&-
            exit 1
        fi
    done <<< "$generation_list"
else
    log_info "Skipping template orphan-volume cleanup because --vmid-range was specified."
fi

log_info "Watcher stopped and managed runners destroyed. Pool drain remains active."
echo "Resume later with:"
echo "  runner start"
echo ""
exec 202>&-
