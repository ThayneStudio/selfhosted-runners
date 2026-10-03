#!/usr/bin/env bash
# Setup must offer and accept only storage that can hold a template and its
# linked clones. Thick LVM and iSCSI accept `qm template` without making a
# base volume, so every linked clone then fails. A VM_STORAGE that differs from
# the template's own storage must be reported, not silently ignored.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup-storage: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'setup-storage: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# `pvesm status` output; local is a dir storage without the images content type.
pvesm() {
    [[ "$1" == status ]] || return 1
    printf 'Name Type Status Total Used Available %%\n'
    if [[ "$*" != "status --content images" ]]; then
        printf 'local dir active 1 1 1 1%%\n'
    fi
    printf '%s\n' \
        'local-zfs zfspool active 1 1 1 1%' \
        'local-lvm lvmthin active 1 1 1 1%' \
        'san-lvm lvm active 1 1 1 1%' \
        'lun iscsi active 1 1 1 1%' \
        'ceph rbd active 1 1 1 1%'
}

[[ "$(template_storages)" == $'local-zfs zfspool\nlocal-lvm lvmthin\nceph rbd' ]] \
    || fail "the storage list offers storage that cannot hold linked clones"
for storage in local-zfs local-lvm ceph; do
    check_vm_storage "$storage" 2>/dev/null || fail "$storage was refused"
done
for storage in san-lvm lun local; do
    if check_vm_storage "$storage" 2> "$state/err"; then
        fail "$storage was accepted for the template"
    fi
    grep -qF "Storage '$storage' (" "$state/err" || fail "the refusal of $storage did not name its type"
done
if check_vm_storage missing 2> "$state/err"; then
    fail "a missing storage was accepted"
fi
grep -qF "does not exist" "$state/err" || fail "a missing storage was not reported as missing"

# The template's disks decide where linked clones go.
qm() {
    [[ "$1" == config ]] || return 1
    printf 'name: ubuntu-cloud-template\nide2: fast-zfs:vm-9000-cloudinit,media=cdrom\nscsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 1\n'
}
TEMPLATE_ID=9000
VM_STORAGE=fast-zfs
warn_template_storage 2> "$state/err"
grep -qF 'disks on local-zfs, not fast-zfs' "$state/err" || fail "a VM_STORAGE change that does not apply was not reported"
grep -qF "rm -f $BAKED_VERSION_FILE && runner rebake" "$state/err" || fail "the warning did not say how to bake on the new storage"
VM_STORAGE=local-zfs
warn_template_storage 2> "$state/err"
[[ ! -s "$state/err" ]] || fail "storage that matches the template was reported"

# The wizard lists and checks storage with these helpers.
main=$(awk '/^require_root "setup"$/ { seen = 1 } seen' "$root/lib/setup.sh")
grep -qF 'template_storages | awk' <<< "$main" || fail "setup.sh no longer lists storage with template_storages"
grep -qF 'if ! check_vm_storage ' <<< "$main" || fail "setup.sh no longer checks VM_STORAGE"
grep -qxF '    warn_template_storage' <<< "$main" || fail "setup.sh no longer reports a storage mismatch"

printf 'setup-storage: ok\n'
