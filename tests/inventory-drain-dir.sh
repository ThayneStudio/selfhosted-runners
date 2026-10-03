#!/usr/bin/env bash
# `runner stop` sets the pool drain flag in the runner runtime directory.
# That directory is created mode 0700. A looser one is tightened. Its parent
# is left alone: an earlier `install -d -m` on the flag's directory chmodded
# `/run/lock` itself and dropped the sticky bit until the next reboot.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'inventory-drain-dir: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'inventory-drain-dir: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

mkdir -m 755 "$state/parent"
mkdir -m 1777 "$state/parent/lock"
POOL_DRAIN_FILE=$state/parent/lock/github-runner-drain
LEGACY_POOL_DRAIN_FILE=$state/legacy-drain
# The default legacy path is the host's /run/lock flag. enable_pool_drain
# publishes it and the last case below used to leave that file behind.
[[ "$LEGACY_POOL_DRAIN_FILE" == "$state/"* ]] ||
    fail "legacy drain flag is $LEGACY_POOL_DRAIN_FILE"
enable_pool_drain
pool_is_draining || fail "enable_pool_drain did not set the drain flag"
[[ -f "$LEGACY_POOL_DRAIN_FILE" && ! -L "$LEGACY_POOL_DRAIN_FILE" ]] ||
    fail "enable_pool_drain did not publish the legacy drain flag in the scratch dir"
[[ "$(file_mode "$state/parent")" == "755" ]] ||
    fail "enable_pool_drain changed the parent directory's mode"
[[ "$(file_mode "$state/parent/lock")" == "700" ]] ||
    fail "enable_pool_drain left the drain directory mode $(file_mode "$state/parent/lock")"
[[ "$(file_owner "$state/parent/lock")" == "$EUID" ]] ||
    fail "enable_pool_drain left the drain directory owned by $(file_owner "$state/parent/lock")"

disable_pool_drain
if pool_is_draining; then fail "disable_pool_drain left the drain flag"; fi

# A lock directory that does not exist yet is created mode 0700.
POOL_DRAIN_FILE=$state/missing/github-runner-drain
enable_pool_drain
pool_is_draining || fail "enable_pool_drain did not create a missing lock directory"
[[ "$(file_mode "$state/missing")" == "700" ]] ||
    fail "a missing drain directory was created mode $(file_mode "$state/missing")"
disable_pool_drain
[[ ! -e "$POOL_DRAIN_FILE" && ! -e "$LEGACY_POOL_DRAIN_FILE" ]] ||
    fail "the scratch drain flags were left behind"

printf 'inventory-drain-dir: ok\n'
