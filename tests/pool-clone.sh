#!/usr/bin/env bash
# clone_runner must configure a clone so the pool can always recycle it:
# a guest reboot has to exit QEMU (post-stop, then reclone) instead of
# resetting in place with no runner.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool-clone: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'pool-clone: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

INSTALL_DIR=$root
SNIPPETS_DIR=$state/snippets
mkdir -p "$SNIPPETS_DIR"
POOL_DRAIN_FILE=$state/drain
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
VMID_LOCK_FILE=$state/vmid.lock
VMID_RESERVATION_LOCK_PREFIX=$state/reserve
CLONE_SLOT_LOCK_PREFIX=$state/clone-slot
TEMPLATE_ID=9000
VM_STORAGE=local-zfs
MIN_VMID=9001
GITHUB_ORG=acme
GITHUB_PAT=ghp_test
calls=$state/qm.calls

flock() { :; }
generate_mac() { printf '02:00:00:00:00:01\n'; }
fetch_jit_config() { printf 'Zm9v\n'; }
qm() {
    printf '%s\n' "$*" >> "$calls"
    case "$1" in
        config) printf 'name: %s\nnet0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0\n' "$clone_name" ;;
        clone) clone_name=$5 ;;
    esac
}
clone_name=""

: > "$calls"
vmid=$(clone_runner runner-1 acme) || fail "clone_runner failed"
[[ "$vmid" == 9001 ]] || fail "unexpected VMID: $vmid"

reboot_line=$(grep -n '^set 9001 --reboot 0$' "$calls" | cut -d: -f1) || fail "reboot was not disabled on the clone"
start_line=$(grep -n '^start 9001$' "$calls" | cut -d: -f1) || fail "the clone was not started"
(( reboot_line < start_line )) || fail "reboot was disabled only after the clone started"

printf 'pool-clone: ok\n'
