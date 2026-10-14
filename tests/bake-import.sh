#!/usr/bin/env bash
# The bake must attach the volume `qm importdisk` created, whichever format
# qemu-server prints, and never a guessed vm-<vmid>-disk-0.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-import: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bake-import: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
attached=$state/attached

mock_import=""
mock_config=""
mock_config_fails=0
# The first `qm set` attaches scsi0. Record that volid and fail the set, so the
# bake stops there.
qm() {
    local arg prev=""
    case "$1" in
        importdisk) printf '%s\n' "$mock_import" ;;
        config)
            [[ "$mock_config_fails" == 0 ]] || return 2
            printf '%s\n' "$mock_config"
            ;;
        set)
            for arg in "$@"; do
                [[ "$prev" != --scsi0 ]] || printf '%s\n' "$arg" >> "$attached"
                prev=$arg
            done
            return 1
            ;;
        *) return 1 ;;
    esac
}

run_bake() {
    : > "$attached"
    if bake_and_publish_vm 9001 2>"$state/log"; then
        fail "$1: the bake did not stop at the mocked qm set"
    fi
}

expect_attached() {
    local name="$1" want="$2"
    run_bake "$name"
    [[ "$(cat "$attached")" == "$want" ]] || fail "$name: attached '$(cat "$attached")', expected '$want'"
}

expect_refused() {
    local name="$1"
    run_bake "$name"
    [[ ! -s "$attached" ]] || fail "$name: attached '$(cat "$attached")' instead of failing"
    grep -q 'Could not find the imported disk' "$state/log" || fail "$name: no error names the missing disk"
}

progress=$'importing disk \'/var/cache/github-runners/noble-server-cloudimg-amd64.img\' to VM 9001 ...\ntransferred 3.5 GiB of 3.5 GiB (100.00%)'

# qemu-server before 8.2.7.
VM_STORAGE=local-zfs
mock_import="$progress"$'\nSuccessfully imported disk as \'unused0:local-zfs:vm-9001-disk-0\''
expect_attached "pre-8.2.7 zfs" local-zfs:vm-9001-disk-0
VM_STORAGE=local
mock_import="$progress"$'\nSuccessfully imported disk as \'unused0:local:9001/vm-9001-disk-0.raw\''
expect_attached "pre-8.2.7 dir" local:9001/vm-9001-disk-0.raw

# qemu-server 8.2.7 and later (PVE 8.3+). A guess would name local:vm-9001-disk-0,
# which dir storage cannot parse.
mock_import="$progress"$'\nunused0: successfully imported disk \'local:9001/vm-9001-disk-0.raw\''
expect_attached "8.3 dir" local:9001/vm-9001-disk-0.raw
# A leftover vm-9001-disk-0 pushed the import to disk-1. A guess would attach
# the leftover runner disk.
VM_STORAGE=local-zfs
mock_import="$progress"$'\nunused0: successfully imported disk \'local-zfs:vm-9001-disk-1\''
expect_attached "8.3 zfs after a leftover disk-0" local-zfs:vm-9001-disk-1

# An unknown format falls back to the unused0 entry importdisk wrote.
VM_STORAGE=local
mock_import="$progress"$'\nimported the disk to unused0'
mock_config=$'boot: order=net0\nname: ubuntu-cloud-template\nunused0: local:9001/vm-9001-disk-0.qcow2'
expect_attached "unknown format, read from config" local:9001/vm-9001-disk-0.qcow2

# Neither the output nor the config names the disk: fail, never guess.
mock_config=$'name: ubuntu-cloud-template'
expect_refused "unknown format, no unused0 in config"
mock_config=$'unused0: local:9001/vm-9001-disk-0.qcow2'
mock_config_fails=1
expect_refused "unknown format, unreadable config"
mock_config_fails=0

# A volid on another storage is not this import.
# shellcheck disable=SC2034 # bake_and_publish_vm reads it
VM_STORAGE=local-zfs
mock_import="$progress"$'\nunused0: successfully imported disk \'local:9001/vm-9001-disk-0.raw\''
expect_refused "volid on another storage"

printf 'bake-import: ok\n'
