#!/bin/bash
set -euo pipefail
# Manually create a single runner VM.

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

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

if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    log_error "Invalid runner name: $RUNNER_NAME"
    exit 1
fi

SELECTED_ORG=$(select_org "$ORG_FLAG") || exit 1
load_org_config "$SELECTED_ORG"

# Verify template is ready
qm config "$TEMPLATE_ID" 2>/dev/null | grep -q "^template: 1" || {
    log_error "Template $TEMPLATE_ID not ready. Run 'runner setup'."; exit 1; }

# Verify snippet exists
[[ -f "$SNIPPETS_DIR/runner-user-data-${SELECTED_ORG}.yaml" ]] || {
    log_error "Cloud-init for '$SELECTED_ORG' missing. Run 'runner add-org'."; exit 1; }

# Check name not taken
EXISTING=$(qm list | awk -v n="$RUNNER_NAME" '$2==n {print $1}')
[[ -z "$EXISTING" ]] || { log_error "'$RUNNER_NAME' already exists (VMID $EXISTING)"; exit 1; }

log_info "Creating $RUNNER_NAME for org $GITHUB_ORG..."
clone_rc=0
VMID=$(clone_runner "$RUNNER_NAME" "$SELECTED_ORG") || clone_rc=$?
if [[ "$clone_rc" -eq 3 ]]; then
    log_info "create: promotion in progress, will retry"
    exit 0
fi
if [[ "$clone_rc" -ne 0 ]]; then
    log_error "Clone failed"
    exit 1
fi

echo ""
log_info "Runner '$RUNNER_NAME' started (VMID: $VMID)"
echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
echo ""
