#!/usr/bin/env bats
#
# Covers the cloud-image download/verify block in lib/setup.sh.
#
# The block is still inline in the setup wizard, so it is extracted between two
# anchors and run standalone against stubbed wget/sha256sum. When the bake moves
# into a library these tests should call that function directly instead.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# Pulls the download/verify block out of lib/setup.sh. Fails loudly rather than
# silently testing nothing if the anchors ever move.
extract_download_block() {
    local block
    block=$(awk '
        /^    CLOUD_IMG_PATH=/ { in_block = 1 }
        /^    log_info "Creating VM template/ { in_block = 0 }
        in_block
    ' "$REPO_ROOT/lib/setup.sh")

    if [[ "$block" != *"for attempt in 1 2"* ]]; then
        echo "could not extract the download/verify block from lib/setup.sh" >&2
        return 1
    fi
    printf '%s\n' "$block"
}

# 105 MiB sparse qcow2-looking file; the tag makes each fixture hash differently.
make_image() {
    local path="$1" tag="$2"
    dd if=/dev/zero of="$path" bs=1 count=0 seek=$((105 * 1024 * 1024)) 2>/dev/null
    printf 'QFI\xfb\x00\x00\x00\x03%s' "$tag" | dd of="$path" bs=1 seek=0 conv=notrunc 2>/dev/null
}

make_html_error_page() {
    printf '<!DOCTYPE html>\n<html><head><title>403 Forbidden</title></head>\n<body>Blocked by proxy</body></html>\n' > "$1"
}

# One line per wget image fetch, in order. "FAIL" makes that fetch fail.
set_payloads() {
    printf '%s\n' "$@" > "$STUB_DIR/payloads"
}

expect_sums_for() {
    sha256sum "$1" | awk -v img="$CLOUD_IMG" '{print $1 "  *" img}' > "$STUB_DIR/sha256sums"
}

run_download_block() {
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        echo 'log_info()  { printf "[INFO] %s\n"  "$1" >&2; }'
        echo 'log_warn()  { printf "[WARN] %s\n"  "$1" >&2; }'
        echo 'log_error() { printf "[ERROR] %s\n" "$1" >&2; }'
        echo "CLOUD_IMG=\"$CLOUD_IMG\""
        echo 'CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/$CLOUD_IMG"'
        echo "IMG_CACHE_DIR=\"$CACHE_DIR\""
        extract_download_block
    } > "$BATS_TEST_TMPDIR/block.sh"

    run bash "$BATS_TEST_TMPDIR/block.sh"
}

setup() {
    CLOUD_IMG="noble-server-cloudimg-amd64.img"
    CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/$CLOUD_IMG"
    CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$CACHE_DIR" "$STUB_DIR/bin"

    cat > "$STUB_DIR/bin/wget" <<'STUB'
#!/bin/bash
# Serves SHA256SUMS from a file; serves the image from the next line of
# $STUB_DIR/payloads, so consecutive downloads can differ.
printf '%s\n' "$*" >> "$STUB_DIR/argv"
out=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -O) out="$2"; shift 2 ;;
        -*) shift ;;
        *)  url="$1"; shift ;;
    esac
done

if [[ "$url" == *SHA256SUMS ]]; then
    cat "$STUB_DIR/sha256sums"
    exit 0
fi

n=1
[[ -f "$STUB_DIR/calls" ]] && n=$(<"$STUB_DIR/calls")
echo $((n + 1)) > "$STUB_DIR/calls"

payload=$(sed -n "${n}p" "$STUB_DIR/payloads")
[[ -n "$payload" ]] || payload=$(tail -1 "$STUB_DIR/payloads")
[[ "$payload" == "FAIL" ]] && exit 8

cp "$payload" "$out"
STUB
    chmod +x "$STUB_DIR/bin/wget"

    # macOS ships shasum, not sha256sum; the block calls sha256sum.
    if ! command -v sha256sum > /dev/null 2>&1; then
        cat > "$STUB_DIR/bin/sha256sum" <<'STUB'
#!/bin/bash
exec shasum -a 256 "$@"
STUB
        chmod +x "$STUB_DIR/bin/sha256sum"
    fi

    export STUB_DIR
    export PATH="$STUB_DIR/bin:$PATH"
}

@test "cached image matching upstream verifies without re-downloading" {
    make_image "$CACHE_DIR/$CLOUD_IMG" good
    expect_sums_for "$CACHE_DIR/$CLOUD_IMG"
    set_payloads FAIL

    run_download_block

    [ "$status" -eq 0 ]
    [[ "$output" == *"Checksum verified"* ]]
    [[ "$output" != *"Re-downloading"* ]]
    [ -f "$CACHE_DIR/$CLOUD_IMG" ]
}

@test "stale cached image is re-downloaded once and the bake continues" {
    make_image "$CACHE_DIR/$CLOUD_IMG" stale
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$BATS_TEST_TMPDIR/current.img"

    run_download_block

    [ "$status" -eq 0 ]
    [[ "$output" == *"most likely stale"* ]]
    [[ "$output" == *"attempt 2 of 2"* ]]
    [[ "$output" == *"Checksum verified"* ]]
    [[ "$output" == *"recovered after re-downloading"* ]]
    # The one re-download bypasses HTTP caches; a proxy pinned to an older
    # noble build is what made the mismatch repeat on pve-test.
    [ "$(grep -cF "$CLOUD_IMG_URL" "$STUB_DIR/argv")" -eq 1 ]
    [ "$(grep -c -- '--no-cache' "$STUB_DIR/argv")" -eq 1 ]
    # The recovered run left the fresh image in place for the import step.
    run sha256sum "$CACHE_DIR/$CLOUD_IMG"
    [[ "$output" == "$(sha256sum "$BATS_TEST_TMPDIR/current.img" | awk '{print $1}')"* ]]
}

@test "two consecutive mismatches fail hard with both hashes" {
    make_image "$CACHE_DIR/$CLOUD_IMG" stale
    make_image "$BATS_TEST_TMPDIR/wrong.img" wrong
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$BATS_TEST_TMPDIR/wrong.img"

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"freshly downloaded image"* ]]
    [[ "$output" == *"Expected: $(sha256sum "$BATS_TEST_TMPDIR/current.img" | awk '{print $1}')"* ]]
    [[ "$output" == *"Got:      $(sha256sum "$BATS_TEST_TMPDIR/wrong.img" | awk '{print $1}')"* ]]
    [ ! -f "$CACHE_DIR/$CLOUD_IMG" ]
}

@test "an HTML error page is reported as a bad download, not as corruption" {
    make_html_error_page "$BATS_TEST_TMPDIR/error.html"
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$BATS_TEST_TMPDIR/error.html" "$BATS_TEST_TMPDIR/error.html"

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"did not return an image"* ]]
    [[ "$output" == *"403 Forbidden"* ]]
    [[ "$output" != *"Checksum verification failed"* ]]
}

@test "a bad first download recovers when the retry returns a real image" {
    make_html_error_page "$BATS_TEST_TMPDIR/error.html"
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$BATS_TEST_TMPDIR/error.html" "$BATS_TEST_TMPDIR/current.img"

    run_download_block

    [ "$status" -eq 0 ]
    [[ "$output" == *"Checksum verified"* ]]
    # First attempt goes through any HTTP cache as normal; only the retry bypasses it.
    [ "$(grep -cF "$CLOUD_IMG_URL" "$STUB_DIR/argv")" -eq 2 ]
    [[ "$(grep -F "$CLOUD_IMG_URL" "$STUB_DIR/argv" | head -1)" != *--no-cache* ]]
    [[ "$(grep -F "$CLOUD_IMG_URL" "$STUB_DIR/argv" | tail -1)" == *--no-cache* ]]
}

@test "a large non-qcow2 file is rejected before hashing" {
    dd if=/dev/zero of="$CACHE_DIR/$CLOUD_IMG" bs=1 count=0 seek=$((105 * 1024 * 1024)) 2>/dev/null
    printf 'not-an-image' | dd of="$CACHE_DIR/$CLOUD_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$CACHE_DIR/$CLOUD_IMG.copy"
    cp "$CACHE_DIR/$CLOUD_IMG" "$CACHE_DIR/$CLOUD_IMG.copy"

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"not a qcow2 image"* ]]
    [[ "$output" != *"Checksum verification failed"* ]]
}

@test "a failed download aborts without leaving a partial file" {
    set_payloads FAIL

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to download cloud image"* ]]
    [ ! -f "$CACHE_DIR/$CLOUD_IMG" ]
}
