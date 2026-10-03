#!/usr/bin/env bash
# setup and rebake both create the bake VM through create_bake_vm. It must not
# create one when VM_STORAGE has less free space than the bake disk can fill,
# or when that cannot be read: a full storage pauses every VM on it.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-admission: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bake-admission: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by the bake functions
{
    NETWORK_BRIDGE=vmbr0
    VM_STORAGE=local-zfs
    LATEST_RUNNER_VERSION=2.329.0
}
gib=1048576

mock_rows=""
mock_pvesm_fails=0
pvesm() {
    printf '%s\n' "$*" >> "$state/pvesm.log"
    [[ "$1" == status ]] || return 1
    [[ "$mock_pvesm_fails" == 0 ]] || return 2
    printf 'Name             Type     Status           Total            Used       Available        %%\n'
    [[ -z "$mock_rows" ]] || printf '%s\n' "$mock_rows"
}
storage_row() {
    printf '%-16s %8s %10s %15d %15d %15d %7.2f%%' "$1" zfspool "$2" $((500 * gib)) $((500 * gib - $3)) "$3" 50
}
# The installer's local-zfs is sparse: a bake takes at most its disk there.
# bakerebake2-thick-zfs covers zfspool storage without `sparse`.
pvesh() { printf '{"storage":"%s","type":"zfspool","pool":"rpool/data","sparse":1}\n' "${2#/storage/}"; }
qm() {
    printf '%s\n' "$*" >> "$state/qm.log"
    [[ "$1" == create ]]
}
curl() { return 22; }

create_vm() {
    : > "$state/qm.log"
    : > "$state/pvesm.log"
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
    grep -q "$2" "$state/log" || fail "$1: no '$2' in: $(cat "$state/log")"
}

mock_rows=$(storage_row local-zfs active $((100 * gib)))
admitted "100 GiB free"
grep -qx 'status --storage local-zfs' "$state/pvesm.log" || fail "free space was not read for VM_STORAGE"
mock_rows=$(storage_row local-zfs active $((30 * gib)))
admitted "exactly 30 GiB free"

mock_rows=$(storage_row local-zfs active $((10 * gib)))
refused "10 GiB free" 'storage local-zfs has 10 GiB free and a bake needs 30 GiB'
mock_rows=$(storage_row local-zfs active $((30 * gib - 1)))
refused "1 KiB under 30 GiB" 'has 29 GiB free'
# Only VM_STORAGE's row counts.
mock_rows=$(storage_row local active $((400 * gib)))$'\n'$(storage_row local-zfs active $((10 * gib)))
refused "another storage has space" 'has 10 GiB free'

# Free space that cannot be read is not free space.
mock_rows=$(storage_row local-zfs inactive 0)
refused "inactive storage" 'status: inactive'
mock_rows=""
refused "storage missing from pvesm status" 'Could not read free space on storage local-zfs'
mock_rows=$(storage_row local-zfs active $((100 * gib)))
mock_pvesm_fails=1
refused "pvesm status failed" 'Could not read free space on storage local-zfs'

# BAKE_MIN_FREE_GIB moves the floor; 0 skips the check.
BAKE_MIN_FREE_GIB=0
admitted "BAKE_MIN_FREE_GIB=0 with pvesm failing"
mock_pvesm_fails=0
mock_rows=$(storage_row local-zfs active $((10 * gib)))
BAKE_MIN_FREE_GIB=5
admitted "BAKE_MIN_FREE_GIB=5 with 10 GiB free"
BAKE_MIN_FREE_GIB=50
mock_rows=$(storage_row local-zfs active $((40 * gib)))
refused "BAKE_MIN_FREE_GIB=50 with 40 GiB free" 'a bake needs 50 GiB'
# shellcheck disable=SC2034 # check_bake_storage_space reads it
BAKE_MIN_FREE_GIB=lots
refused "non-numeric BAKE_MIN_FREE_GIB" 'BAKE_MIN_FREE_GIB must be a whole number'
unset BAKE_MIN_FREE_GIB

printf 'bake-admission: ok\n'
