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
    if [[ ! -r "$COMMON_LIB" ]]; then
        # reclone.sh sources the same file, so it could not run either.
        logger -t github-runner "VM $VMID stopped but $COMMON_LIB is unreadable, skipping reclone"
        exit 0
    fi
    # shellcheck source=/dev/null
    if ( . "$COMMON_LIB" >/dev/null 2>&1 && pool_is_draining ); then
        logger -t github-runner "VM $VMID stopped during pool drain, skipping reclone"
        exit 0
    fi
    logger -t github-runner "VM $VMID stopped, triggering reclone"
    nohup /opt/selfhosted-runners/lib/reclone.sh "$VMID" \
        </dev/null >>/var/log/github-runner.log 2>&1 &
    disown
fi

exit 0
