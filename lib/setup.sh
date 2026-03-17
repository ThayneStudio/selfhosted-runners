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
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 0

# Install to /opt and create symlink
echo ""
log_info "[1/4] Installing to $INSTALL_DIR..."
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
log_info "[2/4] Enabling snippets storage..."
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
log_info "[3/4] Saving configuration..."
mkdir -p "$ORG_CONFIG_DIR"
chmod 700 "$ORG_CONFIG_DIR"
CONF_TMP=$(mktemp "${CONFIG_FILE}.XXXXXX")
cat > "$CONF_TMP" << EOF
NETWORK_BRIDGE="$NETWORK_BRIDGE"
VLAN_TAG="${VLAN_TAG}"
VM_STORAGE="$VM_STORAGE"
TEMPLATE_ID="$TEMPLATE_ID"
EOF
chmod 600 "$CONF_TMP"
mv "$CONF_TMP" "$CONFIG_FILE"

# Check if template already exists
if qm status "$TEMPLATE_ID" &> /dev/null; then
    log_info "[4/4] Template VM $TEMPLATE_ID already exists. Skipping creation."
    log_warn "To recreate: qm destroy $TEMPLATE_ID && runner setup"
else
    # Download and create template
    log_info "[4/4] Creating Ubuntu cloud template..."
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
        --memory 8192 --cores 2 --cpu host --net0 "$NET_CONFIG"; then
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
    qm template "$TEMPLATE_ID" || { log_error "Failed to convert to template"; qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true; exit 1; }

    log_info "Template created successfully"
fi

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
