#!/usr/bin/env bash
# A pending-bake record whose VMID belongs to a container is stale: the bake
# VM is always QEMU, so `qm status` fails while /cluster/resources still lists
# the VMID. Keeping that record failed every later rebake before it could bake.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'rebake-container-vmid: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'rebake-container-vmid: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# These globals are read by the sourced rebake functions.
# shellcheck disable=SC2034
{
    STATE_DIR=$state
    PENDING_BAKE_FILE=$state/pending-bake
    PENDING_VERSION_FILE=$state/pending-version
    TEMPLATE_ID=9000
    REBAKE_PUBLISHED=0
}
actions=$state/actions
: > "$actions"

# VMID 9002 has no QEMU config here; only the inventory says what it is.
qm() {
    printf '%s\n' "$*" >> "$actions"
    [[ "$1" == status || "$1" == config ]] && return 2
    return 1
}
mock_inventory=""
inventory_fails=0
pvesh() {
    [[ "$inventory_fails" == 0 ]] || return 1
    printf '%s\n' "$mock_inventory"
}
release_vmid_reservation() { :; }
seed() {
    printf '9002\n' > "$PENDING_BAKE_FILE"
    printf 'version=2.330.0\n' > "$PENDING_VERSION_FILE"
}
assert_kept() {
    [[ "$(cat "$PENDING_BAKE_FILE")" == 9002 ]] || fail "$1: the pending record was dropped"
    [[ -e "$PENDING_VERSION_FILE" ]] || fail "$1: the pending version was dropped"
}
assert_dropped() {
    [[ ! -e "$PENDING_BAKE_FILE" && ! -e "$PENDING_VERSION_FILE" ]] || fail "$1: the stale pending record was kept"
}
container='[{"vmid":9000,"type":"qemu"},{"vmid":9002,"type":"lxc"}]'

# recover_pending_bake drops the record of a VMID that a container holds.
seed
mock_inventory=$container
recover_pending_bake || fail "recover_pending_bake failed on a container-held VMID"
assert_dropped "recover_pending_bake"
recover_pending_bake || fail "the next run still failed"

# cleanup_rebake drops it too, still reporting the failed bake.
seed
BAKE_VMID=9002
if (cleanup_rebake 1); then fail "cleanup_rebake reported success after a failed bake"; fi
assert_dropped "cleanup_rebake"

# Anything short of a readable inventory that names a container keeps it. A
# QEMU VM listed on this node proves nothing either. (recover_pending_bake
# drops a VMID listed on another node: records-pending-bake.sh.)
uname() { printf 'pve1\n'; }
for condition in qemu_here no_type unreadable malformed; do
    inventory_fails=0
    case "$condition" in
        qemu_here) mock_inventory='[{"vmid":9002,"type":"qemu","node":"pve1"}]' ;;
        no_type) mock_inventory='[{"vmid":9002}]' ;;
        unreadable) inventory_fails=1 ;;
        malformed) mock_inventory='not JSON' ;;
    esac
    seed
    if recover_pending_bake; then fail "$condition: recover_pending_bake dropped an unproven record"; fi
    assert_kept "$condition: recover_pending_bake"
    if (cleanup_rebake 1); then fail "$condition: cleanup_rebake reported success"; fi
    assert_kept "$condition: cleanup_rebake"
done

if grep -E '^(destroy|stop) ' "$actions" >&2; then
    fail "a stale record led to a VM being stopped or destroyed"
fi

printf 'rebake-container-vmid: ok\n'
