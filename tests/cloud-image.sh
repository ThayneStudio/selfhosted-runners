#!/usr/bin/env bash
# A stale cached cloud image must be replaced, not fail the bake. A fresh
# download that fails the checksum must fail and leave no cache behind.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'cloud-image: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'cloud-image: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
IMG_CACHE_DIR=$state/cache
img=$IMG_CACHE_DIR/$CLOUD_IMG
downloads=$state/downloads
: > "$downloads"

# The "checksum" of a file is its contents, so fixtures stay readable.
published=new-image
served=new-image
wget() {
    local out="" url
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -O) out="$2"; shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    if [[ "$url" == */SHA256SUMS ]]; then
        printf '%s *%s\n' "$published" "$CLOUD_IMG"
        return 0
    fi
    printf '%s\n' "$url" >> "$downloads"
    printf '%s' "$served" > "$out"
}
sha256sum() { printf '%s  %s\n' "$(cat "$1")" "$1"; }

mkdir -p "$IMG_CACHE_DIR"
printf 'new-image' > "$img"
prepare_cloud_image 2>/dev/null || fail "a current cache was rejected"
[[ ! -s "$downloads" ]] || fail "a current cache was downloaded again"

printf 'old-image' > "$img"
prepare_cloud_image 2>/dev/null || fail "a stale cache failed the bake instead of being replaced"
[[ $(wc -l < "$downloads") -eq 1 ]] || fail "a stale cache was not downloaded once"
[[ $(cat "$img") == new-image ]] || fail "the stale cache was not replaced"

served=corrupt
printf 'old-image' > "$img"
if prepare_cloud_image 2>/dev/null; then
    fail "a download that failed the checksum was accepted"
fi
[[ ! -e "$img" ]] || fail "a failed download left a cached image"
[[ -z "$(find "$IMG_CACHE_DIR" -type f)" ]] || fail "a failed download left a temp file"

printf 'cloud-image: ok\n'
