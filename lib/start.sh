#!/bin/bash
set -euo pipefail
# Resume the runner pool after maintenance.

START_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=common.sh
source "$START_LIB_DIR/common.sh"
# shellcheck source=recycle.sh
source "$START_LIB_DIR/recycle.sh"

WATCH_SERVICE_FILE="/etc/systemd/system/github-runner-watch.service"

start_main() {
    require_root "start"
    load_infra_config

    disable_pool_drain
    # Resuming is the go-ahead to retry every slot now, not when the failure
    # backoff of a slot that failed before maintenance runs out.
    clear_slot_backoff

    log_info "Starting runner watcher..."
    systemctl start github-runner-watch.timer 2>/dev/null || true

    # Fill inside the watcher's own unit: run from this shell, an SSH drop
    # kills a clone halfway through and leaves a half-configured VM.
    if [[ -f "$WATCH_SERVICE_FILE" ]]; then
        log_info "Running an immediate pool fill (follow it with: journalctl -u github-runner-watch -f)..."
        systemctl start github-runner-watch.service \
            || log_warn "The pool fill failed; see: journalctl -u github-runner-watch"
    else
        log_info "Running an immediate pool fill..."
        "$LIB_DIR/watch.sh" || true
    fi

    echo ""
    log_info "Pool drain cleared and watcher resumed."
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    start_main "$@"
fi
