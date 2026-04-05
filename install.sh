#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/selfhosted-runners"
REPO_URL="https://github.com/ThayneStudio/selfhosted-runners/archive/refs/heads/master.tar.gz"

echo "Installing selfhosted-runners..."

# Download and extract
mkdir -p "$INSTALL_DIR"
curl -fsSL "$REPO_URL" | tar xz --strip-components=1 -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/runner" "$INSTALL_DIR/lib/"*.sh

# Symlink to /usr/local/bin
ln -sf "$INSTALL_DIR/runner" /usr/local/bin/runner

echo "Installed to $INSTALL_DIR"

# If setup was already run, sync deployed files (hookscript, systemd units)
if [[ -f /etc/github-runners.conf ]]; then
    echo "Updating deployed files..."
    if [[ -d /var/lib/vz/snippets ]]; then
        cp "$INSTALL_DIR/templates/runner-hookscript.sh" /var/lib/vz/snippets/runner-hookscript.sh
        chmod 755 /var/lib/vz/snippets/runner-hookscript.sh
    fi
    if [[ -f /etc/systemd/system/github-runner-watch.timer ]]; then
        cp "$INSTALL_DIR/templates/github-runner-watch.service" /etc/systemd/system/
        cp "$INSTALL_DIR/templates/github-runner-watch.timer" /etc/systemd/system/
        systemctl daemon-reload
    fi
    echo "Done. No need to re-run setup."
else
    echo ""
    echo "Run the setup wizard:"
    echo "  runner setup"
fi
echo ""
