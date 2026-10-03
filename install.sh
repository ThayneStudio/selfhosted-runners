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

# Closing line for a host that already has /etc/github-runners.conf. A conf
# file alone is not a finished template: the first setup writes it before the
# bake, and a failed bake leaves TEMPLATE_ID pointing at a VM clones cannot
# use. rebake stops in that state, so the operator runs setup. qm missing, or
# a config we cannot read, is reported as unchecked.
report_install_template() {
    local id="${TEMPLATE_ID:-}" err cfg name
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        echo "TEMPLATE_ID (${id:-unset}) in /etc/github-runners.conf is not a finished template."
        echo "Run the setup wizard:"
        echo "  runner setup"
        return 0
    fi
    if ! command -v qm >/dev/null 2>&1; then
        echo "Could not check whether template VM $id is a finished template: qm is not available."
        return 0
    fi
    if [[ ! -f "$INSTALL_DIR/lib/bake.sh" ]]; then
        echo "Could not check whether template VM $id is a finished template: $INSTALL_DIR/lib/bake.sh is missing."
        return 0
    fi
    # shellcheck source=lib/bake.sh
    if ! source "$INSTALL_DIR/lib/bake.sh"; then
        echo "Could not check whether template VM $id is a finished template."
        return 0
    fi
    err=$(mktemp)
    if ! cfg=$(qm config "$id" 2>"$err"); then
        if grep -q 'does not exist' "$err"; then
            rm -f "$err"
            echo "Template VM $id does not exist, so it is not a finished template."
            echo "Run the setup wizard:"
            echo "  runner setup"
            return 0
        fi
        rm -f "$err"
        echo "Could not check whether template VM $id is a finished template."
        return 0
    fi
    rm -f "$err"
    if template_is_converted "$id"; then
        echo "Done. No need to re-run setup."
        return 0
    fi
    name=$(printf '%s\n' "$cfg" | awk '/^name:/{print $2; exit}')
    if [[ "$name" == "ubuntu-cloud-template" ]]; then
        echo "VM $id is an unfinished template bake: its disk was never converted to a template."
        echo "If nothing is still baking it, remove it and run setup again:"
        echo "  qm stop $id; qm destroy $id"
        echo "  runner setup"
        return 0
    fi
    echo "VM $id is not a finished template, so the pool will not clone from it."
    echo "Run the setup wizard:"
    echo "  runner setup"
}

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
    # shellcheck source=lib/rebake.sh
    source "$INSTALL_DIR/lib/rebake.sh"
    write_rebake_timeout_dropin || log_warn "The rebake start timeout was not updated"
    systemctl daemon-reload
    systemctl enable --now github-runner-rebake.timer 2>/dev/null || true
    echo "Template rebake timer enabled (daily, separate from the pool watcher)."
    echo "A first enable waits for the next midnight before the timer's first check."
    echo "A host with no recorded baked version bakes once on that first check."
    echo "To run that check now: runner rebake"
    echo "Do not install or enable it while a template bake is still running."
    # Prune obsolete per-org snippets. These embedded the org PAT; the PAT now
    # stays on the host and a single-use JIT config is rendered per-VM at clone time.
    if compgen -G "/var/lib/vz/snippets/runner-user-data-*.yaml" > /dev/null; then
        rm -f /var/lib/vz/snippets/runner-user-data-*.yaml
        echo "  Removed obsolete per-org PAT snippets"
    fi
    report_install_template
    # VMs cloned from those snippets keep the PAT until they are destroyed.
    # Look for the VMs, not the snippets: an earlier run may have removed the
    # snippets, and clones made with JIT configs never held the PAT.
    pat_vms=$(grep -ls '^cicustom:.*user=local:snippets/runner-user-data-' /etc/pve/nodes/*/qemu-server/*.conf | wc -l) || pat_vms=0
    if (( pat_vms > 0 )); then
        echo ""
        echo "WARNING: $((pat_vms)) runner VM(s) cloned from the old per-org snippets still have the org PAT"
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
