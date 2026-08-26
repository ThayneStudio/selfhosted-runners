#!/bin/bash
# Template digest, failed-digest memo, fail-closed cloud-image verify, and
# non-interactive bake orchestration (`bake_main`).
#
# Library: functions only at source time. Tests load_lib bake.sh and call
# bake_main. When executed as the CLI (`BASH_SOURCE == $0`), require_root,
# load_infra_config, then bake_main. Do not require_root at source time.
#
# Wrapping a function in `if ! bake_download_image` suppresses set -e for the
# body (#15 comment 1). Every wget/SUMS/hash failure must `return 1` explicitly.
#
# GEN_* fields are loaded via gen_read in this shell; gen_create/gen_update/
# gen_transition are subshells, so SC2030/SC2031 are false positives here as in
# generations.sh.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_BAKE_LOADED:-}" ]]; then
    return 0
fi
RUNNER_BAKE_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=generations.sh
source "$LIB_DIR/generations.sh"

render_template_setup() {
    local template="$INSTALL_DIR/templates/template-setup.yaml"
    if [[ ! -f "$template" ]]; then
        log_error "template-setup.yaml not found at $template"
        return 1
    fi
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
    }' "$template" || return 1
}

fetch_latest_runner_version() {
    local json tag
    json=$(curl -sf --retry 3 --max-time 20 https://api.github.com/repos/actions/runner/releases/latest) || return 1
    tag=$(printf '%s' "$json" | jq -r '.tag_name // empty') || return 1
    tag="${tag#v}"
    [[ -n "$tag" && "$tag" != "null" ]] || return 1
    printf '%s\n' "$tag"
}

fetch_image_checksum_entry() {
    local sums line
    if ! sums=$(wget -q -O- --tries=3 --timeout=30 "$CLOUD_IMG_CHECKSUM_URL"); then
        log_error "Could not fetch $CLOUD_IMG_CHECKSUM_URL — cannot verify the cloud image"
        return 1
    fi
    line=$(printf '%s\n' "$sums" | awk -v img="$CLOUD_IMG" '$2 == img || $2 == "*" img { print; exit }')
    if [[ -z "$line" ]]; then
        log_error "No entry for $CLOUD_IMG in $CLOUD_IMG_CHECKSUM_URL — cannot verify the cloud image"
        return 1
    fi
    printf '%s\n' "$line"
}

compute_template_digest() {
    local yaml version sums_entry digest
    yaml=$(render_template_setup) || return 1
    version=$(fetch_latest_runner_version) || return 1
    sums_entry=$(fetch_image_checksum_entry) || return 1
    [[ -n "$yaml" && -n "$version" && -n "$sums_entry" ]] || return 1
    digest=$(
        {
            printf '%s\n' "$yaml"
            printf '%s\n' "$version"
            printf '%s\n' "$sums_entry"
            printf 'DOCKER_MIRROR_URL=%s\n' "${DOCKER_MIRROR_URL:-}"
            printf 'VM_STORAGE=%s\n' "${VM_STORAGE:-}"
            printf 'NETWORK_BRIDGE=%s\n' "${NETWORK_BRIDGE:-}"
            printf 'VLAN_TAG=%s\n' "${VLAN_TAG:-}"
            printf 'DNS_SERVERS=%s\n' "${DNS_SERVERS:-}"
            printf 'BALLOON=%s\n' "${BALLOON:-}"
        } | sha256sum | awk '{print $1}'
    ) || return 1
    [[ -n "$digest" && "$digest" != "unknown" ]] || return 1
    printf '%s\n' "$digest"
}

digest_is_memoed() {
    local digest="${1:-}"
    [[ -n "$digest" && -f "$FAILED_DIGESTS_FILE" ]] || return 1
    grep -qxF "$digest" "$FAILED_DIGESTS_FILE"
}

memo_failed_digest() {
    local digest="${1:-}"
    [[ -n "$digest" ]] || return 1
    ensure_state_dir "$(dirname "$FAILED_DIGESTS_FILE")" || return 1
    if [[ -f "$FAILED_DIGESTS_FILE" ]] && grep -qxF "$digest" "$FAILED_DIGESTS_FILE"; then
        chmod 600 "$FAILED_DIGESTS_FILE" || return 1
        return 0
    fi
    printf '%s\n' "$digest" >> "$FAILED_DIGESTS_FILE" || return 1
    chmod 600 "$FAILED_DIGESTS_FILE" || return 1
}

bake_download_image() {
    mkdir -p "$IMG_CACHE_DIR" || return 1
    chmod 700 "$IMG_CACHE_DIR" || return 1

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
        size=$(wc -c < "$CLOUD_IMG_PATH") || return 1
        size=${size//[[:space:]]/}
        if (( size < MIN_CLOUD_IMG_BYTES )); then
            log_error "Cloud image is ${size:-0} bytes, far below the ~600 MB upstream publishes"
            log_error "The download did not return a whole image — look for a proxy, captive portal, 404 page or truncated transfer"
            head_bytes=$(head -c 200 "$CLOUD_IMG_PATH" | tr -cd '[:print:]' | tr -s ' ')
            [[ -n "$head_bytes" ]] && log_error "Response began: $head_bytes"
            return 1
        fi
        magic=$(od -An -N4 -tx1 "$CLOUD_IMG_PATH" | tr -cd '[:xdigit:]') || return 1
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
    local FIRST_ATTEMPT_NOTE="" attempt sums_entry EXPECTED_SHA256 ACTUAL_SHA256
    for attempt in 1 2; do
        if [[ -f "$CLOUD_IMG_PATH" ]]; then
            log_info "Using cached cloud image from $CLOUD_IMG_PATH"
        elif ! download_cloud_img "$attempt"; then
            rm -f "$CLOUD_IMG_PATH"
            (( attempt == 1 )) || log_error "The re-download failed; attempt 1 had produced $FIRST_ATTEMPT_NOTE"
            return 1
        fi

        if ! check_cloud_img_plausible; then
            rm -f "$CLOUD_IMG_PATH"
            if (( attempt == 1 )); then
                FIRST_ATTEMPT_NOTE="a file that was not a usable image"
                log_warn "Discarding it and downloading again (attempt 2 of 2)..."
                continue
            fi
            log_error "The re-downloaded file was not a usable image either — aborting"
            return 1
        fi

        # Verify SHA256 checksum. There is no proceed-without-it path: an
        # unverified image would be baked into the template every runner clones.
        # fetch_image_checksum_entry checks wget status before using the body,
        # so a failed SUMS fetch still returns 1 inside `if ! bake_download_image`.
        log_info "Verifying cloud image checksum..."
        if ! sums_entry=$(fetch_image_checksum_entry); then
            return 1
        fi
        EXPECTED_SHA256=$(printf '%s\n' "$sums_entry" | awk '{ print $1; exit }')
        if [[ -z "$EXPECTED_SHA256" ]]; then
            log_error "No entry for $CLOUD_IMG in $CLOUD_IMG_CHECKSUM_URL — cannot verify the cloud image"
            return 1
        fi

        if ! ACTUAL_SHA256=$(sha256sum "$CLOUD_IMG_PATH" | awk '{print $1}'); then
            log_error "Failed to hash cloud image"
            return 1
        fi
        if [[ -z "$ACTUAL_SHA256" ]]; then
            log_error "Failed to hash cloud image"
            return 1
        fi
        if [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]]; then
            log_info "Checksum verified"
            if [[ -n "$FIRST_ATTEMPT_NOTE" ]]; then
                log_warn "This bake needed a second download: attempt 1 produced $FIRST_ATTEMPT_NOTE"
                log_warn "Attempt 2 matched upstream SHA256SUMS: $EXPECTED_SHA256"
            fi
            return 0
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
        return 1
    done

    return 1
}

# ---------------------------------------------------------------------------
# Bake orchestration (spec 6.2)
# ---------------------------------------------------------------------------

# pvesm status Avail is treated as bytes (plan Task 5; stub-friendly). Convert
# to GiB with integer division: bytes / 1024 / 1024 / 1024. Fail closed.
storage_avail_gb() {
    local row avail
    [[ -n "${VM_STORAGE:-}" ]] || return 1
    row=$(pvesm status | awk -v name="$VM_STORAGE" '$1 == name { print; exit }') || return 1
    [[ -n "$row" ]] || return 1
    avail=$(awk '{ print $6 }' <<< "$row")
    [[ "$avail" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' $((avail / 1024 / 1024 / 1024))
}

# Lowest free band VMID without taking the allocator lock. Dry-run only.
bake_planned_vmid() {
    local vmid
    validate_generation_band || return 1
    for vmid in $(seq "$TEMPLATE_BAND_MIN" "$TEMPLATE_BAND_MAX"); do
        if ! vmid_in_use "$vmid" && ! gen_exists "$vmid"; then
            printf '%s\n' "$vmid"
            return 0
        fi
    done
    return 1
}

# First candidate or active generation whose digest matches $1. VMID on stdout.
bake_matching_generation() {
    local digest="${1:-}" vmid
    [[ -n "$digest" ]] || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || return 1
        [[ "$GEN_STATE" == "active" || "$GEN_STATE" == "candidate" ]] || continue
        [[ "$GEN_TEMPLATE_DIGEST" == "$digest" ]] || continue
        printf '%s\n' "$vmid"
        return 0
    done < <(gen_list)
    return 1
}

# Candidate with this digest. Active matches must not skip — weekly floor
# rebakes the same digest. Proven by "matching digest past weekly floor
# without --force still bakes".
bake_matching_candidate() {
    local digest="${1:-}" vmid
    [[ -n "$digest" ]] || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || return 1
        [[ "$GEN_TEMPLATE_DIGEST" == "$digest" ]] || continue
        printf '%s\n' "$vmid"
        return 0
    done < <(gen_list candidate)
    return 1
}

# Copy a line to GEN_BAKE_LOG as well as stderr. No-op until the log path is set.
_bake_tee() {
    local line="$1"
    if [[ -n "${GEN_BAKE_LOG:-}" ]]; then
        mkdir -p "$(dirname "$GEN_BAKE_LOG")" 2>/dev/null || true
        printf '%s\n' "$line" | tee -a "$GEN_BAKE_LOG" >&2
    else
        printf '%s\n' "$line" >&2
    fi
}

# Best-effort leftover volumes at a generation VMID. Missing storage is not a
# failure — leftover cleanup only.
bake_free_vmid_volumes() {
    local vmid="$1" volid rest
    local list=""
    [[ -n "$vmid" && -n "${VM_STORAGE:-}" ]] || return 0
    list=$(pvesm list "$VM_STORAGE" 2>/dev/null) || return 0
    while read -r volid rest; do
        [[ -n "$volid" && "$volid" != "Volid" ]] || continue
        case "$volid" in
            *"vm-${vmid}-disk-"*|*"vm-${vmid}-cloudinit"*)
                pvesm free "$volid" 2>/dev/null || true
                ;;
        esac
    done <<< "$list"
    return 0
}

# Failure path for the NEW band VMID only. Never qm destroy TEMPLATE_ID.
# Proven by "failed bake does not qm destroy the active TEMPLATE_ID".
bake_fail() {
    local reason="${1:-bake failed}"
    local vmid="${_BAKE_VMID:-}"

    [[ "${_BAKE_FAILING:-0}" -eq 1 ]] && return 1
    _BAKE_FAILING=1
    trap - EXIT INT TERM

    log_error "$reason"
    _bake_tee "bake failed: $reason"

    if [[ -n "$vmid" && "$vmid" != "${TEMPLATE_ID:-}" ]]; then
        if qm status "$vmid" >/dev/null 2>&1; then
            # Proxmox refuses destroy of a running VM. Match setup cleanup_bake:
            # stop then destroy. Proven by "failed bake after start stops then
            # destroys the new VMID, never TEMPLATE_ID".
            qm stop "$vmid" --timeout 30 2>/dev/null || true
            if ! qm destroy "$vmid" --purge; then
                log_error "Failed to destroy bake VM $vmid"
            fi
        fi
        bake_free_vmid_volumes "$vmid"
        if gen_exists "$vmid"; then
            gen_transition "$vmid" failed "$reason" || true
        fi
    elif [[ -n "$vmid" && "$vmid" == "${TEMPLATE_ID:-}" ]]; then
        log_error "Refusing to destroy TEMPLATE_ID $TEMPLATE_ID on bake failure"
        if gen_exists "$vmid"; then
            gen_transition "$vmid" failed "$reason" || true
        fi
    fi

    if [[ -n "${_BAKE_DIGEST:-}" ]]; then
        memo_failed_digest "$_BAKE_DIGEST" || true
    fi
    notify error bake.failed "$reason"
    return 1
}

# Create and configure a bake VM. Name and snippet basename are parameterized
# so bake_main can use github-runner-gen-N with a per-VMID snippet.
# Usage: bake_create_template_vm <vmid> <name> <snippet-basename>
bake_create_template_vm() {
    local vmid="$1" name="$2" snippet_base="$3"
    local net imported snippet

    [[ -n "$vmid" && -n "$name" && -n "$snippet_base" ]] || return 1
    BALLOON="${BALLOON:-0}"
    net="virtio,bridge=$NETWORK_BRIDGE"
    if [[ -n "${VLAN_TAG:-}" ]]; then
        net="${net},tag=$VLAN_TAG"
    fi

    log_info "Creating VM $vmid ($name)..."
    if ! qm create "$vmid" --name "$name" \
        --memory 8192 --balloon "$BALLOON" --cores 2 --cpu host --net0 "$net"; then
        log_error "Failed to create VM $vmid"
        return 1
    fi

    local import_output
    import_output=$(qm importdisk "$vmid" "$CLOUD_IMG_PATH" "$VM_STORAGE" 2>&1) || {
        log_error "Failed to import disk"
        printf '%s\n' "$import_output" >&2
        return 1
    }
    if [[ "$import_output" =~ unused0:([^\'\"[:space:]]+) ]]; then
        imported="${BASH_REMATCH[1]}"
    else
        imported="${VM_STORAGE}:vm-${vmid}-disk-0"
        log_warn "Could not parse imported disk name from importdisk output:"
        log_warn "$import_output"
        log_warn "Assuming: $imported"
    fi

    qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$imported" \
        || { log_error "Failed to configure SCSI"; return 1; }
    qm set "$vmid" --ide2 "${VM_STORAGE}:cloudinit" \
        || { log_error "Failed to add cloud-init drive"; return 1; }
    qm set "$vmid" --boot c --bootdisk scsi0 \
        || { log_error "Failed to set boot disk"; return 1; }
    qm set "$vmid" --serial0 socket --vga serial0 \
        || { log_error "Failed to set serial"; return 1; }
    qm set "$vmid" --agent enabled=1 \
        || { log_error "Failed to enable agent"; return 1; }
    qm resize "$vmid" scsi0 30G \
        || { log_error "Failed to resize disk"; return 1; }

    mkdir -p "$SNIPPETS_DIR" || return 1
    snippet="$SNIPPETS_DIR/$snippet_base"
    log_info "Configuring template cloud-init ($snippet_base)..."
    if ! render_template_setup > "$snippet"; then
        log_error "Failed to render $snippet"
        return 1
    fi
    chmod 600 "$snippet"

    qm set "$vmid" --cicustom "user=local:snippets/${snippet_base}" \
        || { log_error "Failed to set cloud-init config"; return 1; }
    qm set "$vmid" --ipconfig0 ip=dhcp \
        || { log_error "Failed to set IP config"; return 1; }
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        qm set "$vmid" --nameserver "$DNS_SERVERS" \
            || { log_error "Failed to set DNS servers"; return 1; }
    fi
    qm set "$vmid" --ciuser runner \
        || { log_error "Failed to set cloud-init user"; return 1; }
    return 0
}

# Poll /opt/.template-setup-complete. Stopped VM is failure; timeout dumps the
# last 40 lines of /var/log/template-setup.log; refuse convert without marker.
# Publish gate moved from setup.sh — proven by "publish gate refuses qm template
# when the completion marker is absent".
bake_poll_setup_complete() {
    local vmid="$1"
    local elapsed=0 interval timeout ready=false
    local vm_status exec_result exec_exit minutes seconds_rem

    interval="${BAKE_INTERVAL:-15}"
    timeout="${BAKE_TIMEOUT:-5400}"

    log_info "Waiting for tool installation to complete..."
    log_info "  (Monitor progress: qm guest exec $vmid -- cat /var/log/template-setup.log)"

    while true; do
        sleep "$interval"
        elapsed=$((elapsed + interval))

        if [[ "$elapsed" -ge "$timeout" ]]; then
            echo "" >&2
            log_error "Bake timed out after $((timeout / 60)) minutes (override with BAKE_TIMEOUT=<seconds>)"
            log_error "Last 40 lines from the guest:"
            exec_result=$(qm guest exec "$vmid" -- tail -n 40 /var/log/template-setup.log 2>/dev/null) || exec_result=""
            if [[ -n "$exec_result" ]]; then
                printf '%s\n' "$exec_result" | jq -r '."out-data" // empty' 2>/dev/null \
                    | tee -a "${GEN_BAKE_LOG:-/dev/null}" >&2 || true
            fi
            return 1
        fi

        vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}') || true
        if [[ "$vm_status" != "running" ]]; then
            echo "" >&2
            log_error "Template VM stopped before setup completion was confirmed"
            log_error "Refusing to publish a possibly half-baked template."
            return 1
        fi

        exec_result=$(qm guest exec "$vmid" -- test -f /opt/.template-setup-complete 2>&1) || {
            minutes=$((elapsed / 60))
            seconds_rem=$((elapsed % 60))
            printf '\r  Elapsed: %dm%02ds (waiting for guest agent...)' "$minutes" "$seconds_rem" >&2
            continue
        }

        exec_exit=$(echo "$exec_result" | jq -r '.exitcode // "1"' 2>/dev/null) || exec_exit="1"
        if [[ "$exec_exit" == "0" ]]; then
            ready=true
            echo "" >&2
            log_info "Template setup complete!"
            break
        fi

        minutes=$((elapsed / 60))
        seconds_rem=$((elapsed % 60))
        printf '\r  Elapsed: %dm%02ds (installing tools...)' "$minutes" "$seconds_rem" >&2
    done
    echo "" >&2

    if [[ "$ready" != "true" ]]; then
        log_error "Internal error: bake loop exited without a confirmed completion marker"
        return 1
    fi
    return 0
}

# Read /opt/.runner-version and stamp /etc/github-runner/generation over the
# guest agent, then record GEN_RUNNER_VERSION. Must run before shutdown.
bake_stamp_generation() {
    local vmid="$1" gen_id="$2" raw version write_json write_exit

    raw=$(qm guest exec "$vmid" -- cat /opt/.runner-version) || {
        log_error "Failed to read /opt/.runner-version"
        return 1
    }
    version=$(printf '%s\n' "$raw" | jq -r '."out-data" // empty' 2>/dev/null) || version=""
    version="${version//$'\r'/}"
    version="${version%%$'\n'*}"
    version="${version//\\n/}"
    if [[ -z "$version" ]]; then
        log_error "Empty /opt/.runner-version from guest"
        return 1
    fi
    log_info "Baked runner version: $version"

    # Guest outcome is JSON exitcode, not qm's process status (the agent call
    # succeeds even when bash in the guest fails). Same as the poll loop.
    # Proven by "stamp write with non-zero guest exitcode fails the bake".
    write_json=$(qm guest exec "$vmid" -- /bin/bash -c \
        "mkdir -p /etc/github-runner && printf '%s\n' '$gen_id' > /etc/github-runner/generation") || {
        log_error "Failed to write /etc/github-runner/generation"
        return 1
    }
    write_exit=$(printf '%s\n' "$write_json" | jq -r '.exitcode // "1"' 2>/dev/null) || write_exit="1"
    if [[ "$write_exit" != "0" ]]; then
        log_error "Failed to write /etc/github-runner/generation (guest exitcode $write_exit)"
        return 1
    fi

    gen_update "$vmid" "GEN_RUNNER_VERSION=$version" || return 1
    return 0
}

# Host shutdown, wait until stopped, drop bake-time cloud-init, qm template.
bake_shutdown_convert() {
    local vmid="$1" vm_status="" i

    log_info "Shutting down template VM..."
    qm shutdown "$vmid" --timeout 120 || {
        log_warn "Graceful shutdown failed, forcing..."
        qm stop "$vmid" --skiplock 2>/dev/null || true
    }
    # shellcheck disable=SC2034  # loop counter is unused; this is a bounded poll
    for i in {1..60}; do
        vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}') || true
        [[ "$vm_status" == "stopped" ]] && break
        sleep 2
    done
    if [[ "$vm_status" != "stopped" ]]; then
        log_error "Template VM did not reach stopped state; refusing to convert to template"
        return 1
    fi

    log_info "Preparing template for cloning..."
    qm set "$vmid" --delete cicustom 2>/dev/null || true
    qm set "$vmid" --delete ciuser 2>/dev/null || true
    qm set "$vmid" --delete ipconfig0 2>/dev/null || true
    qm set "$vmid" --delete nameserver 2>/dev/null || true

    qm template "$vmid" || { log_error "Failed to convert to template"; return 1; }
    return 0
}

# Ruling 6: after a successful bake, fail any other candidate and destroy it.
# Never qm destroy TEMPLATE_ID.
bake_fail_other_candidates() {
    local keep="$1" other
    while read -r other; do
        [[ -n "$other" && "$other" != "$keep" ]] || continue
        log_info "Failing previous candidate VMID $other (superseded by newer candidate)"
        if [[ "$other" == "${TEMPLATE_ID:-}" ]]; then
            log_error "Refusing to destroy TEMPLATE_ID $TEMPLATE_ID (other candidate)"
            gen_transition "$other" failed "superseded by newer candidate" || true
            continue
        fi
        if qm status "$other" >/dev/null 2>&1; then
            qm destroy "$other" --purge 2>/dev/null || true
        fi
        bake_free_vmid_volumes "$other"
        gen_transition "$other" failed "superseded by newer candidate" || true
    done < <(gen_list candidate)
    return 0
}

bake_dry_run() {
    local force="$1" digest planned reason="digest-changed" match="" decision

    digest=$(compute_template_digest) || return 1
    planned=$(bake_planned_vmid) || planned="none"
    if [[ "$force" -eq 1 ]]; then
        reason=force
    else
        decision=$(detect_should_bake) || return 1
        case "$decision" in
            yes\ *|no\ *) reason="${decision#* }" ;;
            *) reason="$decision" ;;
        esac
        match=$(bake_matching_generation "$digest") || match=""
    fi
    printf 'planned_vmid=%s\n' "$planned"
    printf 'digest=%s\n' "$digest"
    printf 'reason=%s\n' "$reason"
    [[ -z "$match" ]] || printf 'matching_vmid=%s\n' "$match"
    return 0
}

# Held under exclusive flock on BAKE_LOCK_FILE fd 207.
bake_locked() {
    local force="$1"
    local avail digest image_sha sums_entry vmid gen_id snippet_base
    local match=""

    avail=$(storage_avail_gb) || {
        log_error "Could not parse free space for $VM_STORAGE"
        notify error bake.failed "Could not parse free space for $VM_STORAGE"
        return 1
    }
    if (( avail < BAKE_MIN_FREE_GB )); then
        log_error "Insufficient free space on $VM_STORAGE: ${avail}G available, ${BAKE_MIN_FREE_GB}G required"
        notify error bake.failed "Insufficient free space on $VM_STORAGE: ${avail}G < ${BAKE_MIN_FREE_GB}G"
        return 1
    fi

    digest=$(compute_template_digest) || {
        log_error "Failed to compute template digest"
        notify error bake.failed "Failed to compute template digest"
        return 1
    }
    _BAKE_DIGEST="$digest"

    sums_entry=$(fetch_image_checksum_entry) || {
        log_error "Failed to fetch image checksum"
        notify error bake.failed "Failed to fetch image checksum"
        return 1
    }
    image_sha=$(printf '%s\n' "$sums_entry" | awk '{ print $1; exit }')
    [[ -n "$image_sha" ]] || {
        log_error "Failed to parse image checksum"
        notify error bake.failed "Failed to parse image checksum"
        return 1
    }

    if [[ "$force" -eq 0 ]]; then
        if digest_is_memoed "$digest"; then
            log_info "nothing to do: digest is memoed as failed (use --force to retry)"
            return 0
        fi
        # Do not skip on an active digest match: weekly floor rebakes the
        # same digest. A candidate with this digest is already the bake.
        if match=$(bake_matching_candidate "$digest"); then
            log_info "nothing to do: digest matches candidate VMID $match"
            return 0
        fi
    fi

    adopt_deployed_template || {
        log_error "Adoption failed"
        notify error bake.failed "Adoption failed"
        return 1
    }

    # Command substitution runs allocate_generation_vmid in a subshell, so
    # fd 206 is released here. gen_create exclusive create is the occupancy;
    # bake lock 207 serializes bakes.
    vmid=$(allocate_generation_vmid) || {
        log_error "generation VMID allocation failed"
        notify error bake.failed "generation VMID allocation failed"
        return 1
    }
    if [[ "$vmid" == "${TEMPLATE_ID:-}" ]]; then
        log_error "allocator returned TEMPLATE_ID $TEMPLATE_ID — refusing to bake over the active template"
        notify error bake.failed "allocator returned TEMPLATE_ID"
        return 1
    fi

    mkdir -p "$BAKE_LOG_DIR" || {
        log_error "Failed to create bake log directory"
        notify error bake.failed "Failed to create bake log directory"
        return 1
    }

    gen_id=$(gen_next_id) || {
        log_error "Failed to allocate generation id"
        notify error bake.failed "Failed to allocate generation id"
        return 1
    }
    GEN_BAKE_LOG="$BAKE_LOG_DIR/bake-${gen_id}.log"
    : >> "$GEN_BAKE_LOG" || true
    chmod 600 "$GEN_BAKE_LOG" 2>/dev/null || true

    gen_create "$vmid" \
        "GEN_ID=$gen_id" \
        "GEN_TEMPLATE_DIGEST=$digest" \
        "GEN_IMAGE_SHA256=$image_sha" \
        "GEN_BAKE_LOG=$GEN_BAKE_LOG" || {
        log_error "Failed to create generation record for VMID $vmid"
        notify error bake.failed "Failed to create generation record"
        return 1
    }

    _BAKE_VMID="$vmid"
    _BAKE_FAILING=0
    trap 'bake_fail "interrupted"' EXIT
    trap 'bake_fail "interrupted"; exit 1' INT TERM

    _bake_tee "bake started gen=$gen_id vmid=$vmid digest=$digest"
    NOTIFY_GENERATION="$gen_id" notify info bake.started \
        "Bake started for generation $gen_id (VMID $vmid)"

    if ! bake_download_image; then
        bake_fail "cloud image download/verify failed"
        return 1
    fi

    snippet_base="template-setup-${vmid}.yaml"
    if ! bake_create_template_vm "$vmid" "github-runner-gen-${gen_id}" "$snippet_base"; then
        bake_fail "VM create/configure failed"
        return 1
    fi

    log_info "Starting VM to install tools (this can take a while on cold caches)..."
    if ! qm start "$vmid"; then
        bake_fail "Failed to start template VM"
        return 1
    fi

    if ! bake_poll_setup_complete "$vmid"; then
        bake_fail "setup did not complete (marker absent or VM stopped)"
        return 1
    fi

    if ! bake_stamp_generation "$vmid" "$gen_id"; then
        bake_fail "failed to stamp runner version/generation"
        return 1
    fi

    if ! bake_shutdown_convert "$vmid"; then
        bake_fail "shutdown/convert to template failed"
        return 1
    fi

    if ! gen_transition "$vmid" candidate; then
        bake_fail "failed to transition VMID $vmid to candidate"
        return 1
    fi

    # New VMID is candidate. An EXIT bake_fail during ruling-6 cleanup must
    # not destroy it. INT/TERM stay until process exit.
    trap - EXIT

    bake_fail_other_candidates "$vmid"

    trap - INT TERM
    log_info "Bake finished: generation $gen_id is candidate (VMID $vmid)"
    _bake_tee "bake finished gen=$gen_id vmid=$vmid state=candidate"
    return 0
}

bake_main() {
    local force=0 dry_run=0 rc=0 decision

    apply_generation_defaults
    BALLOON="${BALLOON:-0}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help)
                echo "Usage: runner bake [--force] [--dry-run]"
                return 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: runner bake [--force] [--dry-run]" >&2
                return 1
                ;;
        esac
    done

    if [[ "$dry_run" -eq 1 ]]; then
        bake_dry_run "$force"
        return $?
    fi

    # --force ignores digest equality, weekly floor, memo, and REBAKE_ENABLED.
    # Default path is detect_should_bake; a `no` decision is exit 0.
    if [[ "$force" -eq 0 ]]; then
        decision=$(detect_should_bake) || {
            log_error "detect_should_bake failed"
            return 1
        }
        case "$decision" in
            yes\ *)
                log_info "bake needed: ${decision#yes }"
                ;;
            no\ *)
                log_info "nothing to do: ${decision#no }"
                return 0
                ;;
            *)
                log_error "detect_should_bake produced an unreadable decision: ${decision:-<empty>}"
                return 1
                ;;
        esac
    fi

    mkdir -p "$(dirname "$BAKE_LOCK_FILE")" || {
        log_error "Cannot create bake lock directory"
        return 1
    }
    # fd 207: 206 is the generation VMID allocator. Non-blocking exclusive.
    # Busy → log and exit 0. Proven by "second concurrent bake exits 0 without
    # qm create".
    exec 207>"$BAKE_LOCK_FILE" || {
        log_error "Cannot open bake lock $BAKE_LOCK_FILE"
        return 1
    }
    if ! flock -n 207; then
        log_info "bake already running"
        exec 207>&- || true
        return 0
    fi

    bake_locked "$force" || rc=$?
    exec 207>&- || true
    return "$rc"
}

# detect.sh may source bake.sh when loaded first. The next directive
# stops the linter following this reverse edge (cycle). Runtime is
# guarded by RUNNER_DETECT_LOADED.
# shellcheck source=/dev/null
source "$LIB_DIR/detect.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root bake
    load_infra_config
    bake_main "$@"
fi
