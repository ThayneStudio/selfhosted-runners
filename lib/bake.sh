#!/bin/bash
# Shared template bake. Callers source common.sh first and run as root on Proxmox.
# The guest writes /opt/.template-setup-complete last and does not power itself off.
# This side confirms that marker, shuts the VM down, and only then runs `qm template`.
set -euo pipefail

IMG_CACHE_DIR="/var/cache/github-runners"
CLOUD_IMG="noble-server-cloudimg-amd64.img"
BAKE_RUNNER_VERSION=""

# Proxmox helpers can fork long-lived kvm processes. Those must not inherit
# the rebake lock (199) or the VMID reservation (203).
qm_host() {
    qm "$@" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&-
}

prepare_cloud_image() {
    local cloud_img_url checksum_url expected actual

    mkdir -p "$IMG_CACHE_DIR"
    chmod 700 "$IMG_CACHE_DIR"
    cloud_img_url="https://cloud-images.ubuntu.com/noble/current/$CLOUD_IMG"

    if [[ ! -f "$IMG_CACHE_DIR/$CLOUD_IMG" ]]; then
        log_info "Downloading Ubuntu 24.04 cloud image..."
        if ! wget -q --show-progress -O "$IMG_CACHE_DIR/$CLOUD_IMG" "$cloud_img_url"; then
            log_error "Failed to download cloud image"
            rm -f "$IMG_CACHE_DIR/$CLOUD_IMG"
            return 1
        fi
    else
        log_info "Using cached cloud image from $IMG_CACHE_DIR/$CLOUD_IMG"
    fi

    if [[ ! -s "$IMG_CACHE_DIR/$CLOUD_IMG" ]]; then
        log_error "Cloud image is empty or missing"
        rm -f "$IMG_CACHE_DIR/$CLOUD_IMG"
        return 1
    fi

    # A mismatch deletes the cache and fails before any template VM is created.
    log_info "Verifying cloud image checksum..."
    checksum_url="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
    # head -1 can SIGPIPE the producer. Tolerate that, and a failed checksum
    # download, so a missing SHA256SUMS still skips verification. Callers run
    # this function with errexit on.
    expected=$(wget -q -O - "$checksum_url" | grep -F "$CLOUD_IMG" | head -1 | awk '{print $1}') || true
    if [[ -n "$expected" ]]; then
        actual=$(sha256sum "$IMG_CACHE_DIR/$CLOUD_IMG" | awk '{print $1}') || true
        if [[ "$actual" != "$expected" ]]; then
            log_error "Checksum verification failed!"
            log_error "Expected: $expected"
            log_error "Got:      $actual"
            rm -f "$IMG_CACHE_DIR/$CLOUD_IMG"
            return 1
        fi
        log_info "Checksum verified"
    else
        log_warn "Could not fetch checksum from Ubuntu — skipping verification"
    fi
}

render_template_setup_snippet() {
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
}

create_bake_vm() {
    local vmid="$1"
    local net_config="virtio,bridge=$NETWORK_BRIDGE"

    if [[ -n "${VLAN_TAG:-}" ]]; then
        net_config="${net_config},tag=$VLAN_TAG"
    fi
    qm_host create "$vmid" --name ubuntu-cloud-template \
        --memory 8192 --balloon "${BALLOON:-0}" --cores 2 --cpu host --net0 "$net_config"
}

# Import, boot, wait for the guest marker, read Runner.Listener --version,
# shut down, and convert. Does not change TEMPLATE_ID. On failure the caller's
# EXIT trap destroys the VM; this function never publishes a VM whose marker
# was not confirmed.
bake_and_publish_vm() {
    local vmid="$1"
    local import_output imported_disk exec_result exec_exit vm_status
    local bake_elapsed=0 bake_interval=15 bake_ready=false
    local bake_timeout="${BAKE_TIMEOUT:-5400}"
    local minutes seconds_rem i

    import_output=$(qm_host importdisk "$vmid" "$IMG_CACHE_DIR/$CLOUD_IMG" "$VM_STORAGE" 2>&1) || {
        log_error "Failed to import disk"
        printf '%s\n' "$import_output" >&2
        return 1
    }

    if [[ "$import_output" =~ unused0:([^\'\"[:space:]]+) ]]; then
        imported_disk="${BASH_REMATCH[1]}"
    else
        imported_disk="${VM_STORAGE}:vm-${vmid}-disk-0"
        log_warn "Could not parse imported disk name from importdisk output:"
        log_warn "$import_output"
        log_warn "Assuming: $imported_disk"
    fi

    qm_host set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$imported_disk" \
        || { log_error "Failed to configure SCSI"; return 1; }
    qm_host set "$vmid" --ide2 "${VM_STORAGE}:cloudinit" \
        || { log_error "Failed to add cloud-init drive"; return 1; }
    qm_host set "$vmid" --boot c --bootdisk scsi0 \
        || { log_error "Failed to set boot disk"; return 1; }
    qm_host set "$vmid" --serial0 socket --vga serial0 \
        || { log_error "Failed to set serial"; return 1; }
    qm_host set "$vmid" --agent enabled=1 \
        || { log_error "Failed to enable agent"; return 1; }
    qm_host resize "$vmid" scsi0 30G \
        || { log_error "Failed to resize disk"; return 1; }

    log_info "Configuring template cloud-init..."
    render_template_setup_snippet

    qm_host set "$vmid" --cicustom "user=local:snippets/template-setup.yaml" \
        || { log_error "Failed to set cloud-init config"; return 1; }
    qm_host set "$vmid" --ipconfig0 ip=dhcp \
        || { log_error "Failed to set IP config"; return 1; }
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        qm_host set "$vmid" --nameserver "$DNS_SERVERS" \
            || { log_error "Failed to set DNS servers"; return 1; }
    fi
    qm_host set "$vmid" --ciuser runner \
        || { log_error "Failed to set cloud-init user"; return 1; }

    log_info "Starting VM to install tools (this can take a while on cold caches)..."
    if ! qm_host start "$vmid"; then
        log_error "Failed to start template VM"
        return 1
    fi

    log_info "Waiting for tool installation to complete..."
    log_info "  (Monitor progress: qm guest exec $vmid -- cat /var/log/template-setup.log)"

    while true; do
        sleep "$bake_interval"
        bake_elapsed=$((bake_elapsed + bake_interval))

        if [[ $bake_elapsed -ge $bake_timeout ]]; then
            echo "" >&2
            log_error "Bake timed out after $((bake_timeout / 60)) minutes (override with BAKE_TIMEOUT=<seconds>)"
            log_error "Last 40 lines from the guest:"
            qm_host guest exec "$vmid" -- tail -n 40 /var/log/template-setup.log 2>/dev/null \
                | jq -r '."out-data" // empty' >&2 || true
            return 1
        fi

        # The guest never powers itself off. A stopped VM is a crash or an
        # external `qm stop`, never success.
        vm_status=$(qm_host status "$vmid" 2>/dev/null | awk '{print $2}') || true
        if [[ "$vm_status" != "running" ]]; then
            echo "" >&2
            log_error "Template VM stopped before setup completion was confirmed"
            log_error "Refusing to publish a possibly half-baked template."
            return 1
        fi

        exec_result=$(qm_host guest exec "$vmid" -- test -f /opt/.template-setup-complete 2>&1) || {
            minutes=$((bake_elapsed / 60))
            seconds_rem=$((bake_elapsed % 60))
            printf '\r  Elapsed: %dm%02ds (waiting for guest agent...)' "$minutes" "$seconds_rem" >&2
            continue
        }

        exec_exit=$(printf '%s\n' "$exec_result" | jq -r '.exitcode // "1"' 2>/dev/null) || exec_exit="1"
        if [[ "$exec_exit" == "0" ]]; then
            bake_ready=true
            echo "" >&2
            log_info "Template setup complete!"
            break
        fi

        minutes=$((bake_elapsed / 60))
        seconds_rem=$((bake_elapsed % 60))
        printf '\r  Elapsed: %dm%02ds (installing tools...)' "$minutes" "$seconds_rem" >&2
    done
    echo "" >&2

    if [[ "$bake_ready" != "true" ]]; then
        log_error "Internal error: bake loop exited without a confirmed completion marker"
        return 1
    fi

    # Read while the guest is still up. qm template leaves the VM stopped, and
    # guest exec cannot read it after that.
    if ! BAKE_RUNNER_VERSION=$(read_baked_listener_version "$vmid"); then
        log_error "Bake finished but Runner.Listener --version could not be read"
        return 1
    fi
    log_info "Baked Runner.Listener version: $BAKE_RUNNER_VERSION"
    # Only the side-template rebake sets this. setup bakes the live TEMPLATE_ID
    # and must not leave a pending-version file for a later recover to trust.
    if [[ "${BAKE_WRITE_PENDING_VERSION:-}" == 1 && -n "${PENDING_VERSION_FILE:-}" ]]; then
        install -d -m 700 "$(dirname "$PENDING_VERSION_FILE")"
        printf 'version=%q\n' "$BAKE_RUNNER_VERSION" > "$PENDING_VERSION_FILE"
        chmod 600 "$PENDING_VERSION_FILE"
    fi

    log_info "Shutting down template VM..."
    qm_host shutdown "$vmid" --timeout 120 || {
        log_warn "Graceful shutdown failed, forcing..."
        qm_host stop "$vmid" --skiplock 2>/dev/null || true
    }
    vm_status=""
    for ((i = 1; i <= 60; i++)); do
        vm_status=$(qm_host status "$vmid" 2>/dev/null | awk '{print $2}') || true
        [[ "$vm_status" == "stopped" ]] && break
        sleep 2
    done
    if [[ "$vm_status" != "stopped" ]]; then
        log_error "Template VM did not reach stopped state; refusing to convert to template"
        return 1
    fi

    log_info "Preparing template for cloning..."
    qm_host set "$vmid" --delete cicustom 2>/dev/null || true
    qm_host set "$vmid" --delete ciuser 2>/dev/null || true
    qm_host set "$vmid" --delete ipconfig0 2>/dev/null || true
    qm_host set "$vmid" --delete nameserver 2>/dev/null || true

    qm_host template "$vmid" || { log_error "Failed to convert to template"; return 1; }
    # Set before returning so a signal in the caller cannot destroy a VM that
    # qm template already published. cleanup_rebake reads this; setup's trap does not.
    # shellcheck disable=SC2034
    REBAKE_PUBLISHED=1
}

read_baked_listener_version() {
    local vmid="$1" result exitcode out
    result=$(qm_host guest exec "$vmid" -- cat /opt/.baked-runner-version 2>/dev/null) || return 1
    exitcode=$(printf '%s\n' "$result" | jq -r '.exitcode // 1' 2>/dev/null) || return 1
    [[ "$exitcode" == "0" ]] || return 1
    out=$(printf '%s\n' "$result" | jq -r '.["out-data"] // empty' 2>/dev/null) || return 1
    out=$(printf '%s' "$out" | tr -d '[:space:]')
    [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$out"
}
