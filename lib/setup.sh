#!/bin/bash
set -euo pipefail

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
    log_info "Installing jq (required for runner recycling)..."
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
read -rp "Minimum VM ID for runners (0 = auto) [0]: " MIN_VMID
MIN_VMID=${MIN_VMID:-0}
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
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 0

# Install to /opt and create symlink
echo ""
log_info "[1/6] Installing to $INSTALL_DIR..."
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
log_info "[2/6] Enabling snippets storage..."
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

# Save infra config
log_info "[3/6] Saving configuration..."
mkdir -p "$ORG_CONFIG_DIR"
chmod 700 "$ORG_CONFIG_DIR"
CONF_TMP=$(mktemp "${CONFIG_FILE}.XXXXXX")
cat > "$CONF_TMP" << EOF
NETWORK_BRIDGE="$NETWORK_BRIDGE"
VLAN_TAG="${VLAN_TAG}"
VM_STORAGE="$VM_STORAGE"
TEMPLATE_ID="$TEMPLATE_ID"
MIN_VMID="$MIN_VMID"
BALLOON="$BALLOON"
EOF
chmod 600 "$CONF_TMP"
mv "$CONF_TMP" "$CONFIG_FILE"

# Check if template already exists
if qm status "$TEMPLATE_ID" &> /dev/null; then
    log_info "[4/6] Template VM $TEMPLATE_ID already exists. Skipping creation."
    log_warn "To recreate: qm destroy $TEMPLATE_ID && runner setup"
else
    # Download and create template
    log_info "[4/6] Creating baked Ubuntu cloud template..."
    CLOUD_IMG="noble-server-cloudimg-amd64.img"
    CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/$CLOUD_IMG"

    # Use a root-only cache directory instead of world-writable /tmp/
    # to prevent symlink attacks or image replacement by unprivileged users
    IMG_CACHE_DIR="/var/cache/github-runners"
    mkdir -p "$IMG_CACHE_DIR"
    chmod 700 "$IMG_CACHE_DIR"

    if [[ ! -f "$IMG_CACHE_DIR/$CLOUD_IMG" ]]; then
        log_info "Downloading Ubuntu 24.04 cloud image..."
        if ! wget -q --show-progress -O "$IMG_CACHE_DIR/$CLOUD_IMG" "$CLOUD_IMG_URL"; then
            log_error "Failed to download cloud image"
            rm -f "$IMG_CACHE_DIR/$CLOUD_IMG"
            exit 1
        fi
    else
        log_info "Using cached cloud image from $IMG_CACHE_DIR/$CLOUD_IMG"
    fi

    # Verify image is valid (basic check)
    if [[ ! -s "$IMG_CACHE_DIR/$CLOUD_IMG" ]]; then
        log_error "Cloud image is empty or missing"
        rm -f "$IMG_CACHE_DIR/$CLOUD_IMG"
        exit 1
    fi

    # Verify SHA256 checksum
    log_info "Verifying cloud image checksum..."
    CHECKSUM_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
    EXPECTED_SHA256=$(wget -q -O - "$CHECKSUM_URL" | grep -F "$CLOUD_IMG" | head -1 | awk '{print $1}')
    if [[ -n "$EXPECTED_SHA256" ]]; then
        ACTUAL_SHA256=$(sha256sum "$IMG_CACHE_DIR/$CLOUD_IMG" | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            log_error "Checksum verification failed!"
            log_error "Expected: $EXPECTED_SHA256"
            log_error "Got:      $ACTUAL_SHA256"
            rm -f "$IMG_CACHE_DIR/$CLOUD_IMG"
            exit 1
        fi
        log_info "Checksum verified"
    else
        log_warn "Could not fetch checksum from Ubuntu — skipping verification"
    fi

    log_info "Creating VM template..."
    NET_CONFIG="virtio,bridge=$NETWORK_BRIDGE"
    if [[ -n "$VLAN_TAG" ]]; then
        NET_CONFIG="${NET_CONFIG},tag=$VLAN_TAG"
    fi
    if ! qm create "$TEMPLATE_ID" --name ubuntu-cloud-template \
        --memory 8192 --balloon "$BALLOON" --cores 2 --cpu host --net0 "$NET_CONFIG"; then
        log_error "Failed to create VM"
        exit 1
    fi

    IMPORT_OUTPUT=$(qm importdisk "$TEMPLATE_ID" "$IMG_CACHE_DIR/$CLOUD_IMG" "$VM_STORAGE" 2>&1) || {
        log_error "Failed to import disk"
        echo "$IMPORT_OUTPUT" >&2
        qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
        exit 1
    }

    # Extract the disk volume from importdisk output
    # Typical output: "Successfully imported disk as 'unused0:storage:vm-9000-disk-0'"
    if [[ "$IMPORT_OUTPUT" =~ unused0:([^\'\"[:space:]]+) ]]; then
        IMPORTED_DISK="${BASH_REMATCH[1]}"
    else
        # Fallback to conventional naming
        IMPORTED_DISK="${VM_STORAGE}:vm-${TEMPLATE_ID}-disk-0"
        log_warn "Could not parse imported disk name from importdisk output:"
        log_warn "$IMPORT_OUTPUT"
        log_warn "Assuming: $IMPORTED_DISK"
    fi

    if ! qm set "$TEMPLATE_ID" --scsihw virtio-scsi-pci \
        --scsi0 "$IMPORTED_DISK"; then
        log_error "Failed to configure SCSI"
        qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
        exit 1
    fi

    if ! qm set "$TEMPLATE_ID" --ide2 "${VM_STORAGE}:cloudinit"; then
        log_error "Failed to add cloud-init drive"
        qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
        exit 1
    fi

    qm set "$TEMPLATE_ID" --boot c --bootdisk scsi0 || { log_error "Failed to set boot disk"; qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true; exit 1; }
    qm set "$TEMPLATE_ID" --serial0 socket --vga serial0 || { log_error "Failed to set serial"; qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true; exit 1; }
    qm set "$TEMPLATE_ID" --agent enabled=1 || { log_error "Failed to enable agent"; qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true; exit 1; }
    qm resize "$TEMPLATE_ID" scsi0 30G || { log_error "Failed to resize disk"; qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true; exit 1; }

    # Copy template-setup cloud-init to snippets and configure
    log_info "Configuring template cloud-init..."
    cp "$INSTALL_DIR/templates/template-setup.yaml" "$SNIPPETS_DIR/template-setup.yaml"
    chmod 600 "$SNIPPETS_DIR/template-setup.yaml"

    if ! qm set "$TEMPLATE_ID" --cicustom "user=local:snippets/template-setup.yaml"; then
        log_error "Failed to set cloud-init config"
        qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
        exit 1
    fi
    qm set "$TEMPLATE_ID" --ipconfig0 ip=dhcp || { log_error "Failed to set IP config"; qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true; exit 1; }
    qm set "$TEMPLATE_ID" --ciuser runner || { log_error "Failed to set cloud-init user"; qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true; exit 1; }

    # Cleanup trap for baking phase (set before start so interrupted starts are cleaned up)
    cleanup_bake() {
        log_warn "Baking failed, cleaning up template VM..."
        qm stop "$TEMPLATE_ID" --timeout 30 2>/dev/null || true
        qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
    }
    trap cleanup_bake EXIT

    # Boot VM to bake tools into the template
    log_info "Starting VM to install tools (this takes 10-20 minutes)..."
    if ! qm start "$TEMPLATE_ID"; then
        log_error "Failed to start template VM"
        exit 1
    fi

    # Poll for template setup completion (timeout: 20 minutes)
    log_info "Waiting for tool installation to complete..."
    log_info "  (Monitor progress: qm guest exec $TEMPLATE_ID -- cat /var/log/template-setup.log)"
    BAKE_TIMEOUT=1200
    BAKE_ELAPSED=0
    BAKE_INTERVAL=15
    BAKE_READY=false

    while [[ $BAKE_ELAPSED -lt $BAKE_TIMEOUT ]]; do
        sleep $BAKE_INTERVAL
        BAKE_ELAPSED=$((BAKE_ELAPSED + BAKE_INTERVAL))

        # Check if VM is still running (it will poweroff after setup completes)
        VM_STATUS=$(qm status "$TEMPLATE_ID" 2>/dev/null | awk '{print $2}') || true
        if [[ "$VM_STATUS" != "running" ]]; then
            # VM powered off — setup succeeded (poweroff only runs if marker exists)
            BAKE_READY=true
            echo "" >&2
            log_info "Template VM powered off (setup complete)"
            break
        fi

        # Try to check for completion marker via guest agent
        EXEC_RESULT=$(qm guest exec "$TEMPLATE_ID" -- test -f /opt/.template-setup-complete 2>&1) || {
            # Guest agent not ready yet (still installing qemu-guest-agent)
            MINUTES=$((BAKE_ELAPSED / 60))
            SECONDS_REM=$((BAKE_ELAPSED % 60))
            printf '\r  Elapsed: %dm%02ds / %dm (waiting for guest agent...)' "$MINUTES" "$SECONDS_REM" "$((BAKE_TIMEOUT / 60))" >&2
            continue
        }

        # Parse exit code from guest exec JSON response
        EXEC_EXIT=$(echo "$EXEC_RESULT" | jq -r '.exitcode // "1"' 2>/dev/null) || EXEC_EXIT="1"
        if [[ "$EXEC_EXIT" == "0" ]]; then
            BAKE_READY=true
            echo "" >&2
            log_info "Template setup complete!"
            break
        fi

        MINUTES=$((BAKE_ELAPSED / 60))
        SECONDS_REM=$((BAKE_ELAPSED % 60))
        printf '\r  Elapsed: %dm%02ds / %dm (installing tools...)' "$MINUTES" "$SECONDS_REM" "$((BAKE_TIMEOUT / 60))" >&2
    done
    echo "" >&2

    if [[ "$BAKE_READY" != true ]]; then
        log_error "Template setup timed out after $((BAKE_TIMEOUT / 60)) minutes"
        log_error "The VM is still running — setup may have failed."
        log_error "Check logs: qm guest exec $TEMPLATE_ID -- cat /var/log/template-setup.log"
        exit 1
    fi

    # Stop VM if still running
    VM_STATUS=$(qm status "$TEMPLATE_ID" 2>/dev/null | awk '{print $2}') || true
    if [[ "$VM_STATUS" == "running" ]]; then
        log_info "Stopping template VM..."
        qm stop "$TEMPLATE_ID" --timeout 60 || {
            log_warn "Graceful stop failed, forcing..."
            qm stop "$TEMPLATE_ID" --skiplock 2>/dev/null || true
        }
        # Wait for stopped state
        for i in {1..30}; do
            VM_STATUS=$(qm status "$TEMPLATE_ID" 2>/dev/null | awk '{print $2}') || true
            [[ "$VM_STATUS" == "stopped" ]] && break
            sleep 2
        done
    fi

    # Clear bake-time cloud-init settings so clones start fresh
    log_info "Preparing template for cloning..."
    qm set "$TEMPLATE_ID" --delete cicustom 2>/dev/null || true
    qm set "$TEMPLATE_ID" --delete ciuser 2>/dev/null || true
    qm set "$TEMPLATE_ID" --delete ipconfig0 2>/dev/null || true

    # Convert to template
    qm template "$TEMPLATE_ID" || { log_error "Failed to convert to template"; exit 1; }

    # Disable cleanup trap — template created successfully
    trap - EXIT

    log_info "Template created successfully (tools baked in)"
fi

log_info "[5/6] Installing recycle timer..."
cp "$INSTALL_DIR/templates/github-runner-recycle.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-recycle.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now github-runner-recycle.timer 2>/dev/null || true
log_info "Recycle timer installed (120s interval)"

log_info "[6/6] Preparing runner state directory..."
mkdir -p "$RUNNERS_DIR"
chmod 700 "$RUNNERS_DIR"

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
