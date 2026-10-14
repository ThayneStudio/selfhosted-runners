#!/usr/bin/env bash
# A killed cloud-image download leaves its temp file beside the cache. The
# next prepare_cloud_image must remove one that has sat idle, and must keep a
# download that may still be running and the cached image itself.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-cache-sweep: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bake-cache-sweep: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
IMG_CACHE_DIR=$state/cache
img=$IMG_CACHE_DIR/$CLOUD_IMG

# The "checksum" of a file is its contents, as in cloud-image.sh.
published=current-image
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
    printf '%s\n' "$url" >> "$state/downloads"
    printf '%s' "$published" > "$out"
}
sha256sum() { printf '%s  %s\n' "$(cat "$1")" "$1"; }

mkdir -p "$IMG_CACHE_DIR"
stale=$img.Ab12Cd
running=$img.Ef34Gh
seed_partials() {
    printf 'partial' > "$stale"
    touch -t 202001010000 "$stale"
    printf 'partial' > "$running"
}

# A current cache returns early; the sweep still runs. The cached image is
# usually days old and must survive it.
seed_partials
printf 'current-image' > "$img"
touch -t 202001010000 "$img"
: > "$state/downloads"
prepare_cloud_image 2>/dev/null || fail "a current cache was rejected"
[[ ! -e "$stale" ]] || fail "an idle partial download was left behind"
[[ -e "$running" ]] || fail "a download that may still be running was removed"
[[ ! -s "$state/downloads" ]] || fail "the cached image was removed and downloaded again"
[[ "$(cat "$img" 2>/dev/null)" == current-image ]] || fail "the cached image was removed"

# Before a fresh download as well, and the download still lands.
seed_partials
rm -f "$img"
prepare_cloud_image 2>/dev/null || fail "a fresh download failed"
[[ ! -e "$stale" ]] || fail "an idle partial download was left behind before a download"
[[ "$(cat "$img")" == current-image ]] || fail "the fresh download was not installed"
[[ "$(find "$IMG_CACHE_DIR" -type f -name "$CLOUD_IMG.*")" == "$running" ]] \
    || fail "unexpected temp files: $(find "$IMG_CACHE_DIR" -type f)"

printf 'bake-cache-sweep: ok\n'
