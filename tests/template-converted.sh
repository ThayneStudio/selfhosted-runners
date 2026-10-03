#!/usr/bin/env bash
# template_is_converted must accept only a template whose disks were converted
# to base volumes. `template: 1` alone is written before the conversion runs.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'template-converted: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'template-converted: %s\n' "$1" >&2; exit 1; }

config=""
config_fails=0
qm() {
    [[ "$1" == config ]] || return 1
    [[ "$config_fails" == 0 ]] || return 2
    printf '%s\n' "$config"
}

accept() {
    config="$2"
    template_is_converted 9000 || fail "rejected a converted template: $1"
}
reject() {
    config="$2"
    if template_is_converted 9000; then
        fail "accepted an unusable template: $1"
    fi
}

accept "zfs" $'name: ubuntu-cloud-template\nide2: local-zfs:vm-9000-cloudinit,media=cdrom\nscsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 1'
accept "lvm-thin" $'scsi0: local-lvm:base-9000-disk-0,size=30G\ntemplate: 1'
accept "dir qcow2" $'ide2: local:9000/vm-9000-cloudinit.qcow2,media=cdrom\nscsi0: local:9000/base-9000-disk-0.qcow2,size=30G\ntemplate: 1'
reject "flag written, disk not converted" $'scsi0: local-zfs:vm-9000-disk-0,size=30G\ntemplate: 1'
reject "second disk not converted" $'scsi0: local-zfs:base-9000-disk-0,size=30G\nscsi1: local-zfs:vm-9000-disk-1,size=8G\ntemplate: 1'
reject "base volume of another VM" $'scsi0: local-zfs:base-8999-disk-0,size=30G\ntemplate: 1'
reject "not a template" $'scsi0: local-zfs:vm-9000-disk-0,size=30G'
reject "no disks" $'name: ubuntu-cloud-template\ntemplate: 1'
reject "template: 10 is not template: 1" $'scsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 10'
config=$'scsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 1'
config_fails=1
if template_is_converted 9000; then
    fail "accepted a template whose config could not be read"
fi
config_fails=0
if template_is_converted abc; then
    fail "accepted a non-numeric VMID"
fi

printf 'template-converted: ok\n'
