#!/usr/bin/env bash
# Releasing the VMID reservation or the clone slot must close that fd and
# nothing else. `exec 203>&- 2>/dev/null` also pointed the calling shell's
# stderr at /dev/null for good, which hid every later log line: the rebake's
# "TEMPLATE_ID is now" and each qm set/start failure after a clone.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'inventory-fd-release: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'inventory-fd-release: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
VMID_RESERVATION_LOCK_PREFIX=$state/reserve
CLONE_SLOT_LOCK_PREFIX=$state/slot

fd_open() { { : >&"$1"; } 2>/dev/null; }

# Each case runs in a subshell with stderr captured. The line logged after
# the release has to arrive, and nothing else may.
out=$( (
    exec 203>"$(vmid_reservation_lock_file 9001)"
    release_vmid_reservation 9001
    if fd_open 203; then echo "fd 203 is still open"; fi
    log_warn "after release_vmid_reservation"
) 2>&1 )
[[ "$out" == "$(log_warn "after release_vmid_reservation" 2>&1)" ]] ||
    fail "release_vmid_reservation hid later stderr or left fd 203 open: ${out:-<nothing>}"
[[ ! -e "$(vmid_reservation_lock_file 9001)" ]] || fail "release_vmid_reservation left its lock file"

out=$( (
    exec 204>"${CLONE_SLOT_LOCK_PREFIX}-1.lock"
    release_clone_slot
    if fd_open 204; then echo "fd 204 is still open"; fi
    log_warn "after release_clone_slot"
) 2>&1 )
[[ "$out" == "$(log_warn "after release_clone_slot" 2>&1)" ]] ||
    fail "release_clone_slot hid later stderr or left fd 204 open: ${out:-<nothing>}"

# cleanup_rebake and clone_runner also release when nothing is held.
out=$( (
    release_vmid_reservation ""
    release_clone_slot
    log_warn "after releasing nothing"
) 2>&1 )
[[ "$out" == "$(log_warn "after releasing nothing" 2>&1)" ]] ||
    fail "releasing an fd that was not open failed or hid stderr: ${out:-<nothing>}"

printf 'inventory-fd-release: ok\n'
