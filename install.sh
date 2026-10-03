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
    fi
    cp "$INSTALL_DIR/templates/github-runner-rebake.service" /etc/systemd/system/
    cp "$INSTALL_DIR/templates/github-runner-rebake.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now github-runner-rebake.timer 2>/dev/null || true
    echo "Template rebake timer enabled (daily, separate from the pool watcher)."
    echo "A first enable waits for the next midnight before the timer's first check."
    echo "A host with no recorded baked version bakes once on that first check."
    echo "To run that check now: runner rebake"
    echo "Do not install or enable it while a template bake is still running."
    # Prune obsolete per-org snippets. These embedded the org PAT; the PAT now
    # stays on the host and a single-use JIT config is rendered per-VM at clone time.
    pruned_pat_snippets=0
    if compgen -G "/var/lib/vz/snippets/runner-user-data-*.yaml" > /dev/null; then
        rm -f /var/lib/vz/snippets/runner-user-data-*.yaml
        echo "  Removed obsolete per-org PAT snippets"
        pruned_pat_snippets=1
    fi
    echo "Done. No need to re-run setup."
    # Only VMs cloned from those snippets hold the PAT. Without them, the pool
    # was cloned with JIT configs, or an earlier run removed them and warned.
    if [[ "$pruned_pat_snippets" == 1 ]]; then
        echo ""
        echo "WARNING: runner VMs cloned from the removed snippets still have the org PAT"
        echo "on their cloud-init drive, where any job they run can read it, until they are"
        echo "destroyed. Recycle the pool to destroy them, now or once the first rebake has"
        echo "published a new template:"
        echo "  runner stop && runner start"
    fi
else
    echo ""
    echo "Run the setup wizard:"
    echo "  runner setup"
fi
echo ""
