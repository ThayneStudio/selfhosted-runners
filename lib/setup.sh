#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

INSTALL_DIR="/opt/selfhosted-runners"

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

# Get the repo root directory (this script lives in lib/)
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
REPO_DIR="$(cd "$(dirname "$SOURCE")/.." && pwd)"

# Check if template file exists
if [[ ! -f "$REPO_DIR/templates/runner-user-data.yaml" ]]; then
    log_error "templates/runner-user-data.yaml not found in $REPO_DIR"
    exit 1
fi

# Collect and validate GitHub Organization
while true; do
    read -p "GitHub Organization name: " GITHUB_ORG
    if [[ -z "$GITHUB_ORG" ]]; then
        log_error "Organization name cannot be empty"
        continue
    fi
    if [[ ! "$GITHUB_ORG" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid organization name. Use only letters, numbers, hyphens, underscores."
        continue
    fi
    break
done

# Collect and validate GitHub PAT
while true; do
    read -sp "GitHub PAT (admin:org scope): " GITHUB_PAT
    echo ""
    if [[ -z "$GITHUB_PAT" ]]; then
        log_error "PAT cannot be empty"
        continue
    fi
    if [[ ! "$GITHUB_PAT" =~ ^(ghp_|github_pat_) ]]; then
        log_warn "PAT doesn't start with 'ghp_' or 'github_pat_'. Make sure it's valid."
        read -p "Continue anyway? [y/N]: " CONTINUE
        [[ "${CONTINUE:-N}" =~ ^[Yy]$ ]] || continue
    fi
    break
done

# Validate PAT by testing GitHub API
log_info "Validating PAT with GitHub API..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/orgs/${GITHUB_ORG}")

if [[ "$HTTP_CODE" != "200" ]]; then
    log_error "GitHub API returned HTTP $HTTP_CODE"
    log_error "Check that your PAT has 'admin:org' scope and the organization name is correct."
    exit 1
fi
log_info "PAT validated successfully"

# Detect available bridges
echo ""
echo "Available network bridges:"
BRIDGES=$(ip -br link | grep -E '^vmbr' | awk '{print $1}' || true)
if [[ -z "$BRIDGES" ]]; then
    log_warn "No bridges found (vmbr*). Using default vmbr0."
else
    echo "$BRIDGES" | sed 's/^/  /'
fi
read -p "Network bridge [vmbr0]: " NETWORK_BRIDGE
NETWORK_BRIDGE=${NETWORK_BRIDGE:-vmbr0}

# Validate bridge exists
if ! ip link show "$NETWORK_BRIDGE" &> /dev/null; then
    log_error "Bridge '$NETWORK_BRIDGE' does not exist"
    exit 1
fi

# VLAN tag (optional)
read -p "VLAN tag (leave empty for none): " VLAN_TAG
if [[ -n "$VLAN_TAG" ]]; then
    if [[ ! "$VLAN_TAG" =~ ^[0-9]+$ ]] || [[ "$VLAN_TAG" -lt 1 || "$VLAN_TAG" -gt 4094 ]]; then
        log_error "VLAN tag must be a number between 1 and 4094"
        exit 1
    fi
fi

# Detect storage
echo ""
echo "Available storage pools:"
pvesm status | grep -E 'zfspool|dir|lvm' | awk '{print "  " $1 " (" $2 ")"}'
read -p "Storage for VMs [local-zfs]: " VM_STORAGE
VM_STORAGE=${VM_STORAGE:-local-zfs}

# Validate storage exists
if ! pvesm status | grep -qw "$VM_STORAGE"; then
    log_error "Storage pool '$VM_STORAGE' does not exist"
    exit 1
fi

read -p "Template VM ID [9000]: " TEMPLATE_ID
TEMPLATE_ID=${TEMPLATE_ID:-9000}

# Validate template ID is a number
if [[ ! "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
    log_error "Template ID must be a number"
    exit 1
fi

# Confirm
echo ""
echo "Configuration:"
echo "  GitHub Org:     $GITHUB_ORG"
echo "  PAT:            ${GITHUB_PAT:0:10}... (validated)"
echo "  Network Bridge: $NETWORK_BRIDGE"
echo "  VLAN Tag:       ${VLAN_TAG:-none}"
echo "  VM Storage:     $VM_STORAGE"
echo "  Template ID:    $TEMPLATE_ID"
echo ""
read -p "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]$ ]] || exit 0

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
CURRENT_CONTENT=$(pvesm status --content snippets 2>/dev/null | grep -c "^local" || echo "0")
if [[ "$CURRENT_CONTENT" -eq 0 ]]; then
    pvesm set local --content iso,backup,vztmpl,snippets || {
        log_error "Failed to enable snippets on local storage"
        exit 1
    }
fi
mkdir -p /var/lib/vz/snippets

# Save config for other scripts
log_info "[3/5] Saving configuration..."
cat > /etc/github-runners.conf << EOF
GITHUB_ORG="$GITHUB_ORG"
GITHUB_PAT="$GITHUB_PAT"
NETWORK_BRIDGE="$NETWORK_BRIDGE"
VLAN_TAG="${VLAN_TAG}"
VM_STORAGE="$VM_STORAGE"
TEMPLATE_ID="$TEMPLATE_ID"
EOF
chmod 600 /etc/github-runners.conf

# Generate cloud-init from template
# Escape special characters in PAT for sed
log_info "[4/5] Creating cloud-init snippet..."
ESCAPED_PAT=$(printf '%s\n' "$GITHUB_PAT" | sed -e 's/[\/&]/\\&/g')
ESCAPED_ORG=$(printf '%s\n' "$GITHUB_ORG" | sed -e 's/[\/&]/\\&/g')
sed -e "s|{{GITHUB_PAT}}|$ESCAPED_PAT|g" \
    -e "s|{{GITHUB_ORG}}|$ESCAPED_ORG|g" \
    "$INSTALL_DIR/templates/runner-user-data.yaml" > /var/lib/vz/snippets/runner-user-data.yaml || {

    log_error "Failed to generate cloud-init snippet"
    exit 1
}

# Check if template already exists
if qm status $TEMPLATE_ID &> /dev/null; then
    log_info "[5/5] Template VM $TEMPLATE_ID already exists. Skipping creation."
    log_warn "To recreate: qm destroy $TEMPLATE_ID && ./setup.sh"
else
    # Download and create template
    log_info "[5/5] Creating Ubuntu cloud template..."
    CLOUD_IMG="jammy-server-cloudimg-amd64.img"
    CLOUD_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/$CLOUD_IMG"
    # SHA256 checksum from Ubuntu (update periodically)
    # Get latest from: https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS

    if [[ ! -f "/tmp/$CLOUD_IMG" ]]; then
        log_info "Downloading Ubuntu 22.04 cloud image..."
        if ! wget -q --show-progress -O "/tmp/$CLOUD_IMG" "$CLOUD_IMG_URL"; then
            log_error "Failed to download cloud image"
            rm -f "/tmp/$CLOUD_IMG"
            exit 1
        fi
    else
        log_info "Using cached cloud image from /tmp/$CLOUD_IMG"
    fi

    # Verify image is valid (basic check)
    if [[ ! -s "/tmp/$CLOUD_IMG" ]]; then
        log_error "Cloud image is empty or missing"
        rm -f "/tmp/$CLOUD_IMG"
        exit 1
    fi

    log_info "Creating VM template..."
    NET_CONFIG="virtio,bridge=$NETWORK_BRIDGE"
    if [[ -n "$VLAN_TAG" ]]; then
        NET_CONFIG="${NET_CONFIG},tag=$VLAN_TAG"
    fi
    if ! qm create $TEMPLATE_ID --name ubuntu-cloud-template \
        --memory 8192 --cores 2 --net0 "$NET_CONFIG"; then
        log_error "Failed to create VM"
        exit 1
    fi

    if ! qm importdisk $TEMPLATE_ID "/tmp/$CLOUD_IMG" $VM_STORAGE; then
        log_error "Failed to import disk"
        qm destroy $TEMPLATE_ID --purge 2>/dev/null || true
        exit 1
    fi

    if ! qm set $TEMPLATE_ID --scsihw virtio-scsi-pci \
        --scsi0 ${VM_STORAGE}:vm-${TEMPLATE_ID}-disk-0; then
        log_error "Failed to configure SCSI"
        qm destroy $TEMPLATE_ID --purge 2>/dev/null || true
        exit 1
    fi

    if ! qm set $TEMPLATE_ID --ide2 ${VM_STORAGE}:cloudinit; then
        log_error "Failed to add cloud-init drive"
        qm destroy $TEMPLATE_ID --purge 2>/dev/null || true
        exit 1
    fi

    qm set $TEMPLATE_ID --boot c --bootdisk scsi0 || { log_error "Failed to set boot disk"; exit 1; }
    qm set $TEMPLATE_ID --serial0 socket --vga serial0 || { log_error "Failed to set serial"; exit 1; }
    qm set $TEMPLATE_ID --agent enabled=1 || { log_error "Failed to enable agent"; exit 1; }
    qm resize $TEMPLATE_ID scsi0 30G || { log_error "Failed to resize disk"; exit 1; }
    qm template $TEMPLATE_ID || { log_error "Failed to convert to template"; exit 1; }

    log_info "Template created successfully"
fi

echo ""
echo "========================================"
echo "  Setup complete!"
echo "========================================"
echo ""
echo "Installed to: $INSTALL_DIR"
echo ""
echo "Usage:"
echo "  runner create runner-01"
echo "  runner create runner-02"
echo "  runner list"
echo "  runner destroy runner-01"
echo "  runner setup               (re-run this wizard)"
echo "  runner help"
echo ""
echo "View runners in GitHub:"
echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
echo ""
