#!/bin/bash
# Proxmox hookscript: on VM shutdown, background a destroy + re-clone.
# No set -e: a failing hookscript makes Proxmox report the stop task as failed.
# The actual work (destroy, re-clone) happens in reclone.sh AFTER this exits,
# so Proxmox's task queue is not blocked and the VMID lock is released.

VMID="$1"
PHASE="$2"
POOL_DRAIN_FILE="/run/lock/github-runner-drain"

if [[ "$PHASE" == "post-stop" ]]; then
    if [[ -e "$POOL_DRAIN_FILE" ]]; then
        logger -t github-runner "VM $VMID stopped during pool drain, skipping reclone"
        exit 0
    fi
    logger -t github-runner "VM $VMID stopped, triggering reclone"
    nohup /opt/selfhosted-runners/lib/reclone.sh "$VMID" \
        </dev/null >>/var/log/github-runner.log 2>&1 &
    disown
fi

exit 0
