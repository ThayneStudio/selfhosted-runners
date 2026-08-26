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
    if [[ -f "$SYSTEMD_UNIT_DIR/github-runner-watch.timer" ]]; then
        cp "$INSTALL_DIR/templates/github-runner-watch.service" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-watch.timer" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-guard.service" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-guard.timer" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-maintain.service" "$SYSTEMD_UNIT_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-maintain.timer" "$SYSTEMD_UNIT_DIR/"
        systemctl daemon-reload
        # New in this release, so an existing install has it disabled.
        systemctl enable --now github-runner-guard.timer 2>/dev/null || true
        systemctl enable --now github-runner-maintain.timer 2>/dev/null || true
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
    echo "  Daily maintain timer: 02:30 (detect + rebake inside REBAKE_WINDOW)."
    echo "    Disable: systemctl disable --now github-runner-maintain.timer"
    # Adopt the deployed template as generation 1 when the store is empty.
    # Never bakes on upgrade.
    if command -v qm >/dev/null 2>&1; then
        # shellcheck source=lib/generations.sh
        source "$INSTALL_DIR/lib/generations.sh"
        adopt_deployed_template
    fi
    # Regenerate per-org cloud-init snippets from updated template
    if [[ -d /etc/github-runners.d ]]; then
        for org_conf in /etc/github-runners.d/*.conf; do
            [[ -f "$org_conf" ]] || continue
            org=$(basename "$org_conf" .conf)
            # Source org config to get PAT and org name
            GITHUB_PAT="" GITHUB_ORG=""
            # shellcheck source=/dev/null  # per-org config, written by add-org at runtime
            source "$org_conf"
            [[ -n "$GITHUB_PAT" && -n "$GITHUB_ORG" ]] || continue
            # Re-render the snippet using the same awk substitution as add-org.sh
            snippet_tmp=$(mktemp "/var/lib/vz/snippets/.runner-user-data-${org}.XXXXXX")
            chmod 600 "$snippet_tmp"
            DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-}"
            GITHUB_PAT="$GITHUB_PAT" GITHUB_ORG="$GITHUB_ORG" DOCKER_MIRROR_URL="$DOCKER_MIRROR_URL" awk '
            function lreplace(str, old, new,    i, result) {
                result = ""
                while ((i = index(str, old)) > 0) {
                    result = result substr(str, 1, i - 1) new
                    str = substr(str, i + length(old))
                }
                return result str
            }
            {
                $0 = lreplace($0, "{{GITHUB_PAT}}", ENVIRON["GITHUB_PAT"])
                $0 = lreplace($0, "{{GITHUB_ORG}}", ENVIRON["GITHUB_ORG"])
                $0 = lreplace($0, "{{DOCKER_MIRROR_URL}}", ENVIRON["DOCKER_MIRROR_URL"])
                print
            }' "$INSTALL_DIR/templates/runner-user-data.yaml" > "$snippet_tmp"
            mv "$snippet_tmp" "/var/lib/vz/snippets/runner-user-data-${org}.yaml"
            echo "  Updated snippet for $org"
        done
    fi
    echo "Done. No need to re-run setup."
else
    echo ""
    echo "Run the setup wizard:"
    echo "  runner setup"
fi
echo ""
