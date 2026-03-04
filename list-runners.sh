#!/bin/bash

echo "Runner VMs:"
echo ""
qm list | head -1
qm list | grep -E 'runner-' || echo "(no runners found)"
echo ""

# If config exists, show GitHub link
if [[ -f /etc/github-runners.conf ]]; then
    source /etc/github-runners.conf
    echo "View in GitHub:"
    echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
fi
