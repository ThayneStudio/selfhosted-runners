#!/bin/bash
set -euo pipefail

echo "========================================"
echo "  GitHub Actions Runner Setup Wizard"
echo "========================================"
echo ""

# Check we're on Proxmox
if ! command -v qm &> /dev/null; then
    echo "Error: This script must be run on a Proxmox host"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if template file exists
if [[ ! -f "$SCRIPT_DIR/templates/runner-user-data.yaml" ]]; then
    echo "Error: templates/runner-user-data.yaml not found"
    exit 1
fi

# Collect configuration
read -p "GitHub Organization name: " GITHUB_ORG
read -sp "GitHub PAT (admin:org scope): " GITHUB_PAT
echo ""

# Validate PAT format
if [[ ! "$GITHUB_PAT" =~ ^ghp_ ]] && [[ ! "$GITHUB_PAT" =~ ^github_pat_ ]]; then
    echo "Warning: PAT doesn't start with 'ghp_' or 'github_pat_'. Make sure it's valid."
fi

# Detect available bridges
echo ""
echo "Available network bridges:"
ip -br link | grep -E '^vmbr' || echo "  (none found - using default)"
read -p "Network bridge [vmbr0]: " NETWORK_BRIDGE
NETWORK_BRIDGE=${NETWORK_BRIDGE:-vmbr0}

# Detect storage
echo ""
echo "Available storage pools:"
pvesm status | grep -E 'zfspool|dir|lvm' | awk '{print "  " $1 " (" $2 ")"}'
read -p "Storage for VMs [local-zfs]: " VM_STORAGE
VM_STORAGE=${VM_STORAGE:-local-zfs}

read -p "Template VM ID [9000]: " TEMPLATE_ID
TEMPLATE_ID=${TEMPLATE_ID:-9000}

# Confirm
echo ""
echo "Configuration:"
echo "  GitHub Org:     $GITHUB_ORG"
echo "  Network Bridge: $NETWORK_BRIDGE"
echo "  VM Storage:     $VM_STORAGE"
echo "  Template ID:    $TEMPLATE_ID"
echo ""
read -p "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]$ ]] || exit 0

# Enable snippets on local storage
echo ""
echo "[1/4] Enabling snippets storage..."
CURRENT_CONTENT=$(pvesm status --content snippets 2>/dev/null | grep -c "^local" || echo "0")
if [[ "$CURRENT_CONTENT" -eq 0 ]]; then
    pvesm set local --content iso,backup,vztmpl,snippets
fi
mkdir -p /var/lib/vz/snippets

# Save config for other scripts
echo "[2/4] Saving configuration..."
cat > /etc/github-runners.conf << EOF
GITHUB_ORG="$GITHUB_ORG"
GITHUB_PAT="$GITHUB_PAT"
NETWORK_BRIDGE="$NETWORK_BRIDGE"
VM_STORAGE="$VM_STORAGE"
TEMPLATE_ID="$TEMPLATE_ID"
EOF
chmod 600 /etc/github-runners.conf

# Generate cloud-init from template
echo "[3/4] Creating cloud-init snippet..."
sed -e "s|{{GITHUB_PAT}}|$GITHUB_PAT|g" \
    -e "s|{{GITHUB_ORG}}|$GITHUB_ORG|g" \
    "$SCRIPT_DIR/templates/runner-user-data.yaml" > /var/lib/vz/snippets/runner-user-data.yaml

# Check if template already exists
if qm status $TEMPLATE_ID &> /dev/null; then
    echo "[4/4] Template VM $TEMPLATE_ID already exists. Skipping creation."
    echo "      To recreate: qm destroy $TEMPLATE_ID && ./setup.sh"
else
    # Download and create template
    echo "[4/4] Creating Ubuntu cloud template..."
    CLOUD_IMG="jammy-server-cloudimg-amd64.img"

    if [[ ! -f "/tmp/$CLOUD_IMG" ]]; then
        echo "      Downloading Ubuntu 22.04 cloud image..."
        wget -q --show-progress -O "/tmp/$CLOUD_IMG" \
            "https://cloud-images.ubuntu.com/jammy/current/$CLOUD_IMG"
    else
        echo "      Using cached cloud image from /tmp/$CLOUD_IMG"
    fi

    qm create $TEMPLATE_ID --name ubuntu-cloud-template \
        --memory 8192 --cores 2 --net0 virtio,bridge=$NETWORK_BRIDGE
    qm importdisk $TEMPLATE_ID "/tmp/$CLOUD_IMG" $VM_STORAGE
    qm set $TEMPLATE_ID --scsihw virtio-scsi-pci \
        --scsi0 ${VM_STORAGE}:vm-${TEMPLATE_ID}-disk-0
    qm set $TEMPLATE_ID --ide2 ${VM_STORAGE}:cloudinit
    qm set $TEMPLATE_ID --boot c --bootdisk scsi0
    qm set $TEMPLATE_ID --serial0 socket --vga serial0
    qm set $TEMPLATE_ID --agent enabled=1
    qm resize $TEMPLATE_ID scsi0 30G
    qm template $TEMPLATE_ID
fi

echo ""
echo "========================================"
echo "  Setup complete!"
echo "========================================"
echo ""
echo "Create runners with:"
echo "  ./create-runner.sh runner-01"
echo "  ./create-runner.sh runner-02"
echo ""
echo "List runners with:"
echo "  ./list-runners.sh"
echo ""
