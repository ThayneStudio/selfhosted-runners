#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=rebake.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rebake.sh"
# shellcheck source=setup-prompts.sh
source "$LIB_DIR/setup-prompts.sh"

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

load_setup_prefills
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Saved settings are prefilled for editing. Enter keeps the shown value."
    echo "Clear the input (Ctrl-U), then Enter, to use the default in brackets."
    echo ""
fi

# Detect available bridges
echo "Available network bridges:"
BRIDGES=$(ip -br link | grep -E '^vmbr' | awk '{print $1}' || true)
if [[ -z "$BRIDGES" ]]; then
    log_warn "No bridges found (vmbr*). Using default vmbr0."
else
    echo "$BRIDGES" | sed 's/^/  /'
fi
prompt_setup_value NETWORK_BRIDGE "Network bridge" vmbr0

# Validate bridge exists
if ! ip link show "$NETWORK_BRIDGE" &> /dev/null; then
    log_error "Bridge '$NETWORK_BRIDGE' does not exist"
    exit 1
fi

# VLAN tag (optional)
prompt_setup_value VLAN_TAG "VLAN tag (empty for none)" ""
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
prompt_setup_value VM_STORAGE "Storage for VMs" local-zfs

# Validate storage exists
if ! pvesm status | awk '{print $1}' | grep -qxF "$VM_STORAGE"; then
    log_error "Storage pool '$VM_STORAGE' does not exist"
    exit 1
fi

prompt_setup_value TEMPLATE_ID "Template VM ID" 9000

# Validate before computing the minimum VMID default from this answer.
if [[ ! "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
    log_error "Template ID must be a number"
    exit 1
fi
if [[ "$TEMPLATE_ID" -lt 100 || "$TEMPLATE_ID" -gt 999999999 ]]; then
    log_error "Template ID must be between 100 and 999999999"
    exit 1
fi

# Minimum VM ID for runners (0 = use Proxmox default)
DEFAULT_MIN_VMID=$((TEMPLATE_ID + 1))
prompt_setup_value MIN_VMID "Minimum VM ID for runners (0 = auto)" "$DEFAULT_MIN_VMID"
if [[ ! "$MIN_VMID" =~ ^[0-9]+$ ]]; then
    log_error "Minimum VM ID must be a non-negative number"
    exit 1
fi
if [[ "$MIN_VMID" -ne 0 && "$MIN_VMID" -lt 100 ]]; then
    log_error "Minimum VM ID must be at least 100"
    exit 1
fi

# Memory ballooning (0 = disabled)
prompt_setup_value BALLOON "Memory balloon, MB (0 = disabled)" 0
if [[ ! "$BALLOON" =~ ^[0-9]+$ ]]; then
    log_error "Balloon must be a non-negative number"
    exit 1
fi

# DNS nameservers (space-separated, applied via cloud-init)
prompt_setup_value DNS_SERVERS "DNS nameservers, space-separated" "1.1.1.1 8.8.8.8"
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
prompt_setup_value DOCKER_MIRROR_URL "Supabase Docker mirror URL (empty to disable)" ""
if [[ -n "$DOCKER_MIRROR_URL" ]]; then
    while [[ "$DOCKER_MIRROR_URL" == */ ]]; do
        DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL%/}"
    done
    if [[ ! "$DOCKER_MIRROR_URL" =~ ^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]+)?$ ]]; then
        log_error "Docker mirror URL must be scheme://host[:port], for example http://10.20.1.19:8080"
        exit 1
    fi
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
    cp -r "$REPO_DIR"/* "$INSTALL_DIR/"
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
} > "$CONF_TMP"
chmod 600 "$CONF_TMP"
mv "$CONF_TMP" "$CONFIG_FILE"

# Prune obsolete per-org snippets that embedded the org PAT. Cloud-init is now
# rendered per-VM at clone time with a single-use JIT config; the PAT stays
# on the host.
if compgen -G "$SNIPPETS_DIR/runner-user-data-*.yaml" > /dev/null; then
    rm -f "$SNIPPETS_DIR"/runner-user-data-*.yaml
    log_info "Removed obsolete per-org PAT snippets"
fi

# Check if template already exists
if qm status "$TEMPLATE_ID" &> /dev/null; then
    log_info "[4/5] Template VM $TEMPLATE_ID already exists. Skipping creation."
    log_warn "To recreate: qm destroy $TEMPLATE_ID && runner setup"
    if [[ ! -f /var/lib/github-runners/baked-runner-version ]]; then
        log_warn "No baked runner version is recorded. The daily rebake will bake once."
    fi
else
    log_info "[4/5] Creating baked Ubuntu cloud template..."
    # Checksum mismatch deletes the cached image and returns before qm create.
    # Simple commands, not `|| exit`: `||` disables errexit inside the callee.
    prepare_cloud_image

    log_info "Creating VM template..."
    create_bake_vm "$TEMPLATE_ID"

    # Destroy this VM on failure or interrupt. It is not a template yet.
    # A SIGHUP after qm template succeeds must not purge the live template.
    cleanup_bake() {
        local cfg name
        if ! cfg=$(qm_host config "$TEMPLATE_ID" 2>/dev/null); then
            log_error "Could not read config for VM $TEMPLATE_ID; leaving it"
            return 0
        fi
        name=$(printf '%s\n' "$cfg" | awk '/^name:/{print $2; exit}')
        if [[ "$name" != "ubuntu-cloud-template" ]]; then
            log_error "Refusing to destroy VM $TEMPLATE_ID (${name:-unnamed}); it is not the template bake VM"
            return 0
        fi
        if printf '%s\n' "$cfg" | grep -q '^template: 1[[:space:]]*$'; then
            log_warn "VM $TEMPLATE_ID is already a template; leaving it"
            return 0
        fi
        log_warn "Baking failed, cleaning up template VM..."
        qm_host stop "$TEMPLATE_ID" --timeout 30 2>/dev/null || true
        qm_host destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
    }
    trap cleanup_bake EXIT

    bake_and_publish_vm "$TEMPLATE_ID"
    trap - EXIT

    if ! commit_baked_version "$BAKE_RUNNER_VERSION" "$TEMPLATE_ID"; then
        log_warn "Template was created but the baked runner version was not recorded"
    fi
    log_info "Template created successfully (tools baked in)"
fi

log_info "[5/5] Installing pool watcher and rebake timers..."
cp "$INSTALL_DIR/templates/github-runner-watch.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-watch.timer" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-rebake.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-rebake.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now github-runner-watch.timer 2>/dev/null || true
systemctl enable --now github-runner-rebake.timer 2>/dev/null || true
log_info "Pool watcher timer installed (30s interval)"
log_info "Template rebake timer installed (daily)"

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
    log_warn "Running VMs still have the old PAT on their cloud-init drive until recycled."
    log_warn "Recycle the pool before the next job: runner stop && runner start"
    echo ""
fi
