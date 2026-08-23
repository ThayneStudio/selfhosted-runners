#!/bin/bash
set -euo pipefail
# Resume the runner pool after maintenance.

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "start"
load_infra_config

disable_pool_drain

log_info "Starting runner watcher..."
systemctl start github-runner-watch.timer 2>/dev/null || true

log_info "Running an immediate pool fill..."
"$LIB_DIR/watch.sh" || true

echo ""
log_info "Pool drain cleared and watcher resumed."
echo ""
