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
        cp "$INSTALL_DIR/templates/github-runner-guard.service" /etc/systemd/system/
        cp "$INSTALL_DIR/templates/github-runner-guard.timer" /etc/systemd/system/
        systemctl daemon-reload
        # New in this release, so an existing install has it disabled.
        systemctl enable --now github-runner-guard.timer 2>/dev/null || true
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
    # Regenerate per-org cloud-init snippets from updated template
    if [[ -d /etc/github-runners.d ]]; then
        for org_conf in /etc/github-runners.d/*.conf; do
            [[ -f "$org_conf" ]] || continue
            org=$(basename "$org_conf" .conf)
            # Source org config to get PAT and org name
            GITHUB_PAT="" GITHUB_ORG=""
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
