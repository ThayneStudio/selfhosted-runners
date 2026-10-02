#!/bin/bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/selfhosted-runners}"
# Which ref to install. Overridable so a branch can be deployed to a staging
# host before it reaches master -- the integration pass on pve-test has no other
# way to get the code onto a host, since this script IS the deploy mechanism:
#
#   REPO_REF=integration/phase-1 bash -c "$(curl -fsSL .../install.sh)"
#
# Branch names containing a slash work; GitHub's tarball endpoint accepts them.
REPO_REF="${REPO_REF:-master}"
REPO_URL="${REPO_URL:-https://github.com/ThayneStudio/selfhosted-runners/archive/refs/heads/${REPO_REF}.tar.gz}"

if [[ "$REPO_REF" != "master" ]]; then
    echo "Installing selfhosted-runners from ref: $REPO_REF"
else
    echo "Installing selfhosted-runners..."
fi

# Download and extract. tests/ is excluded on purpose: it contains executables
# named qm, pvesm, pvesh and zfs that fake the Proxmox CLI, and they have no
# business on a host that manages real VMs.
mkdir -p "$INSTALL_DIR"
curl -fsSL "$REPO_URL" | tar xz --strip-components=1 -C "$INSTALL_DIR" \
    --exclude='*/tests' --exclude='*/tests/*'
chmod +x "$INSTALL_DIR/runner" "$INSTALL_DIR/lib/"*.sh

# Symlink to /usr/local/bin
ln -sf "$INSTALL_DIR/runner" /usr/local/bin/runner

echo "Installed to $INSTALL_DIR"

# Paths come from the library we just extracted rather than being spelled again
# here, so relocating the platform's state stays a one-line change in common.sh.
# Safe to source: the tar above has completed, so the file is whole.
# shellcheck source=lib/common.sh
source "$INSTALL_DIR/lib/common.sh"

# Carry an active maintenance drain over to the persistent flag. Releases before
# this one kept it on tmpfs, so upgrading mid-maintenance and then rebooting --
# which is usually the whole reason the pool was stopped -- would wipe the flag
# and let the watcher refill the pool on the next boot.

if [[ -e "$POOL_DRAIN_FILE_LEGACY" ]]; then
    ensure_state_dir
    : > "$POOL_DRAIN_FILE"
    echo "Migrated the active maintenance drain to $POOL_DRAIN_FILE"
    echo "The pool stays drained until you run 'runner start'."
fi

if [[ -f "$INSTALL_DIR/templates/github-runners.logrotate" ]]; then
    mkdir -p "$LOGROTATE_DIR"
    cp "$INSTALL_DIR/templates/github-runners.logrotate" "$LOGROTATE_DIR/github-runners"
fi

# If setup was already run, sync deployed files (hookscript, systemd units)
if [[ -f /etc/github-runners.conf ]]; then
    echo "Updating deployed files..."
    # shellcheck source=/dev/null
    source /etc/github-runners.conf
    # Fail closed on MIN_VMID=0 / band overlap so this upgrade cannot enable
    # github-runner-maintain.timer on a host that can no longer clone.
    apply_generation_defaults
    if ! validate_generation_band; then
        echo "" >&2
        echo "ERROR: /etc/github-runners.conf is incompatible with generational templates." >&2
        echo "  Set MIN_VMID=$((TEMPLATE_BAND_MAX + 1)) (or higher) in /etc/github-runners.conf" >&2
        echo "  before the next watch tick; the runner pool will not refill until you do." >&2
        echo "Install aborted; github-runner-maintain.timer was not enabled." >&2
        exit 1
    fi
    if [[ -d /var/lib/vz/snippets ]]; then
        cp "$INSTALL_DIR/templates/runner-hookscript.sh" /var/lib/vz/snippets/runner-hookscript.sh
        chmod 755 /var/lib/vz/snippets/runner-hookscript.sh
        # shellcheck source=lib/bake.sh
        source "$INSTALL_DIR/lib/bake.sh"
        if render_template_setup > "$SNIPPETS_DIR/template-setup.yaml"; then
            chmod 600 "$SNIPPETS_DIR/template-setup.yaml"
        fi
    fi
    # Adopt before enabling maintain.timer so a pvesm/inventory failure cannot
    # leave the timer running on a host that did not finish adoption.
    if command -v qm >/dev/null 2>&1; then
        # shellcheck source=lib/generations.sh
        source "$INSTALL_DIR/lib/generations.sh"
        if ! adopt_deployed_template; then
            echo "" >&2
            echo "ERROR: adoption of TEMPLATE_ID failed." >&2
            echo "Install aborted; github-runner-maintain.timer was not enabled." >&2
            exit 1
        fi
    fi
    if [[ -f "$SYSTEMD_UNIT_DIR/github-runner-watch.timer" ]]; then
        cp "$INSTALL_DIR/templates/github-runner-watch.service" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-watch.timer" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-guard.service" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-guard.timer" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-maintain.service" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-maintain.timer" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-drift.service" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-drift.timer" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-upgrade.service" "$SYSTEMD_UNIT_DIR/"
        systemctl daemon-reload
        # New in this release, so an existing install has it disabled.
        systemctl enable --now github-runner-guard.timer 2>/dev/null || true
        systemctl enable --now github-runner-maintain.timer 2>/dev/null || true
        systemctl enable --now github-runner-drift.timer 2>/dev/null || true
    fi
    # Backfill settings added after this host was set up. The guard falls back
    # to the same defaults, but an operator can only tune what they can see.
    guard_default() {
        sed -n "s/^DEFAULT_${1}=//p" "$INSTALL_DIR/lib/common.sh" | tail -n 1 | tr -d "\"'"
    }
    conf_value() {
        sed -n "s/^${1}=//p" /etc/github-runners.conf | tail -n 1 \
            | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' | tr -d "\"'"
    }
    for key in MAX_VM_LIFETIME_HOURS STOPPED_REAP_MINUTES GUARD_EXCLUDE_VMIDS; do
        grep -q "^${key}=" /etc/github-runners.conf && continue
        grep -q "^DEFAULT_${key}=" "$INSTALL_DIR/lib/common.sh" || continue
        value=$(guard_default "$key")
        conf_tmp=$(mktemp /etc/github-runners.conf.XXXXXX)
        chmod 600 "$conf_tmp"
        { cat /etc/github-runners.conf; printf '%s=%s\n' "$key" "$value"; } > "$conf_tmp"
        mv "$conf_tmp" /etc/github-runners.conf
        echo "  Added ${key}=${value} to /etc/github-runners.conf"
    done
    # This install enables a timer that destroys VMs unattended. Say so, and
    # say how to look before it leaps and how to turn it off.
    echo "  Lifetime guard active: destroys managed runner VMs running longer than" \
         "$(conf_value MAX_VM_LIFETIME_HOURS)h, and ones stopped longer than" \
         "$(conf_value STOPPED_REAP_MINUTES)m."
    echo "    Preview: runner guard --dry-run   Disable: systemctl disable --now github-runner-guard.timer"
    echo "  Daily maintain timer: 02:30 (reconcile, gc, canary, bake inside REBAKE_WINDOW, drift)."
    echo "    Disable: systemctl disable --now github-runner-maintain.timer"
    echo "  Drift alarm: every 6h (runner version vs the 30-day upstream window)."
    echo "    Disable: systemctl disable --now github-runner-drift.timer"
    echo "  To bake a new generation and start cloning it (does not destroy TEMPLATE_ID):"
    echo "    runner upgrade --dry-run"
    echo "    runner upgrade"
    # Prune obsolete per-org snippets. These embedded the org PAT; the PAT now
    # stays on the host and a single-use JIT config is rendered per-VM at clone time.
    if compgen -G "$SNIPPETS_DIR/runner-user-data-*.yaml" > /dev/null; then
        rm -f "$SNIPPETS_DIR"/runner-user-data-*.yaml
        echo "  Removed obsolete per-org PAT snippets"
    fi
    echo "Done. No need to re-run setup."
    echo ""
    echo "WARNING: VMs that are already running still have the old PAT on their"
    echo "cloud-init drive until they are destroyed. Recycle the pool before the"
    echo "next job or any workflow can still read it:"
    echo "  runner stop && runner start"
else
    echo ""
    echo "Run the setup wizard:"
    echo "  runner setup"
fi
echo ""
