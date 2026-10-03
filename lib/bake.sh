#!/bin/bash
# Shared template bake. Callers source common.sh first and run as root on Proxmox.
# The guest writes /opt/.template-setup-complete last and does not power itself off.
# This side confirms that marker, shuts the VM down, and only then runs `qm template`.
# A failed guest setup writes /opt/.template-setup-failed instead, or powers the
# VM off when it fails before its guest agent runs. Either fails the bake at once.
set -euo pipefail

IMG_CACHE_DIR="/var/cache/github-runners"
CLOUD_IMG="noble-server-cloudimg-amd64.img"
BAKE_DISK_GIB=30
# While the guest installs, abort if VM_STORAGE drops below this. The
# admission floor is the whole disk (twice that on thick ZFS); this only
# catches the pool filling up afterwards. BAKE_FREE_FLOOR_GIB overrides it.
BAKE_FREE_FLOOR_DEFAULT_GIB=5
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
    # A download killed mid-transfer (systemctl stop, shutdown, Ctrl-C) leaves
    # its mktemp file behind. setup and rebake share no lock, and an active
    # download keeps its mtime fresh, so remove only files idle for 3 hours.
    find "$IMG_CACHE_DIR" -maxdepth 1 -type f -name "$CLOUD_IMG.*" -mmin +180 -delete 2>/dev/null || true
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
    # The guest installs exactly this release and makes no GitHub API call.
    if [[ ! "${LATEST_RUNNER_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "No actions/runner version was resolved for the bake"
        return 1
    fi
    DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-}" RUNNER_VERSION="$LATEST_RUNNER_VERSION" awk '
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
        $0 = lreplace($0, "{{RUNNER_VERSION}}", ENVIRON["RUNNER_VERSION"])
        print
    }' "$INSTALL_DIR/templates/template-setup.yaml" > "$SNIPPETS_DIR/template-setup.yaml" || return 1
    chmod 600 "$SNIPPETS_DIR/template-setup.yaml"
}

# The host picks the runner release for the bake, so the guest makes no
# unauthenticated GitHub API call (60 an hour per address, shared with every
# job behind it). rebake_main has already read the latest release; setup has
# not, so read it once here. rebake.sh, which both callers source, defines
# fetch_latest_runner_release.
resolve_bake_runner_version() {
    if [[ -z "${LATEST_RUNNER_VERSION:-}" ]] && ! fetch_latest_runner_release; then
        log_error "Could not read the latest actions/runner release; not baking"
        return 1
    fi
    if [[ ! "${LATEST_RUNNER_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "actions/runner release '${LATEST_RUNNER_VERSION:-}' is not an X.Y.Z version; not baking"
        return 1
    fi
    log_info "The bake installs actions/runner $LATEST_RUNNER_VERSION"
}

# BAKE_TIMEOUT is whole seconds. bash reads "2h" or "90m" as a bad number, and
# the poll's -ge test then fails on every pass without ending the loop, so a
# stalled guest would hold the bake, and the rebake lock, for good.
check_bake_timeout() {
    if [[ -n "${BAKE_TIMEOUT:-}" && ! "$BAKE_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
        log_error "BAKE_TIMEOUT must be a whole number of seconds, such as 7200, not '$BAKE_TIMEOUT'"
        return 1
    fi
}

check_bake_min_free_gib() {
    if [[ -n "${BAKE_MIN_FREE_GIB:-}" && ! "$BAKE_MIN_FREE_GIB" =~ ^[0-9]+$ ]]; then
        log_error "BAKE_MIN_FREE_GIB must be a whole number of GiB, not '$BAKE_MIN_FREE_GIB'"
        return 1
    fi
}

check_bake_free_floor() {
    if [[ -n "${BAKE_FREE_FLOOR_GIB:-}" && ! "$BAKE_FREE_FLOOR_GIB" =~ ^[0-9]+$ ]]; then
        log_error "BAKE_FREE_FLOOR_GIB must be a whole number of GiB, not '$BAKE_FREE_FLOOR_GIB'"
        return 1
    fi
}

# Prints "type status avail_kib" for $VM_STORAGE from `pvesm status`.
# Returns 0 only when the storage is active and avail_kib is a whole number
# of KiB. The admission check refuses to bake otherwise; the running bake
# only warns, because a transient failure must not abort a healthy guest.
read_vm_storage_status() {
    local row storage_type="" storage_status="" avail_kib=""
    # Columns: Name Type Status Total Used Available %. Sizes are KiB.
    row=$(pvesm status --storage "$VM_STORAGE" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null \
        | awk -v s="$VM_STORAGE" '$1 == s && !found { print $2, $3, $6; found = 1 }') || row=""
    read -r storage_type storage_status avail_kib _ <<< "$row"
    printf '%s %s %s\n' "$storage_type" "$storage_status" "$avail_kib"
    [[ "$storage_status" == active && "$avail_kib" =~ ^[0-9]+$ ]]
}

# 0 when storage $1's config sets `sparse`, so ZFS creates its volumes thin.
# Without it ZFS reserves each volume's full size. A config that cannot be
# read counts as thick.
zfs_storage_is_sparse() {
    local sparse
    if ! sparse=$(pvesh get "/storage/$1" --output-format json \
        199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null | jq -r '.sparse // 0' 2>/dev/null); then
        log_warn "Could not read the config of storage $1; counting it as thick-provisioned"
        return 1
    fi
    [[ "$sparse" == 1 || "$sparse" == true ]]
}

# A bake can write its whole BAKE_DISK_GIB disk to VM_STORAGE. A storage that
# fills up pauses every VM on it (QEMU's default werror=enospc), not only the
# bake VM, so refuse to start a bake without that much free. Thick ZFS (a
# zfspool or ZFS over iSCSI storage without `sparse`) reserves the whole disk
# when the bake resizes it, and the snapshot `qm template` takes then needs
# the bake's data free outside that reservation: there a bake can take twice
# its disk. BAKE_MIN_FREE_GIB overrides the floor; 0 skips the check.
check_bake_storage_space() {
    local min_gib="${BAKE_MIN_FREE_GIB:-}" row storage_type storage_status avail_kib thick=0
    check_bake_min_free_gib || return 1
    if [[ -n "$min_gib" ]]; then
        min_gib=$((10#$min_gib))
        (( min_gib > 0 )) || return 0
    fi
    if ! row=$(read_vm_storage_status); then
        read -r storage_type storage_status avail_kib <<< "$row"
        log_error "Could not read free space on storage $VM_STORAGE (status: ${storage_status:-unknown}); not baking"
        log_error "To bake without this check: BAKE_MIN_FREE_GIB=0 runner rebake (or runner setup)"
        return 1
    fi
    read -r storage_type storage_status avail_kib <<< "$row"
    if [[ -z "$min_gib" ]]; then
        min_gib=$BAKE_DISK_GIB
        if [[ "$storage_type" == zfspool || "$storage_type" == zfs ]] && ! zfs_storage_is_sparse "$VM_STORAGE"; then
            thick=1
            min_gib=$((2 * BAKE_DISK_GIB))
        fi
    fi
    if (( avail_kib < min_gib * 1048576 )); then
        log_error "Not baking: storage $VM_STORAGE has $((avail_kib / 1048576)) GiB free and a bake needs $min_gib GiB"
        if [[ "$thick" == 1 ]]; then
            log_error "Thick-provisioned ZFS reserves the bake's whole ${BAKE_DISK_GIB} GiB disk, and qm template needs room for the bake's data besides."
        fi
        log_error "A full storage pauses every VM on it. Free space on $VM_STORAGE, or lower the floor for one run: BAKE_MIN_FREE_GIB=<GiB> runner rebake (or runner setup)"
        return 1
    fi
}

create_bake_vm() {
    local vmid="$1"
    local net_config="virtio,bridge=$NETWORK_BRIDGE"

    # Checked before the VM exists, for setup and rebake alike.
    check_bake_timeout || return 1
    check_bake_free_floor || return 1
    check_bake_storage_space || return 1
    resolve_bake_runner_version || return 1

    if [[ -n "${VLAN_TAG:-}" ]]; then
        net_config="${net_config},tag=$VLAN_TAG"
    fi
    qm_host create "$vmid" --name ubuntu-cloud-template \
        --memory 8192 --balloon "${BALLOON:-0}" --cores 2 --cpu host --net0 "$net_config"
}

log_guest_setup_tail() {
    log_error "Last 40 lines from the guest:"
    qm_host guest exec "$1" -- tail -n 40 /var/log/template-setup.log 2>/dev/null \
        | jq -r '."out-data" // empty' >&2 || true
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
    local free_floor_gib=$BAKE_FREE_FLOOR_DEFAULT_GIB free_check_every=60 since_free_check=0
    local minutes seconds_rem i storage_row avail_kib

    # Before any VM work: the poll below cannot time out on a bad value,
    # and a bad floor would otherwise abort a healthy bake on the first check.
    check_bake_timeout || return 1
    check_bake_free_floor || return 1
    if [[ -n "${BAKE_FREE_FLOOR_GIB:-}" ]]; then
        free_floor_gib=$((10#$BAKE_FREE_FLOOR_GIB))
    fi

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
    qm_host resize "$vmid" scsi0 "${BAKE_DISK_GIB}G" \
        || { log_error "Failed to resize disk"; return 1; }

    log_info "Configuring template cloud-init..."
    render_template_setup_snippet \
        || { log_error "Failed to write the template cloud-init snippet"; return 1; }

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
            log_guest_setup_tail "$vmid"
            return 1
        fi

        # Once a minute, not every poll: pvesm status walks the storage.
        # qm resize has already reserved the disk on thick ZFS, and linked
        # clones writing job data can fill what is left. Below the floor,
        # abort through the caller's cleanup so it destroys this VM and
        # releases that reservation. A reading that cannot be taken must
        # not abort a guest that is still installing.
        since_free_check=$((since_free_check + bake_interval))
        if (( free_floor_gib > 0 && since_free_check >= free_check_every )); then
            since_free_check=0
            if ! storage_row=$(read_vm_storage_status); then
                echo "" >&2
                log_warn "Could not read free space on storage $VM_STORAGE during the bake; continuing"
            else
                read -r _ _ avail_kib <<< "$storage_row"
                if (( avail_kib < free_floor_gib * 1048576 )); then
                    echo "" >&2
                    log_error "Aborting the bake: storage $VM_STORAGE has $((avail_kib / 1048576)) GiB free, under the ${free_floor_gib} GiB floor"
                    log_error "A full storage pauses every VM on it. Override with BAKE_FREE_FLOOR_GIB=<GiB>, or 0 to keep baking."
                    return 1
                fi
            fi
        fi

        # A successful guest never powers itself off. A stopped VM is a crash,
        # an external `qm stop`, or a setup that failed before its guest agent
        # ran; never success.
        vm_status=$(qm_host status "$vmid" 2>/dev/null | awk '{print $2}') || true
        if [[ "$vm_status" != "running" ]]; then
            echo "" >&2
            log_error "Template VM stopped before setup completion was confirmed (status: ${vm_status:-unknown})"
            log_error "Guest setup powers the VM off when it fails before its guest agent runs (network, DNS, apt)."
            log_error "Refusing to publish a possibly half-baked template."
            return 1
        fi

        # One call tells the states apart: exit 2 is the guest's failure
        # marker, 0 its completion marker, anything else still installing.
        # Parse stdout only. A qm warning on stderr (a Perl locale warning
        # over SSH) ahead of the JSON would hide a finished bake.
        exec_result=$(qm_host guest exec "$vmid" -- sh -c \
            'test -f /opt/.template-setup-failed && exit 2; test -f /opt/.template-setup-complete' \
            2>/dev/null) || {
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
        if [[ "$exec_exit" == "2" ]]; then
            echo "" >&2
            log_error "Template setup failed inside the guest after $((bake_elapsed / 60)) minutes"
            log_guest_setup_tail "$vmid"
            return 1
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
    # qm template exits 0 when its conversion worker fails, and Proxmox writes
    # `template: 1` before it converts the disks. Only base volumes can be
    # linked-cloned, so check the result instead of trusting the exit status.
    if ! template_is_converted "$vmid"; then
        log_error "qm template did not convert the disks of VM $vmid to base volumes; refusing to publish it"
        return 1
    fi
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
