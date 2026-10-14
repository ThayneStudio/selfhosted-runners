#!/usr/bin/env bash
# On ZFS storage without `sparse` (a zfspool added with "Thin provision" off),
# `qm resize` reserves the bake's whole 30 GiB disk at once, and the snapshot
# `qm template` takes needs the bake's data free outside that reservation. A
# 30 GiB floor admitted a bake that left running VMs nearly no space and could
# fail at the snapshot, so the admission floor there is twice the bake disk.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bakerebake2-thick-zfs: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bakerebake2-thick-zfs: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by the bake functions
{
    NETWORK_BRIDGE=vmbr0
    VM_STORAGE=tank
    LATEST_RUNNER_VERSION=2.330.0
}
unset BAKE_MIN_FREE_GIB BAKE_TIMEOUT
gib=1048576

# pvesm status reports $mock_type with $mock_avail KiB available. pvesh returns
# $mock_cfg as the storage config, or fails.
mock_type=zfspool
mock_avail=0
mock_cfg=""
mock_pvesh_fails=0
pvesm() {
    case "$1" in
        list) printf 'Volid Format Type Size VMID\n' ;;
        status)
            printf 'Name Type Status Total Used Available %%\n'
            printf '%s %s active %d %d %d 50.00%%\n' "$VM_STORAGE" "$mock_type" \
                $((1000 * gib)) $((1000 * gib - mock_avail)) "$mock_avail"
            ;;
        *) return 1 ;;
    esac
}
pvesh() {
    printf '%s\n' "$*" >> "$state/pvesh.log"
    [[ "$mock_pvesh_fails" == 0 ]] || return 2
    printf '%s\n' "$mock_cfg"
}
qm() {
    printf '%s\n' "$*" >> "$state/qm.log"
    [[ "$1" == create ]]
}
curl() { return 22; }

create_vm() {
    : > "$state/qm.log"
    : > "$state/pvesh.log"
    create_rc=0
    create_bake_vm 9001 2>"$state/log" || create_rc=$?
}
admitted() {
    create_vm
    [[ "$create_rc" == 0 ]] || fail "$1: refused: $(cat "$state/log")"
    grep -q '^create 9001 ' "$state/qm.log" || fail "$1: the bake VM was not created"
}
refused() {
    create_vm
    [[ "$create_rc" != 0 ]] || fail "$1: the bake VM was created"
    [[ ! -s "$state/qm.log" ]] || fail "$1: qm ran: $(cat "$state/qm.log")"
    grep -qF "$2" "$state/log" || fail "$1: no '$2' in: $(cat "$state/log")"
}
thick_cfg='{"storage":"tank","type":"zfspool","pool":"tank/vms","content":"images,rootdir"}'

# Thick zfspool: the reservation plus the template snapshot.
mock_cfg=$thick_cfg
mock_avail=$((45 * gib))
refused "thick zfspool, 45 GiB free" 'storage tank has 45 GiB free and a bake needs 60 GiB'
grep -q 'Thick-provisioned ZFS reserves' "$state/log" || fail "the thick refusal did not say why: $(cat "$state/log")"
grep -qx 'get /storage/tank --output-format json' "$state/pvesh.log" \
    || fail "the storage config was not read for VM_STORAGE: $(cat "$state/pvesh.log")"
mock_avail=$((60 * gib - 1))
refused "thick zfspool, 1 KiB under 60 GiB" 'a bake needs 60 GiB'
mock_avail=$((60 * gib))
admitted "thick zfspool, 60 GiB free"
mock_cfg='{"storage":"tank","type":"zfspool","pool":"tank/vms","sparse":0}'
mock_avail=$((45 * gib))
refused "zfspool with sparse 0" 'a bake needs 60 GiB'

# ZFS over iSCSI creates its zvols the same way.
mock_type=zfs
mock_cfg='{"storage":"tank","type":"zfs","pool":"tank/vms","portal":"10.0.0.5"}'
refused "thick ZFS over iSCSI" 'a bake needs 60 GiB'

# A config that cannot be read counts as thick.
mock_type=zfspool
mock_pvesh_fails=1
refused "unreadable storage config" 'a bake needs 60 GiB'
grep -q 'counting it as thick-provisioned' "$state/log" || fail "the unreadable config was not reported"
mock_pvesh_fails=0
mock_cfg='[{"vmid":100,"type":"qemu"}]'
refused "storage config that is not an object" 'a bake needs 60 GiB'

# Sparse ZFS keeps the disk-sized floor (the installer's local-zfs).
mock_cfg='{"storage":"tank","type":"zfspool","pool":"tank/vms","sparse":1}'
mock_avail=$((30 * gib))
admitted "sparse zfspool, 30 GiB free"
mock_avail=$((30 * gib - 1))
refused "sparse zfspool, 1 KiB under 30 GiB" 'a bake needs 30 GiB'
if grep -q 'Thick-provisioned' "$state/log"; then fail "a sparse zfspool was called thick"; fi

# Other storage types are thin here and need no storage config.
for type in lvmthin dir rbd; do
    mock_type=$type
    mock_cfg=$thick_cfg
    mock_avail=$((30 * gib))
    admitted "$type, 30 GiB free"
    [[ ! -s "$state/pvesh.log" ]] || fail "$type: read a storage config: $(cat "$state/pvesh.log")"
done

# BAKE_MIN_FREE_GIB is taken as given, thick or not.
mock_type=zfspool
mock_cfg=$thick_cfg
mock_avail=$((45 * gib))
BAKE_MIN_FREE_GIB=40
admitted "thick zfspool with BAKE_MIN_FREE_GIB=40"
# shellcheck disable=SC2034 # check_bake_storage_space reads it
BAKE_MIN_FREE_GIB=50
refused "thick zfspool with BAKE_MIN_FREE_GIB=50" 'a bake needs 50 GiB'
unset BAKE_MIN_FREE_GIB

printf 'bakerebake2-thick-zfs: ok\n'
