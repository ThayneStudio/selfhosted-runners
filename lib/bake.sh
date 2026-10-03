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
    local base_url img tmp expected actual
    local -a progress=()

    mkdir -p "$IMG_CACHE_DIR"
    chmod 700 "$IMG_CACHE_DIR"
    base_url="https://cloud-images.ubuntu.com/noble/current"
    img="$IMG_CACHE_DIR/$CLOUD_IMG"

    # head -1 can SIGPIPE the producer. Tolerate that, and a failed checksum
    # download, so a missing SHA256SUMS still skips verification. Callers run
    # this function with errexit on.
    expected=$(wget -q -O - "$base_url/SHA256SUMS" | grep -F "$CLOUD_IMG" | head -1 | awk '{print $1}') || true

    # Upstream rotates noble/current every few weeks, so a cache from the last
    # bake is usually stale by the next one. Replace it rather than failing.
    if [[ -s "$img" ]]; then
        if [[ -z "$expected" ]]; then
            log_warn "Could not fetch checksum from Ubuntu — using the cached image unverified"
            return 0
        fi
        actual=$(sha256sum "$img" | awk '{print $1}') || true
        if [[ "$actual" == "$expected" ]]; then
            log_info "Using cached cloud image from $img (checksum verified)"
            return 0
        fi
        log_info "Cached cloud image does not match the current release; downloading a fresh one"
    fi
    rm -f "$img"

    log_info "Downloading Ubuntu 24.04 cloud image..."
    [[ -t 2 ]] && progress=(--show-progress)
    # Download beside the cache so an interrupted transfer never looks cached.
    tmp=$(mktemp "$img.XXXXXX") || return 1
    if ! wget -q "${progress[@]}" -O "$tmp" "$base_url/$CLOUD_IMG" || [[ ! -s "$tmp" ]]; then
        log_error "Failed to download cloud image"
        rm -f "$tmp"
        return 1
    fi

    # A mismatch fails before any template VM is created.
    if [[ -n "$expected" ]]; then
        actual=$(sha256sum "$tmp" | awk '{print $1}') || true
        if [[ "$actual" != "$expected" ]]; then
            log_error "Checksum verification failed!"
            log_error "Expected: $expected"
            log_error "Got:      $actual"
            rm -f "$tmp"
            return 1
        fi
        log_info "Checksum verified"
    else
        log_warn "Could not fetch checksum from Ubuntu — skipping verification"
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$img"
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
    local new_import_re="unused0: successfully imported disk '([^'[:space:]]+)'"
    local old_import_re="unused0:([^'\"[:space:]]+)"
    local bake_elapsed=0 bake_interval=15 bake_ready=false
    local bake_timeout="${BAKE_TIMEOUT:-5400}"
    local minutes seconds_rem i

    import_output=$(qm_host importdisk "$vmid" "$IMG_CACHE_DIR/$CLOUD_IMG" "$VM_STORAGE" 2>&1) || {
        log_error "Failed to import disk"
        printf '%s\n' "$import_output" >&2
        return 1
    }

    # qemu-server before 8.2.7 prints "Successfully imported disk as
    # 'unused0:<volid>'"; 8.2.7 and later print "unused0: successfully
    # imported disk '<volid>'". Never guess the volid: dir storage names it
    # <storage>:<vmid>/vm-<vmid>-disk-0.<fmt>, and a leftover vm-<vmid>-disk-0
    # pushes the import to disk-1. Otherwise read the unused0 entry that
    # importdisk added to this new VM's config.
    if [[ "$import_output" =~ $new_import_re || "$import_output" =~ $old_import_re ]]; then
        imported_disk="${BASH_REMATCH[1]}"
    else
        log_warn "importdisk output did not name the imported disk; reading unused0 from VM $vmid's config"
        imported_disk=$(qm_host config "$vmid" 2>/dev/null \
            | awk -F': ' '$1 == "unused0" && !found { print $2; found = 1 }') || imported_disk=""
    fi
    if [[ "$imported_disk" != "$VM_STORAGE:"?* ]]; then
        log_error "Could not find the imported disk on $VM_STORAGE in the importdisk output or VM $vmid's config:"
        printf '%s\n' "$import_output" >&2
        return 1
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

# 0 only when VM $1 is a finished template: `template: 1` is set and every
# disk except cdrom media (the cloud-init drive) is a base volume of that VM.
# Proxmox writes `template: 1` before it converts the disks, and `qm template`
# exits 0 even when its conversion worker fails, so neither the flag nor the
# exit status alone proves a clone can be made from it.
template_is_converted() {
    local vmid="$1" cfg
    [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
    cfg=$(qm_host config "$vmid" 2>/dev/null) || return 1
    printf '%s\n' "$cfg" | awk -v id="$vmid" '
        /^template: 1[[:space:]]*$/ { template = 1 }
        /^(ide|sata|scsi|virtio)[0-9]+: / {
            if ($0 ~ /media=cdrom/) next
            disks++
            volume = $2
            sub(/,.*/, "", volume)
            if (volume !~ ("(^|[:/])base-" id "-disk-[0-9]+")) unconverted = 1
        }
        END { exit !(template && disks > 0 && !unconverted) }
    '
}
