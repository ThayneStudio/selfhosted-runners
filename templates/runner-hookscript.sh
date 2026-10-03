#!/bin/bash
# Proxmox hookscript: on VM shutdown, start a destroy + re-clone.
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
    # reclone.sh runs as its own transient unit. A child of this hook stays in
    # qmeventd.service's cgroup, and stopping qmeventd kills it mid-reclone:
    # every qemu-server upgrade restarts qmeventd, and host shutdown stops it.
    # systemd refuses to start the unit while the host shuts down; the
    # watcher reclaims the stopped VM after boot. Do not fall back to a child
    # process here, or the shutdown case comes back.
    if ! systemd-run --no-block --collect --quiet \
        --unit="github-runner-reclone-${VMID}" \
        --property=StandardOutput=append:/var/log/github-runner.log \
        --property=StandardError=append:/var/log/github-runner.log \
        /opt/selfhosted-runners/lib/reclone.sh "$VMID"; then
        logger -t github-runner "VM $VMID: could not start the reclone unit; the watcher will reclaim it"
    fi
fi

exit 0
