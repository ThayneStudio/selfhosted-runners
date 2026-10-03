#!/bin/bash
set -euo pipefail
# Manually create a single runner VM.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/recycle.sh"

require_root "create"
load_infra_config

if pool_is_draining; then
    log_error "Runner pool is stopped for maintenance. Run 'runner start' to resume."
    exit 1
fi

# Parse: [--org <org>] <name>
ORG_FLAG=""
RUNNER_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --org)   [[ $# -ge 2 ]] || { log_error "--org requires a value"; exit 1; }; ORG_FLAG="$2"; shift 2 ;;
        --org=*) ORG_FLAG="${1#--org=}"; shift ;;
        -*)      log_error "Unknown option: $1"; exit 1 ;;
        *)       [[ -z "$RUNNER_NAME" ]] || { log_error "Unexpected argument: $1"; exit 1; }; RUNNER_NAME="$1"; shift ;;
    esac
done

if [[ -z "$RUNNER_NAME" ]]; then
    echo "Usage: runner create [--org <org>] <name>"
    exit 1
fi

# The name becomes the VM name, which qm clone checks as a DNS name. Reject it
# here: clone_runner mints (registers) the runner on GitHub before it clones.
if ! validate_runner_name "$RUNNER_NAME"; then
    log_error "Invalid runner name: $RUNNER_NAME"
    log_error "Use letters, numbers and hyphens, starting and ending with a letter or number (no underscores)."
    exit 1
fi

SELECTED_ORG=$(select_org "$ORG_FLAG") || exit 1
load_org_config "$SELECTED_ORG"

# Verify template is ready
qm config "$TEMPLATE_ID" 2>/dev/null | grep -q "^template: 1" || {
    log_error "Template $TEMPLATE_ID not ready. Run 'runner setup'."; exit 1; }

# Verify runner cloud-init template exists (rendered per-VM at clone time)
[[ -f "$INSTALL_DIR/templates/runner-user-data.yaml" ]] || {
    log_error "Runner template missing at $INSTALL_DIR/templates/runner-user-data.yaml. Re-run install."; exit 1; }

# Take the per-slot lock so watch/reclone don't race us — clone_runner requires
# callers to hold fd 200 before entering (lock-order inversion vs VMID lock).
exec 200>"$(slot_lock_file "$RUNNER_NAME")"
flock -n 200 || { log_error "Another process is managing '$RUNNER_NAME'"; exit 1; }

# Check name not taken
EXISTING=$(qm list | awk -v n="$RUNNER_NAME" '$2==n {print $1}')
[[ -z "$EXISTING" ]] || { log_error "'$RUNNER_NAME' already exists (VMID $EXISTING)"; exit 1; }

log_info "Creating $RUNNER_NAME for org $GITHUB_ORG..."
VMID=$(clone_runner "$RUNNER_NAME" "$SELECTED_ORG") || { log_error "Clone failed"; exit 1; }

# The watcher fills a recorded extra runner like a slot, so it comes back
# when a failure hold or a template rebuild leaves it empty. One of the org's
# slots is the watcher's already.
read_org_slots "$SELECTED_ORG"
SLOT_N=$(slot_number "$RUNNER_NAME" "$ORG_SLOT_PREFIX") || SLOT_N=""
if [[ -z "$ORG_SLOT_COUNT" || -z "$SLOT_N" ]] || (( SLOT_N > ORG_SLOT_COUNT )); then
    record_extra_runner "$RUNNER_NAME" "$SELECTED_ORG" \
        || log_warn "Could not record $RUNNER_NAME in $EXTRA_RUNNERS_FILE; the watcher will not re-create it if it is ever left empty"
fi

echo ""
log_info "Runner '$RUNNER_NAME' started (VMID: $VMID)"
echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
echo ""
