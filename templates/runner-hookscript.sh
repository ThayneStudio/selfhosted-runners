#!/bin/bash
# Proxmox hookscript: auto-destroy runner VMs on shutdown.
# Called by Proxmox with: <vmid> <phase>
# No set -e: a failing hookscript makes Proxmox report the stop task as failed.

VMID="$1"
PHASE="$2"

if [[ "$PHASE" == "post-stop" ]]; then
    logger -t github-runner "Auto-destroying VM $VMID"
    # Clean up snippet files (qm destroy --purge doesn't remove these)
    rm -f "/var/lib/vz/snippets/runner-${VMID}-meta.yaml" \
          "/var/lib/vz/snippets/runner-${VMID}-vendor.yaml" 2>/dev/null
    nohup /usr/sbin/qm destroy "$VMID" --purge &>/dev/null &
fi

exit 0
