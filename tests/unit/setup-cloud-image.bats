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

# Fixtures are sized off the implementation's own floor so raising it cannot
# leave the tests passing against images the bake would now reject.
min_cloud_img_bytes() {
    local expr
    expr=$(sed -n 's/^ *MIN_CLOUD_IMG_BYTES=\$((\(.*\)))$/\1/p' "$REPO_ROOT/lib/setup.sh" | head -1)
    if [[ -z "$expr" ]]; then
        echo "could not read MIN_CLOUD_IMG_BYTES from lib/setup.sh" >&2
        return 1
    fi
    echo $(( expr ))
}

# Sparse file just over the floor, carrying the qcow2 magic. The tag makes each
# fixture hash differently.
make_image() {
    local path="$1" tag="$2"
    dd if=/dev/zero of="$path" bs=1 count=0 seek="$IMG_BYTES" 2>/dev/null
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

hash_of() {
    sha256sum "$1" | awk '{print $1}'
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
    IMG_BYTES=$(( $(min_cloud_img_bytes) + 1024 * 1024 ))
    mkdir -p "$CACHE_DIR" "$STUB_DIR/bin"

    cat > "$STUB_DIR/bin/wget" <<'STUB'
#!/bin/bash
# Serves SHA256SUMS from a file, response headers for --spider, and the image
# from the next line of $STUB_DIR/payloads so consecutive downloads can differ.
printf '%s\n' "$*" >> "$STUB_DIR/argv"

out=""
url=""
spider=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -O) out="$2"; shift 2 ;;
        --spider) spider=1; shift ;;
        -*) shift ;;
        *)  url="$1"; shift ;;
    esac
done

if (( spider )); then
    # wget -S writes the response headers to stderr, indented.
    {
        echo "  HTTP/1.1 200 OK"
        echo "  Last-Modified: ${STUB_LAST_MODIFIED:-Fri, 14 Aug 2026 13:18:03 GMT}"
        echo "  ETag: \"25385000-65901a67bd77e\""
        echo "  Content-Length: 624447488"
    } >&2
    exit 0
fi

if [[ "$url" == *SHA256SUMS ]]; then
    [[ -f "$STUB_DIR/sums_fail" ]] && exit 4
    cat "$STUB_DIR/sha256sums"
    exit 0
fi

n=1
[[ -f "$STUB_DIR/calls" ]] && n=$(<"$STUB_DIR/calls")
echo $((n + 1)) > "$STUB_DIR/calls"

payload=$(sed -n "${n}p" "$STUB_DIR/payloads")
[[ -n "$payload" ]] || payload=$(tail -1 "$STUB_DIR/payloads")
if [[ "$payload" == "FAIL" ]]; then
    # Real wget creates and truncates -O before it can fail.
    : > "$out"
    exit 8
fi

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
    [[ "$output" != *"needed a second download"* ]]
    [ -f "$CACHE_DIR/$CLOUD_IMG" ]
}

@test "stale cached image is re-downloaded once and the bake continues" {
    make_image "$CACHE_DIR/$CLOUD_IMG" stale
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$BATS_TEST_TMPDIR/current.img"
    stale_hash=$(hash_of "$CACHE_DIR/$CLOUD_IMG")

    run_download_block

    [ "$status" -eq 0 ]
    [[ "$output" == *"most often simply stale"* ]]
    [[ "$output" == *"attempt 2 of 2"* ]]
    [[ "$output" == *"Checksum verified"* ]]
    # The recovered run stays loud, and repeats both hashes rather than
    # asserting a cause it cannot know.
    [[ "$output" == *"needed a second download"* ]]
    [[ "$output" == *"attempt 1 produced an image hashing $stale_hash"* ]]
    [[ "$output" == *"Attempt 2 matched upstream SHA256SUMS: $(hash_of "$BATS_TEST_TMPDIR/current.img")"* ]]
    # The one re-download bypasses HTTP caches, and the build actually served
    # is logged so a repeat can be pinned to a dated build.
    [ "$(grep -cF "$CLOUD_IMG_URL" "$STUB_DIR/argv")" -eq 2 ]
    [ "$(grep -c -- '--no-cache' "$STUB_DIR/argv")" -eq 1 ]
    [[ "$output" == *"Upstream served:"* ]]
    [[ "$output" == *"Last-Modified: Fri, 14 Aug 2026"* ]]
    # The recovered run left the fresh image in place for the import step.
    [ "$(hash_of "$CACHE_DIR/$CLOUD_IMG")" = "$(hash_of "$BATS_TEST_TMPDIR/current.img")" ]
}

@test "two consecutive mismatches fail hard with both hashes" {
    make_image "$CACHE_DIR/$CLOUD_IMG" stale
    make_image "$BATS_TEST_TMPDIR/wrong.img" wrong
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$BATS_TEST_TMPDIR/wrong.img"
    stale_hash=$(hash_of "$CACHE_DIR/$CLOUD_IMG")

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"failed on both attempts"* ]]
    [[ "$output" == *"Expected: $(hash_of "$BATS_TEST_TMPDIR/current.img")"* ]]
    [[ "$output" == *"Got:      $(hash_of "$BATS_TEST_TMPDIR/wrong.img")"* ]]
    # Attempt 1's hash survives into the final message.
    [[ "$output" == *"Attempt 1 produced an image hashing $stale_hash"* ]]
    [ ! -f "$CACHE_DIR/$CLOUD_IMG" ]
}

@test "an HTML error page is reported as a bad download, not as corruption" {
    make_html_error_page "$BATS_TEST_TMPDIR/error.html"
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$BATS_TEST_TMPDIR/error.html" "$BATS_TEST_TMPDIR/error.html"

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"did not return a whole image"* ]]
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
    [[ "$output" == *"attempt 1 produced a file that was not a usable image"* ]]
    # Two downloads plus a served-build probe after each.
    [ "$(grep -cF "$CLOUD_IMG_URL" "$STUB_DIR/argv")" -eq 4 ]
    # First attempt goes through any HTTP cache as normal; only the retry bypasses it.
    [[ "$(grep -F "$CLOUD_IMG_URL" "$STUB_DIR/argv" | head -1)" != *--no-cache* ]]
    [ "$(grep -c -- '--no-cache' "$STUB_DIR/argv")" -eq 1 ]
}

@test "the size floor stays close to the real image size" {
    # Fixtures derive from the constant, so they follow it wherever it goes.
    # This is the one place the value itself is pinned: upstream publishes
    # ~595 MB, and a floor far below that accepts a badly truncated transfer.
    [ "$(min_cloud_img_bytes)" -ge $(( 300 * 1024 * 1024 )) ]
}

@test "a truncated image below the floor is rejected before hashing" {
    dd if=/dev/zero of="$CACHE_DIR/$CLOUD_IMG" bs=1 count=0 \
        seek=$(( $(min_cloud_img_bytes) - 1 )) 2>/dev/null
    printf 'QFI\xfb\x00\x00\x00\x03' | dd of="$CACHE_DIR/$CLOUD_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads FAIL

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"did not return a whole image"* ]]
    [[ "$output" != *"Checksum verification failed"* ]]
}

@test "a large non-qcow2 file is rejected before hashing" {
    dd if=/dev/zero of="$CACHE_DIR/$CLOUD_IMG" bs=1 count=0 seek="$IMG_BYTES" 2>/dev/null
    printf 'not-an-image' | dd of="$CACHE_DIR/$CLOUD_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
    cp "$CACHE_DIR/$CLOUD_IMG" "$BATS_TEST_TMPDIR/not-an-image"
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads "$BATS_TEST_TMPDIR/not-an-image"

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"does not start with the qcow2 magic"* ]]
    [[ "$output" != *"Checksum verification failed"* ]]
}

@test "a failed download aborts without leaving a partial file" {
    set_payloads FAIL

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to download cloud image"* ]]
    [ ! -f "$CACHE_DIR/$CLOUD_IMG" ]
}

@test "a failed retry download says the retry is what failed" {
    make_image "$CACHE_DIR/$CLOUD_IMG" stale
    make_image "$BATS_TEST_TMPDIR/current.img" current
    expect_sums_for "$BATS_TEST_TMPDIR/current.img"
    set_payloads FAIL
    stale_hash=$(hash_of "$CACHE_DIR/$CLOUD_IMG")

    run_download_block

    [ "$status" -eq 1 ]
    [[ "$output" == *"The re-download failed"* ]]
    [[ "$output" == *"attempt 1 had produced an image hashing $stale_hash"* ]]
    [ ! -f "$CACHE_DIR/$CLOUD_IMG" ]
}

@test "an unreachable SHA256SUMS aborts loudly and never skips verification" {
    make_image "$CACHE_DIR/$CLOUD_IMG" good
    expect_sums_for "$CACHE_DIR/$CLOUD_IMG"
    touch "$STUB_DIR/sums_fail"
    set_payloads FAIL

    run_download_block

    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not fetch"* ]]
    [[ "$output" == *"cannot verify the cloud image"* ]]
    [[ "$output" != *"skipping verification"* ]]
    [[ "$output" != *"Checksum verified"* ]]
}

@test "SHA256SUMS without an entry for the image aborts loudly" {
    make_image "$CACHE_DIR/$CLOUD_IMG" good
    printf '%s *noble-server-cloudimg-arm64.img\n' \
        0000000000000000000000000000000000000000000000000000000000000000 \
        > "$STUB_DIR/sha256sums"
    set_payloads FAIL

    run_download_block

    [ "$status" -ne 0 ]
    [[ "$output" == *"No entry for $CLOUD_IMG"* ]]
    [[ "$output" != *"skipping verification"* ]]
    [[ "$output" != *"Checksum verified"* ]]
}

@test "the checksum entry is chosen by exact filename, not by position" {
    make_image "$CACHE_DIR/$CLOUD_IMG" good
    # SHA256SUMS is sorted by hash, so a suffixed sibling can precede the real
    # entry. Selecting the first line that merely contains the name picks this.
    {
        printf '%s *%s.zst\n' \
            0000000000000000000000000000000000000000000000000000000000000000 "$CLOUD_IMG"
        sha256sum "$CACHE_DIR/$CLOUD_IMG" | awk -v img="$CLOUD_IMG" '{print $1 "  *" img}'
    } > "$STUB_DIR/sha256sums"
    set_payloads FAIL

    run_download_block

    [ "$status" -eq 0 ]
    [[ "$output" == *"Checksum verified"* ]]
}
