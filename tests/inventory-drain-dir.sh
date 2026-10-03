#!/usr/bin/env bash
# `runner stop` sets the pool drain flag in /run/lock, which is 1777 on
# Debian. `install -d -m 755` chmodded that directory to 0755 and dropped the
# sticky bit until the next reboot, so non-root programs could no longer
# create their locks there.
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

mkdir "$state/lock"
chmod 1777 "$state/lock"
POOL_DRAIN_FILE=$state/lock/github-runner-drain
enable_pool_drain
pool_is_draining || fail "enable_pool_drain did not set the drain flag"
# find -perm -1777 matches only while every bit of 1777 is still set.
[[ -n "$(find "$state/lock" -maxdepth 0 -perm -1777)" ]] ||
    fail "enable_pool_drain dropped the lock directory's 1777 mode"

disable_pool_drain
if pool_is_draining; then fail "disable_pool_drain left the drain flag"; fi

# A lock directory that does not exist yet is still created.
POOL_DRAIN_FILE=$state/missing/github-runner-drain
enable_pool_drain
pool_is_draining || fail "enable_pool_drain did not create a missing lock directory"

printf 'inventory-drain-dir: ok\n'
