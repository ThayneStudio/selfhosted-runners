#!/bin/bash
# Proxmox hookscript for GitHub Actions runner VMs.
# Called by Proxmox with: <vmid> <phase>
# On post-stop, backgrounds a recycle of the runner that owned this VMID.
#
# IMPORTANT: No set -e here. A failing hookscript causes Proxmox to report
# the stop task as failed, which is misleading. Errors are handled inside
# recycle-one.sh.

VMID="$1"
PHASE="$2"

# Only act on post-stop (VM has finished shutting down)
case "$PHASE" in
    post-stop) ;;
    *) exit 0 ;;
esac

INSTALL_DIR="/opt/selfhosted-runners"
RUNNERS_DIR="/etc/github-runners.d/runners"

# Find which runner state file owns this VMID
STATE_FILE=""
for f in "$RUNNERS_DIR"/*.conf 2>/dev/null; do
    if grep -qxF "VMID=\"$VMID\"" "$f" 2>/dev/null; then
        STATE_FILE="$f"
        break
    fi
done

if [[ -z "$STATE_FILE" ]]; then
    # No runner owns this VMID (template, manually created VM, or state already deleted)
    exit 0
fi

RUNNER_NAME=$(basename "$STATE_FILE" .conf)
logger -t github-runner-hookscript "post-stop: $RUNNER_NAME (VMID $VMID) — triggering recycle"

# Background the recycle and exit immediately so Proxmox's task queue isn't blocked.
# The clone takes ~60s and must not hold up the hookscript.
nohup "$INSTALL_DIR/lib/recycle-one.sh" "$STATE_FILE" \
    </dev/null >>/var/log/github-runner-hookscript.log 2>&1 &
disown

exit 0
