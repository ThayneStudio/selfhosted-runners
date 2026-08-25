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
    # never destroys. Fresh-host bake is Task 7.
    # shellcheck source=generations.sh
    source "$LIB_DIR/generations.sh"
    adopt_deployed_template
else
    # Download and create template
    log_info "[4/5] Creating baked Ubuntu cloud template..."
    CLOUD_IMG="noble-server-cloudimg-amd64.img"
    CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/$CLOUD_IMG"

    # Use a root-only cache directory instead of world-writable /tmp/
    # to prevent symlink attacks or image replacement by unprivileged users
    IMG_CACHE_DIR="/var/cache/github-runners"
    mkdir -p "$IMG_CACHE_DIR"
    chmod 700 "$IMG_CACHE_DIR"

    CLOUD_IMG_PATH="$IMG_CACHE_DIR/$CLOUD_IMG"
    CHECKSUM_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
    # Floor for the plausibility check below, not a validity gate. The published
    # image is ~595 MB; this sits under that so an upstream size change does not
    # start failing bakes on its own.
    MIN_CLOUD_IMG_BYTES=$((400 * 1024 * 1024))

    # Names the build upstream actually served. pve-test kept receiving the
    # 20260615 image long after noble/current had moved on, which a hash alone
    # does not reveal; Last-Modified/ETag identify the build without comparing
    # the hash against every dated directory by hand. Diagnostic only — a failed
    # or unparsable probe must never affect the bake.
    log_served_build() {
        local headers served
        headers=$(wget -S --spider --tries=1 --timeout=15 "$CLOUD_IMG_URL" 2>&1) || return 0
        served=$(printf '%s\n' "$headers" \
            | grep -iE '^[[:space:]]*(Last-Modified|ETag|Content-Length):' \
            | tr -d '\r' | tr '\n' ' ' | tr -s ' ') || return 0
        [[ -n "$served" ]] && log_info "Upstream served:$served"
        return 0
    }

    # $1 is the attempt number. --tries/--timeout absorb a transient reset
    # without spending the one retry on it. The retry also sends no-cache
    # request headers; those only reach an explicit proxy or something
    # terminating TLS, so treat them as cheap rather than reliable — the served
    # headers logged next are what actually identify a mirror stuck on an old
    # dated build.
    download_cloud_img() {
        local -a wget_args=(-q --show-progress --tries=3 --timeout=30)
        if (( $1 > 1 )); then
            wget_args+=(--no-cache)
            log_info "Re-downloading Ubuntu 24.04 cloud image (asking caches to revalidate)..."
        else
            log_info "Downloading Ubuntu 24.04 cloud image..."
        fi
        if ! wget "${wget_args[@]}" -O "$CLOUD_IMG_PATH" "$CLOUD_IMG_URL"; then
            log_error "Failed to download cloud image"
            return 1
        fi
        log_served_build
    }

    # A diagnostic, not a validity gate: the SHA256 comparison below is what
    # establishes that this is the image upstream published. This only checks a
    # size floor and the four-byte qcow2 magic so that a truncated transfer or
    # an error page says what it is, instead of surfacing as a checksum failure
    # that reads like tampering. The magic is read directly rather than through
    # qemu-img so the check holds on any host.
    check_cloud_img_plausible() {
        local size magic head_bytes
        size=$(wc -c < "$CLOUD_IMG_PATH")
        size=${size//[[:space:]]/}
        if (( size < MIN_CLOUD_IMG_BYTES )); then
            log_error "Cloud image is ${size:-0} bytes, far below the ~600 MB upstream publishes"
            log_error "The download did not return a whole image — look for a proxy, captive portal, 404 page or truncated transfer"
            head_bytes=$(head -c 200 "$CLOUD_IMG_PATH" | tr -cd '[:print:]' | tr -s ' ')
            [[ -n "$head_bytes" ]] && log_error "Response began: $head_bytes"
            return 1
        fi
        magic=$(od -An -N4 -tx1 "$CLOUD_IMG_PATH" | tr -cd '[:xdigit:]')
        if [[ "$magic" != "514649fb" ]]; then
            log_error "Cloud image is $size bytes but does not start with the qcow2 magic"
            log_error "Leading bytes: ${magic:-none} (expected 514649fb)"
            return 1
        fi
        return 0
    }

    # Ubuntu rotates noble/current every 2-4 weeks, so a cached image that no
    # longer matches SHA256SUMS is far more often stale than tampered with.
    # Discard it and download once more before treating the mismatch as fatal.
    # SHA256SUMS is re-fetched each attempt so a rotation that lands mid-run
    # recovers too, rather than pairing a new image against the old sums.
    FIRST_ATTEMPT_NOTE=""
    for attempt in 1 2; do
        if [[ -f "$CLOUD_IMG_PATH" ]]; then
            log_info "Using cached cloud image from $CLOUD_IMG_PATH"
        elif ! download_cloud_img "$attempt"; then
            rm -f "$CLOUD_IMG_PATH"
            (( attempt == 1 )) || log_error "The re-download failed; attempt 1 had produced $FIRST_ATTEMPT_NOTE"
            exit 1
        fi

        if ! check_cloud_img_plausible; then
            rm -f "$CLOUD_IMG_PATH"
            if (( attempt == 1 )); then
                FIRST_ATTEMPT_NOTE="a file that was not a usable image"
                log_warn "Discarding it and downloading again (attempt 2 of 2)..."
                continue
            fi
            log_error "The re-downloaded file was not a usable image either — aborting"
            exit 1
        fi

        # Verify SHA256 checksum. There is no proceed-without-it path: an
        # unverified image would be baked into the template every runner clones.
        log_info "Verifying cloud image checksum..."
        SHA256SUMS_TEXT=$(wget -q -O - --tries=3 --timeout=30 "$CHECKSUM_URL") || {
            log_error "Could not fetch $CHECKSUM_URL — cannot verify the cloud image"
            exit 1
        }
        # Selected by exact filename. SHA256SUMS is sorted by hash, so picking a
        # line by position would become arbitrary the day upstream adds a
        # suffixed entry. awk also reports no-match as empty output rather than
        # a non-zero status, which would abort this script without a word.
        EXPECTED_SHA256=$(printf '%s\n' "$SHA256SUMS_TEXT" \
            | awk -v img="$CLOUD_IMG" '$2 == img || $2 == "*" img { print $1; exit }')
        if [[ -z "$EXPECTED_SHA256" ]]; then
            log_error "No entry for $CLOUD_IMG in $CHECKSUM_URL — cannot verify the cloud image"
            exit 1
        fi

        ACTUAL_SHA256=$(sha256sum "$CLOUD_IMG_PATH" | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]]; then
            log_info "Checksum verified"
            if [[ -n "$FIRST_ATTEMPT_NOTE" ]]; then
                log_warn "This bake needed a second download: attempt 1 produced $FIRST_ATTEMPT_NOTE"
                log_warn "Attempt 2 matched upstream SHA256SUMS: $EXPECTED_SHA256"
            fi
            break
        fi

        rm -f "$CLOUD_IMG_PATH"
        if (( attempt == 1 )); then
            FIRST_ATTEMPT_NOTE="an image hashing $ACTUAL_SHA256"
            log_warn "Cloud image does not match upstream SHA256SUMS"
            log_warn "Expected: $EXPECTED_SHA256"
            log_warn "Got:      $ACTUAL_SHA256"
            log_warn "Upstream rotates noble/current every few weeks, so a cached image is most often simply stale."
            log_warn "Discarding it and downloading again (attempt 2 of 2)..."
            continue
        fi

        log_error "Checksum verification failed on both attempts — nothing was imported"
        log_error "Expected: $EXPECTED_SHA256"
        log_error "Got:      $ACTUAL_SHA256"
        log_error "Attempt 1 produced $FIRST_ATTEMPT_NOTE"
        log_error "The second download asked caches to revalidate and still did not match."
        log_error "Check any upstream headers logged above: if the build served is older than the"
        log_error "one noble/current now points at, compare it against the SHA256SUMS under"
        log_error "https://cloud-images.ubuntu.com/noble/<date>/ to name it, then inspect"
        log_error "http_proxy, /etc/wgetrc and DNS for cloud-images.ubuntu.com on this host."
        exit 1
    done

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

    # Cleanup trap: destroy template VM on any failure or interrupt from this point
    cleanup_bake() {
        log_warn "Baking failed, cleaning up template VM..."
        qm stop "$TEMPLATE_ID" --timeout 30 2>/dev/null || true
        qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
    }
    trap cleanup_bake EXIT

    IMPORT_OUTPUT=$(qm importdisk "$TEMPLATE_ID" "$IMG_CACHE_DIR/$CLOUD_IMG" "$VM_STORAGE" 2>&1) || {
        log_error "Failed to import disk"
        echo "$IMPORT_OUTPUT" >&2
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

    qm set "$TEMPLATE_ID" --scsihw virtio-scsi-pci --scsi0 "$IMPORTED_DISK" \
        || { log_error "Failed to configure SCSI"; exit 1; }
    qm set "$TEMPLATE_ID" --ide2 "${VM_STORAGE}:cloudinit" \
        || { log_error "Failed to add cloud-init drive"; exit 1; }
    qm set "$TEMPLATE_ID" --boot c --bootdisk scsi0 \
        || { log_error "Failed to set boot disk"; exit 1; }
    qm set "$TEMPLATE_ID" --serial0 socket --vga serial0 \
        || { log_error "Failed to set serial"; exit 1; }
    qm set "$TEMPLATE_ID" --agent enabled=1 \
        || { log_error "Failed to enable agent"; exit 1; }
    qm resize "$TEMPLATE_ID" scsi0 30G \
        || { log_error "Failed to resize disk"; exit 1; }

    # Copy template-setup cloud-init to snippets and configure
    log_info "Configuring template cloud-init..."
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
    }' "$INSTALL_DIR/templates/template-setup.yaml" > "$SNIPPETS_DIR/template-setup.yaml"
    chmod 600 "$SNIPPETS_DIR/template-setup.yaml"

    qm set "$TEMPLATE_ID" --cicustom "user=local:snippets/template-setup.yaml" \
        || { log_error "Failed to set cloud-init config"; exit 1; }
    qm set "$TEMPLATE_ID" --ipconfig0 ip=dhcp \
        || { log_error "Failed to set IP config"; exit 1; }
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        qm set "$TEMPLATE_ID" --nameserver "$DNS_SERVERS" \
            || { log_error "Failed to set DNS servers"; exit 1; }
    fi
    qm set "$TEMPLATE_ID" --ciuser runner \
        || { log_error "Failed to set cloud-init user"; exit 1; }

    # Boot VM to bake tools into the template
    log_info "Starting VM to install tools (this can take a while on cold caches)..."
    if ! qm start "$TEMPLATE_ID"; then
        log_error "Failed to start template VM"
        exit 1
    fi

    # Poll for the guest's completion marker. The guest stays running until we
    # confirm the marker and shut it down ourselves — see templates/template-setup.yaml.
    log_info "Waiting for tool installation to complete..."
    log_info "  (Monitor progress: qm guest exec $TEMPLATE_ID -- cat /var/log/template-setup.log)"
    BAKE_ELAPSED=0
    BAKE_INTERVAL=15
    BAKE_TIMEOUT="${BAKE_TIMEOUT:-5400}"   # 90 min; a healthy bake runs ~30-45
    BAKE_READY=false

    while true; do
        sleep $BAKE_INTERVAL
        BAKE_ELAPSED=$((BAKE_ELAPSED + BAKE_INTERVAL))

        if [[ $BAKE_ELAPSED -ge $BAKE_TIMEOUT ]]; then
            echo "" >&2
            log_error "Bake timed out after $((BAKE_TIMEOUT / 60)) minutes (override with BAKE_TIMEOUT=<seconds>)"
            log_error "Last 40 lines from the guest:"
            qm guest exec "$TEMPLATE_ID" -- tail -n 40 /var/log/template-setup.log 2>/dev/null \
                | jq -r '."out-data" // empty' >&2 || true
            exit 1
        fi

        # The guest never powers itself off, so a stopped VM means a crash or an
        # external `qm stop` — never success. Refuse to publish.
        VM_STATUS=$(qm status "$TEMPLATE_ID" 2>/dev/null | awk '{print $2}') || true
        if [[ "$VM_STATUS" != "running" ]]; then
            echo "" >&2
            log_error "Template VM stopped before setup completion was confirmed"
            log_error "Refusing to publish a possibly half-baked template."
            exit 1
        fi

        # Try to check for completion marker via guest agent
        EXEC_RESULT=$(qm guest exec "$TEMPLATE_ID" -- test -f /opt/.template-setup-complete 2>&1) || {
            # Guest agent not ready yet (still installing qemu-guest-agent)
            MINUTES=$((BAKE_ELAPSED / 60))
            SECONDS_REM=$((BAKE_ELAPSED % 60))
            printf '\r  Elapsed: %dm%02ds (waiting for guest agent...)' "$MINUTES" "$SECONDS_REM" >&2
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
        printf '\r  Elapsed: %dm%02ds (installing tools...)' "$MINUTES" "$SECONDS_REM" >&2
    done
    echo "" >&2

    # Publish gate: never convert a VM whose marker we did not confirm.
    if [[ "$BAKE_READY" != "true" ]]; then
        log_error "Internal error: bake loop exited without a confirmed completion marker"
        exit 1
    fi

    log_info "Shutting down template VM..."
    qm shutdown "$TEMPLATE_ID" --timeout 120 || {
        log_warn "Graceful shutdown failed, forcing..."
        qm stop "$TEMPLATE_ID" --skiplock 2>/dev/null || true
    }
    # shellcheck disable=SC2034  # loop counter is unused; this is a bounded poll
    for i in {1..60}; do
        VM_STATUS=$(qm status "$TEMPLATE_ID" 2>/dev/null | awk '{print $2}') || true
        [[ "$VM_STATUS" == "stopped" ]] && break
        sleep 2
    done
    if [[ "$VM_STATUS" != "stopped" ]]; then
        log_error "Template VM did not reach stopped state; refusing to convert to template"
        exit 1
    fi

    # Clear bake-time cloud-init settings so clones start fresh
    log_info "Preparing template for cloning..."
    qm set "$TEMPLATE_ID" --delete cicustom 2>/dev/null || true
    qm set "$TEMPLATE_ID" --delete ciuser 2>/dev/null || true
    qm set "$TEMPLATE_ID" --delete ipconfig0 2>/dev/null || true
    qm set "$TEMPLATE_ID" --delete nameserver 2>/dev/null || true

    # Convert to template
    qm template "$TEMPLATE_ID" || { log_error "Failed to convert to template"; exit 1; }

    # Disable cleanup trap — template created successfully
    trap - EXIT

    log_info "Template created successfully (tools baked in)"
fi

log_info "[5/5] Installing pool watcher and lifetime guard timers..."
cp "$INSTALL_DIR/templates/github-runner-watch.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-watch.timer" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-guard.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-guard.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now github-runner-watch.timer 2>/dev/null || true
systemctl enable --now github-runner-guard.timer 2>/dev/null || true
log_info "Pool watcher timer installed (30s interval)"
log_info "Lifetime guard timer installed (5m interval, ${MAX_VM_LIFETIME_HOURS}h VM ceiling, ${STOPPED_REAP_MINUTES}m stopped reap)"
echo "  Preview what it would destroy:  runner guard --dry-run"
echo "  Turn it off:                    systemctl disable --now github-runner-guard.timer"

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
