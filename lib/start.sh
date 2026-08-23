#!/bin/bash
set -euo pipefail
# Resume the runner pool after maintenance.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "start"
load_infra_config

# Reap before clearing the drain flag. A managed VM that powered off during
# maintenance is garbage — the hookscript skipped its reclone — but the watcher
# sees the name in `qm list` and counts the slot as filled, so the slot would
# stay dead until someone noticed. Drain is still active here, so no clone can
# be in flight and nothing re-clones behind us.
log_info "Reaping stopped runner VMs left over from maintenance..."
"$LIB_DIR/guard.sh" --stopped-only --now --wait 60 \
    || log_warn "Stopped-VM reap did not finish — github-runner-guard.timer will retry."

disable_pool_drain

log_info "Starting runner watcher..."
systemctl start github-runner-watch.timer 2>/dev/null || true

log_info "Running an immediate pool fill..."
"$LIB_DIR/watch.sh" || true

echo ""
log_info "Pool drain cleared and watcher resumed."
echo ""
