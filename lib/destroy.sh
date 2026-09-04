#!/bin/bash
set -euo pipefail
# Manually destroy a runner VM.

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "destroy"

RUNNER_NAME=""
VMID=""
VM_ORG=""
SKIP_DEREGISTER=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-deregister)
            SKIP_DEREGISTER=true
            shift
            ;;
        --vmid)
            [[ $# -ge 2 ]] || { log_error "--vmid requires a value"; exit 1; }
            VMID="$2"
            shift 2
            ;;
        --vmid=*)
            VMID="${1#--vmid=}"
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            echo "Usage: runner destroy <runner-name> | runner destroy --vmid <vmid>"
            exit 1
            ;;
        *)
            [[ -z "$RUNNER_NAME" ]] || { log_error "Unexpected argument: $1"; exit 1; }
            RUNNER_NAME="$1"
            shift
            ;;
    esac
done

if [[ -n "$VMID" ]]; then
    [[ "$VMID" =~ ^[0-9]+$ ]] || { log_error "Invalid VMID: $VMID"; exit 1; }
    RUNNER_NAME=$(qm config "$VMID" 200>&- 201>&- 202>&- 2>/dev/null | awk '/^name:/{print $2}') || true
    [[ -n "$RUNNER_NAME" ]] || { log_error "VMID $VMID not found"; exit 1; }
else
    if [[ -z "$RUNNER_NAME" ]]; then
        echo "Usage: runner destroy <runner-name> | runner destroy --vmid <vmid>"
        exit 1
    fi

    if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log_error "Invalid runner name: $RUNNER_NAME"
        exit 1
    fi

    mapfile -t MATCHING_VMIDS < <(qm list 200>&- 201>&- 202>&- | awk -v n="$RUNNER_NAME" '$2==n {print $1}')
    [[ ${#MATCHING_VMIDS[@]} -gt 0 ]] || { log_error "'$RUNNER_NAME' not found"; exit 1; }

    MANAGED_VMIDS=()
    for candidate_vmid in "${MATCHING_VMIDS[@]}"; do
        candidate_org=$(get_vm_org "$candidate_vmid")
        [[ "$candidate_org" == "unknown" ]] && continue
        MANAGED_VMIDS+=("$candidate_vmid")
    done

    if [[ ${#MANAGED_VMIDS[@]} -eq 0 ]]; then
        log_error "'$RUNNER_NAME' is not managed by selfhosted-runners"
        exit 1
    fi
    if [[ ${#MANAGED_VMIDS[@]} -gt 1 ]]; then
        log_error "Multiple managed runners named '$RUNNER_NAME' found: ${MANAGED_VMIDS[*]}"
        exit 1
    fi

    VMID="${MANAGED_VMIDS[0]}"
fi

VM_ORG=$(get_vm_org "$VMID")
if [[ "$VM_ORG" == "unknown" ]]; then
    log_error "VMID $VMID ($RUNNER_NAME) is not managed by selfhosted-runners"
    exit 1
fi

# All destructive actors use slot -> org ordering. Rollover/guard pass the
# marker because their parent already owns both locks and the child inherits
# them; manual destroy acquires them here.
if [[ "${RUNNER_DESTRUCTIVE_LOCKS_HELD:-}" != 1 ]]; then
    exec 200>"${RUNNER_SLOT_LOCK_PREFIX}-${RUNNER_NAME}.lock"
    flock 200
    exec 209>"${ROLLOVER_ORG_LOCK_PREFIX}-${VM_ORG}.lock"
    flock 209
fi

# Remove hookscript to prevent auto-destroy from racing with us
qm set "$VMID" --delete hookscript 200>&- 201>&- 202>&- 2>/dev/null || true

# Stop if running
STATUS=$(qm status "$VMID" 200>&- 201>&- 202>&- 2>/dev/null | awk '{print $2}') || true
if [[ "$STATUS" == "running" ]]; then
    log_info "Stopping $RUNNER_NAME..."
    qm stop "$VMID" --timeout 30 200>&- 201>&- 202>&- 2>/dev/null || qm stop "$VMID" --skiplock 200>&- 201>&- 202>&- 2>/dev/null || true
fi

# Deregister from GitHub (best-effort)
if [[ "$SKIP_DEREGISTER" != true && "$VM_ORG" != "unknown" ]]; then
    deregister_runner "$VM_ORG" "$RUNNER_NAME" || true
fi

# Destroy
log_info "Destroying $RUNNER_NAME (VMID $VMID)..."
qm destroy "$VMID" --purge 200>&- 201>&- 202>&- || { log_error "Failed to destroy $VMID"; exit 1; }

# Clean up snippets
rm -f "${SNIPPETS_DIR}/runner-${VMID}-meta.yaml" "${SNIPPETS_DIR}/runner-${VMID}-vendor.yaml"

log_info "$RUNNER_NAME destroyed."
if systemctl is-active --quiet github-runner-watch.timer 2>/dev/null; then
    echo "Watcher will recreate on next tick."
else
    echo "Watcher is stopped."
fi
