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
    # shellcheck source=/dev/null
    source /etc/github-runners.conf
    if [[ -d /var/lib/vz/snippets ]]; then
        cp "$INSTALL_DIR/templates/runner-hookscript.sh" /var/lib/vz/snippets/runner-hookscript.sh
        chmod 755 /var/lib/vz/snippets/runner-hookscript.sh
        DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-}" awk '
        function lreplace(str, old, new,    i, result) {
            result = ""
            while ((i = index(str, old)) > 0) {
                result = result substr(str, 1, i - 1) new
                str = substr(str, i + length(old))
            }
            return result str
        }
        {
            $0 = lreplace($0, "{{DOCKER_MIRROR_URL}}", ENVIRON["DOCKER_MIRROR_URL"])
            print
        }' "$INSTALL_DIR/templates/template-setup.yaml" > /var/lib/vz/snippets/template-setup.yaml
        chmod 600 /var/lib/vz/snippets/template-setup.yaml
    fi
    if [[ -f /etc/systemd/system/github-runner-watch.timer ]]; then
        cp "$INSTALL_DIR/templates/github-runner-watch.service" /etc/systemd/system/
        cp "$INSTALL_DIR/templates/github-runner-watch.timer" /etc/systemd/system/
        systemctl daemon-reload
    fi
    # Prune obsolete per-org snippets. These embedded the org PAT; the PAT now
    # stays on the host and a short-lived token is rendered per-VM at clone time.
    # Safe to remove: ephemeral VMs never restart, and any legacy VM is replaced
    # new-style on its next reclone.
    if compgen -G "/var/lib/vz/snippets/runner-user-data-*.yaml" > /dev/null; then
        rm -f /var/lib/vz/snippets/runner-user-data-*.yaml
        echo "  Removed obsolete per-org PAT snippets"
    fi
    echo "Done. No need to re-run setup."
else
    echo ""
    echo "Run the setup wizard:"
    echo "  runner setup"
fi
echo ""
