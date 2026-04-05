#!/bin/bash
# Proxmox hookscript: destroy VM on shutdown, then re-clone it.
# No set -e: a failing hookscript makes Proxmox report the stop task as failed.

VMID="$1"
PHASE="$2"

if [[ "$PHASE" == "post-stop" ]]; then
    # Capture name and org BEFORE destroying
    CONFIG=$(qm config "$VMID" 2>/dev/null) || exit 0
    NAME=$(echo "$CONFIG" | awk '/^name:/{print $2}')
    ORG=$(echo "$CONFIG" | grep -o 'runner-user-data-[^.]*' | sed 's/runner-user-data-//')

    # Destroy
    rm -f "/var/lib/vz/snippets/runner-${VMID}-meta.yaml"
    qm destroy "$VMID" --purge 2>&1 | logger -t github-runner &
    wait

    # Re-clone in background (must not block Proxmox task queue)
    if [[ -n "$NAME" && -n "$ORG" ]]; then
        logger -t github-runner "Re-cloning $NAME for org $ORG"
        nohup /opt/selfhosted-runners/lib/reclone.sh "$NAME" "$ORG" \
            </dev/null >>/var/log/github-runner.log 2>&1 &
        disown
    fi
fi

exit 0
