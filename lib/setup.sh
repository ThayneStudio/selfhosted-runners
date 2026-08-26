#!/bin/bash
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "setup"

echo "========================================"
echo "  GitHub Actions Runner Setup Wizard"
echo "========================================"
echo ""

# Check we're on Proxmox
if ! command -v qm &> /dev/null; then
    log_error "This script must be run on a Proxmox host"
    exit 1
fi

if ! command -v pvesm &> /dev/null; then
    log_error "pvesm command not found. Is this a Proxmox host?"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_info "Installing jq (required for pool watcher)..."
    apt-get install -y jq > /dev/null 2>&1 || {
        log_error "Failed to install jq. Install it manually: apt-get install jq"
        exit 1
    }
fi

# Check if template file exists
if [[ ! -f "$REPO_DIR/templates/runner-user-data.yaml" ]]; then
    log_error "templates/runner-user-data.yaml not found in $REPO_DIR"
    exit 1
fi

# Detect available bridges
echo "Available network bridges:"
BRIDGES=$(ip -br link | grep -E '^vmbr' | awk '{print $1}' || true)
if [[ -z "$BRIDGES" ]]; then
    log_warn "No bridges found (vmbr*). Using default vmbr0."
else
    # shellcheck disable=SC2001  # indents every line of a multi-line list
    echo "$BRIDGES" | sed 's/^/  /'
fi
read -rp "Network bridge [vmbr0]: " NETWORK_BRIDGE
NETWORK_BRIDGE=${NETWORK_BRIDGE:-vmbr0}

# Validate bridge exists
if ! ip link show "$NETWORK_BRIDGE" &> /dev/null; then
    log_error "Bridge '$NETWORK_BRIDGE' does not exist"
    exit 1
fi

# VLAN tag (optional)
read -rp "VLAN tag (leave empty for none): " VLAN_TAG
if [[ -n "$VLAN_TAG" ]]; then
    if [[ ! "$VLAN_TAG" =~ ^[0-9]+$ ]] || [[ "$VLAN_TAG" -lt 1 || "$VLAN_TAG" -gt 4094 ]]; then
        log_error "VLAN tag must be a number between 1 and 4094"
        exit 1
    fi
fi

# Detect storage
echo ""
echo "Available storage pools:"
pvesm status | grep -E 'zfspool|dir|lvm' | awk '{print "  " $1 " (" $2 ")"}' || true
read -rp "Storage for VMs [local-zfs]: " VM_STORAGE
VM_STORAGE=${VM_STORAGE:-local-zfs}

# Validate storage exists
if ! pvesm status | awk '{print $1}' | grep -qxF "$VM_STORAGE"; then
    log_error "Storage pool '$VM_STORAGE' does not exist"
    exit 1
fi

read -rp "Template VM ID [9000]: " TEMPLATE_ID
TEMPLATE_ID=${TEMPLATE_ID:-9000}

# Minimum VM ID for runners (0 = use Proxmox default)
DEFAULT_MIN_VMID=$((TEMPLATE_ID + 1))
read -rp "Minimum VM ID for runners (0 = auto) [${DEFAULT_MIN_VMID}]: " MIN_VMID
MIN_VMID=${MIN_VMID:-$DEFAULT_MIN_VMID}
if [[ ! "$MIN_VMID" =~ ^[0-9]+$ ]]; then
    log_error "Minimum VM ID must be a non-negative number"
    exit 1
fi
if [[ "$MIN_VMID" -ne 0 && "$MIN_VMID" -lt 100 ]]; then
    log_error "Minimum VM ID must be at least 100"
    exit 1
fi

# Memory ballooning (0 = disabled)
read -rp "Memory balloon, MB (0 = disabled) [0]: " BALLOON
BALLOON=${BALLOON:-0}
if [[ ! "$BALLOON" =~ ^[0-9]+$ ]]; then
    log_error "Balloon must be a non-negative number"
    exit 1
fi

# DNS nameservers (space-separated, applied via cloud-init)
read -rp "DNS nameservers, space-separated [1.1.1.1 8.8.8.8]: " DNS_SERVERS
DNS_SERVERS=${DNS_SERVERS:-1.1.1.1 8.8.8.8}
for ns in $DNS_SERVERS; do
    if [[ ! "$ns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! ("$ns" =~ ^[0-9a-fA-F:]+$ && "$ns" =~ :) ]]; then
        log_error "Invalid nameserver: $ns (must be an IPv4 or IPv6 address)"
        exit 1
    fi
done

# Docker registry mirror for Supabase images (optional, e.g., local Zot cache)
# Leave empty to disable — runners will pull directly from public.ecr.aws.
echo ""
echo "Docker mirror: a local OCI registry (e.g., http://lxc-ip:5000 Zot) that caches"
echo "Supabase public.ecr.aws images. HTTP mirrors are routed through Supabase's image"
echo "registry override; HTTPS mirrors also configure containerd pull-through hosts."
read -rp "Supabase Docker mirror URL (empty to disable): " DOCKER_MIRROR_URL
if [[ -n "$DOCKER_MIRROR_URL" ]]; then
    while [[ "$DOCKER_MIRROR_URL" == */ ]]; do
        DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL%/}"
    done
    if [[ ! "$DOCKER_MIRROR_URL" =~ ^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]+)?$ ]]; then
        log_error "Docker mirror URL must be scheme://host[:port], for example http://10.20.1.19:8080"
        exit 1
    fi
fi

# Validate template ID is a valid Proxmox VM ID (100-999999999)
if [[ ! "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
    log_error "Template ID must be a number"
    exit 1
fi
if [[ "$TEMPLATE_ID" -lt 100 || "$TEMPLATE_ID" -gt 999999999 ]]; then
    log_error "Template ID must be between 100 and 999999999"
    exit 1
fi

# Confirm
echo ""
echo "Infrastructure configuration:"
echo "  Network Bridge: $NETWORK_BRIDGE"
echo "  VLAN Tag:       ${VLAN_TAG:-none}"
echo "  VM Storage:     $VM_STORAGE"
echo "  Template ID:    $TEMPLATE_ID"
echo "  Min VM ID:      $([ "${MIN_VMID:-0}" -eq 0 ] && echo "auto" || echo "$MIN_VMID")"
echo "  Balloon:        ${BALLOON:-0} MB ($([ "${BALLOON:-0}" -eq 0 ] && echo "disabled" || echo "enabled"))"
echo "  DNS Servers:    ${DNS_SERVERS:-DHCP only}"
echo "  Docker Mirror:  ${DOCKER_MIRROR_URL:-none}"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 0

# Install to /opt and create symlink
echo ""
log_info "[1/5] Installing to $INSTALL_DIR..."
if [[ "$REPO_DIR" != "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    # tests/ is skipped on purpose: it contains executables named qm, pvesm,
    # pvesh and zfs that fake the Proxmox CLI, and they have no business on a
    # host that manages real VMs.
    for repo_item in "$REPO_DIR"/*; do
        [[ "$(basename "$repo_item")" == "tests" ]] && continue
        cp -r "$repo_item" "$INSTALL_DIR/"
    done
    cp -r "$REPO_DIR"/.gitignore "$INSTALL_DIR/" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/runner" "$INSTALL_DIR/lib/"*.sh
    log_info "Copied files to $INSTALL_DIR"
else
    log_info "Already running from $INSTALL_DIR"
fi

# Create single symlink in /usr/local/bin
log_info "Creating symlink in /usr/local/bin..."
ln -sf "$INSTALL_DIR/runner" /usr/local/bin/runner
log_info "Command available: runner"

# Enable snippets on local storage
log_info "[2/5] Enabling snippets storage..."
if ! pvesm status --content snippets 2>/dev/null | awk '{print $1}' | grep -qx "local"; then
    # Read current content types to avoid overwriting them
    EXISTING_CONTENT=$(awk '/^dir: local$/,/^[^[:space:]]/' /etc/pve/storage.cfg 2>/dev/null | awk '/^[[:space:]]+content/ {print $2}')
    if [[ -n "$EXISTING_CONTENT" ]]; then
        if [[ "$EXISTING_CONTENT" == *snippets* ]]; then
            log_info "Snippets already in content types for local storage"
        else
            pvesm set local --content "${EXISTING_CONTENT},snippets" || {
                log_error "Failed to enable snippets on local storage"
                exit 1
            }
        fi
    else
        pvesm set local --content iso,backup,vztmpl,snippets || {
            log_error "Failed to enable snippets on local storage"
            exit 1
        }
    fi
fi
mkdir -p "$SNIPPETS_DIR"

# Install hookscript for auto-destroy on VM shutdown
log_info "Installing runner hookscript..."
cp "$INSTALL_DIR/templates/runner-hookscript.sh" "$SNIPPETS_DIR/runner-hookscript.sh"
chmod 755 "$SNIPPETS_DIR/runner-hookscript.sh"

# Save infra config
log_info "[3/5] Saving configuration..."
mkdir -p "$ORG_CONFIG_DIR"
chmod 700 "$ORG_CONFIG_DIR"
# The termination guard settings have no wizard prompt, so read back whatever
# is already configured and fall back to the defaults on a fresh install.
# Sourcing the file here would clobber the answers collected above. Trailing
# comments and whitespace are stripped: `MAX_VM_LIFETIME_HOURS=12 # long builds`
# would otherwise be written back verbatim and then silently rejected as
# non-numeric by the guard.
existing_conf_value() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    sed -n "s/^${1}=//p" "$CONFIG_FILE" \
        | tail -n 1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
        | tr -d "\"'"
}
MAX_VM_LIFETIME_HOURS=$(existing_conf_value MAX_VM_LIFETIME_HOURS)
MAX_VM_LIFETIME_HOURS=${MAX_VM_LIFETIME_HOURS:-$DEFAULT_MAX_VM_LIFETIME_HOURS}
STOPPED_REAP_MINUTES=$(existing_conf_value STOPPED_REAP_MINUTES)
STOPPED_REAP_MINUTES=${STOPPED_REAP_MINUTES:-$DEFAULT_STOPPED_REAP_MINUTES}
GUARD_EXCLUDE_VMIDS=$(existing_conf_value GUARD_EXCLUDE_VMIDS)
GUARD_EXCLUDE_VMIDS=${GUARD_EXCLUDE_VMIDS:-$DEFAULT_GUARD_EXCLUDE_VMIDS}
NOTIFY_WEBHOOK_URL=$(existing_conf_value NOTIFY_WEBHOOK_URL)
NOTIFY_MIN_SEVERITY=$(existing_conf_value NOTIFY_MIN_SEVERITY)
NOTIFY_FORMAT=$(existing_conf_value NOTIFY_FORMAT)

CONF_TMP=$(mktemp "${CONFIG_FILE}.XXXXXX")
{
    printf 'NETWORK_BRIDGE=%q\n' "$NETWORK_BRIDGE"
    printf 'VLAN_TAG=%q\n' "${VLAN_TAG}"
    printf 'VM_STORAGE=%q\n' "$VM_STORAGE"
    printf 'TEMPLATE_ID=%q\n' "$TEMPLATE_ID"
    printf 'MIN_VMID=%q\n' "$MIN_VMID"
    printf 'BALLOON=%q\n' "$BALLOON"
    printf 'DNS_SERVERS=%q\n' "$DNS_SERVERS"
    printf 'DOCKER_MIRROR_URL=%q\n' "${DOCKER_MIRROR_URL:-}"
    printf 'MAX_VM_LIFETIME_HOURS=%q\n' "$MAX_VM_LIFETIME_HOURS"
    printf 'STOPPED_REAP_MINUTES=%q\n' "$STOPPED_REAP_MINUTES"
    printf 'GUARD_EXCLUDE_VMIDS=%q\n' "$GUARD_EXCLUDE_VMIDS"
    printf 'NOTIFY_WEBHOOK_URL=%q\n' "${NOTIFY_WEBHOOK_URL:-}"
    printf 'NOTIFY_MIN_SEVERITY=%q\n' "${NOTIFY_MIN_SEVERITY:-}"
    printf 'NOTIFY_FORMAT=%q\n' "${NOTIFY_FORMAT:-}"
} > "$CONF_TMP"
chmod 600 "$CONF_TMP"
mv "$CONF_TMP" "$CONFIG_FILE"

# Re-render any existing org snippets from the current runner-user-data template.
# This keeps cloned runners aligned with updated bootstrap settings and mirror config.
if compgen -G "$ORG_CONFIG_DIR/*.conf" > /dev/null; then
    log_info "Refreshing existing runner cloud-init snippets..."
    for org_conf in "$ORG_CONFIG_DIR"/*.conf; do
        [[ -f "$org_conf" ]] || continue
        GITHUB_PAT="" GITHUB_ORG=""
        # shellcheck source=/dev/null
        source "$org_conf"
        [[ -n "$GITHUB_PAT" && -n "$GITHUB_ORG" ]] || continue

        snippet_tmp=$(mktemp "$SNIPPETS_DIR/.runner-user-data-${GITHUB_ORG}.XXXXXX")
        chmod 600 "$snippet_tmp"
        GITHUB_PAT="$GITHUB_PAT" GITHUB_ORG="$GITHUB_ORG" DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-}" awk '
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
        }' "$INSTALL_DIR/templates/runner-user-data.yaml" > "$snippet_tmp" || {
            log_error "Failed to regenerate cloud-init snippet for $GITHUB_ORG"
            exit 1
        }
        mv "$snippet_tmp" "$SNIPPETS_DIR/runner-user-data-${GITHUB_ORG}.yaml"
        log_info "  Updated snippet for $GITHUB_ORG"
    done
fi

# Check if template already exists
if qm status "$TEMPLATE_ID" &> /dev/null; then
    log_info "[4/5] Template VM $TEMPLATE_ID already exists. Skipping creation."
    # Adopt as generation 1 when the store is empty (spec 8). No-op otherwise;
    # never destroys.
    # shellcheck source=generations.sh
    source "$LIB_DIR/generations.sh"
    adopt_deployed_template
else
    # Bootstrap (ruling 2): no template at TEMPLATE_ID. Bake a band candidate
    # and promote it with skip-canary --yes only when the store had no active
    # generation before the bake. --yes is not a production maintain bypass.
    log_info "[4/5] No template at VMID $TEMPLATE_ID — baking the first generation..."
    # shellcheck source=bake.sh
    source "$LIB_DIR/bake.sh"
    # shellcheck source=promote.sh
    source "$LIB_DIR/promote.sh"

    had_active=0
    if [[ -n "$(gen_list active)" ]]; then
        had_active=1
    fi

    if ! bake_main --force; then
        log_error "First-run bake failed"
        exit 1
    fi

    if [[ "$had_active" -eq 0 ]]; then
        cand_vmid=""
        cand_count=0
        while read -r cand_line; do
            [[ -n "$cand_line" ]] || continue
            cand_vmid="$cand_line"
            cand_count=$((cand_count + 1))
        done < <(gen_list candidate)
        if [[ "$cand_count" -ne 1 || -z "$cand_vmid" ]]; then
            log_error "Bake finished but could not find a single candidate to promote"
            exit 1
        fi
        # gen_read publishes GEN_* into its caller. Capture in a subshell so
        # we do not depend on the parent seeing those assignments.
        # shellcheck disable=SC2031
        bootstrap_gen_id=$(
            gen_read "$cand_vmid" || exit 1
            printf '%s' "$GEN_ID"
        ) || exit 1
        if [[ -z "$bootstrap_gen_id" ]]; then
            log_error "Candidate VMID $cand_vmid has no GEN_ID"
            exit 1
        fi
        if ! promote_generation "$bootstrap_gen_id" --skip-canary --yes; then
            log_error "Failed to promote generation $bootstrap_gen_id"
            exit 1
        fi
        TEMPLATE_ID=$(reload_active_template_id) || exit 1
        log_info "Promoted generation $bootstrap_gen_id (VMID $TEMPLATE_ID) as the active template"
    fi
fi

log_info "[5/5] Installing pool watcher, lifetime guard, and maintain timers..."
cp "$INSTALL_DIR/templates/github-runner-watch.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-watch.timer" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-guard.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-guard.timer" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-maintain.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-maintain.timer" /etc/systemd/system/
mkdir -p /etc/logrotate.d
cp "$INSTALL_DIR/templates/github-runners.logrotate" /etc/logrotate.d/github-runners
systemctl daemon-reload
systemctl enable --now github-runner-watch.timer 2>/dev/null || true
systemctl enable --now github-runner-guard.timer 2>/dev/null || true
systemctl enable --now github-runner-maintain.timer 2>/dev/null || true
log_info "Pool watcher timer installed (30s interval)"
log_info "Lifetime guard timer installed (5m interval, ${MAX_VM_LIFETIME_HOURS}h VM ceiling, ${STOPPED_REAP_MINUTES}m stopped reap)"
log_info "Maintain timer installed (daily 02:30, rebake inside REBAKE_WINDOW)"
echo "  Preview what it would destroy:  runner guard --dry-run"
echo "  Turn it off:                    systemctl disable --now github-runner-guard.timer"
echo "  Disable daily maintain:         systemctl disable --now github-runner-maintain.timer"

echo ""
echo "========================================"
echo "  Infrastructure setup complete!"
echo "========================================"
echo ""

# Add first org if none configured
mapfile -t existing_orgs < <(list_orgs)
if [[ ${#existing_orgs[@]} -eq 0 ]]; then
    echo "Now let's add your first GitHub organization."
    echo ""
    exec "$LIB_DIR/add-org.sh"
else
    echo "Existing orgs: ${existing_orgs[*]}"
    echo ""
    echo "To add another org:  runner add-org"
    echo "To list orgs:        runner list-orgs"
    echo ""
    echo "Usage:"
    echo "  runner create runner-01"
    echo "  runner list"
    echo "  runner help"
    echo ""
fi
