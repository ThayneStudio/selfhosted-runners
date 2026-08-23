#!/bin/bash
# Proxmox hookscript: on VM shutdown, background a destroy + re-clone.
# No set -e: a failing hookscript makes Proxmox report the stop task as failed.
# The actual work (destroy, re-clone) happens in reclone.sh AFTER this exits,
# so Proxmox's task queue is not blocked and the VMID lock is released.

VMID="$1"
PHASE="$2"
COMMON_LIB="/opt/selfhosted-runners/lib/common.sh"

if [[ "$PHASE" == "post-stop" ]]; then
    # Proxmox runs this script standalone, so the drain check has to reach into
    # the install tree for pool_is_draining(). Hardcoding the flag path here is
    # what let this script drift from lib/common.sh when the flag moved off
    # tmpfs. The subshell keeps common.sh's `set -euo pipefail` out of here.
    #
    # The answer is a printed token, never an exit status. A common.sh that
    # cannot be sourced also exits 1 — indistinguishable from "not draining" —
    # and that is a real state during an upgrade, because install.sh untars
    # over the live tree and common.sh lands before the helpers it sources.
    # Silence is therefore treated as "draining": a missed reclone is repaired
    # by the watcher on its next tick, a reclone mid-maintenance is not.
    # shellcheck source=/dev/null
    DRAIN=$(
        . "$COMMON_LIB" >/dev/null 2>&1 || exit 0
        declare -F pool_is_draining >/dev/null || exit 0
        pool_is_draining && echo draining || echo clear
    )

    if [[ "$DRAIN" == "draining" ]]; then
        logger -t github-runner "VM $VMID stopped during pool drain, skipping reclone"
        exit 0
    fi
    if [[ "$DRAIN" != "clear" ]]; then
        logger -t github-runner "VM $VMID stopped but the drain check was inconclusive ($COMMON_LIB missing or unsourceable), skipping reclone"
        exit 0
    fi

    logger -t github-runner "VM $VMID stopped, triggering reclone"
    nohup /opt/selfhosted-runners/lib/reclone.sh "$VMID" \
        </dev/null >>/var/log/github-runner.log 2>&1 &
    disown
fi

exit 0
