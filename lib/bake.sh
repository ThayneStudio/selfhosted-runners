#!/bin/bash
# Template digest, failed-digest memo, and fail-closed cloud-image verify.
#
# Library only: functions, no main, no require_root, no load_infra_config at
# source time. runner bake (Task 5) sources this and calls bake_main.
#
# Wrapping a function in `if ! bake_download_image` suppresses set -e for the
# body (#15 comment 1). Every wget/SUMS/hash failure must `return 1` explicitly.
set -euo pipefail

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
