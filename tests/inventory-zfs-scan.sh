#!/usr/bin/env bash
# The ZFS half of list_template_linked_clone_volids looks up every vm-*
# volume from one `pvesm list` snapshot, which includes the runners'
# cloud-init zvols. A reclone that destroyed one of them mid-scan made the
# lookup fail and the whole scan fail, so the daily rebake kept a retired
# template it could have destroyed. A volume that is gone depends on nothing;
# every other failed lookup must still fail closed.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'inventory-zfs-scan: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'inventory-zfs-scan: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
cd "$state"
VM_STORAGE=local-zfs

qm() {
    [[ "$1" == config ]] || return 1
    printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 1\n'
}

# State lives in files: pvesm path runs inside $(...), so a variable it sets
# would not survive. Mocks read only mock_* variables.
mock_storage=$state/storage
mock_race=$state/race
mock_list_fails=$state/list-fails
mock_origin_fails=$state/origin-fails
pvesm() {
    local volume
    case "$1" in
        list)
            [[ ! -e "$mock_list_fails" ]] || return 1
            printf 'Volid Format Type Size VMID\n'
            while read -r volume; do
                printf 'local-zfs:%s raw images 1 0\n' "$volume"
            done < "$mock_storage"
            ;;
        path)
            # Like ZFSPoolPlugin, the path is built without checking that the
            # zvol exists.
            if [[ "$2" == local-zfs:vm-9001-cloudinit && -e "$mock_race" ]]; then
                # A reclone destroys VM 9002 while 9001 is being looked up.
                grep -v 'vm-9002-' "$mock_storage" > "$mock_storage.new" || true
                mv "$mock_storage.new" "$mock_storage"
                [[ "$(cat "$mock_race")" != list-fails ]] || : > "$mock_list_fails"
            fi
            printf '/dev/zvol/rpool/data/%s\n' "${2##*[:/]}"
            ;;
        *) return 1 ;;
    esac
}
zfs_exists() { grep -qE "(^|/)${1##*/}\$" "$mock_storage"; }
zfs() {
    local dataset="${*: -1}"
    case "$1" in
        list) zfs_exists "$dataset" ;;
        get)
            zfs_exists "$dataset" || return 1
            ! grep -qxF "$dataset" "$mock_origin_fails" 2>/dev/null || return 1
            case "${dataset##*/}" in
                vm-9001-disk-0 | vm-9002-disk-0 | vm-9004-disk-0) printf 'rpool/data/base-9000-disk-0@__base__\n' ;;
                *) printf -- '-\n' ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

reset() {
    # Proxmox lists linked clones nested under the base. vm-9004-disk-0 is a
    # clone listed flat, which only the origin lookup finds.
    printf '%s\n' base-9000-disk-0 \
        base-9000-disk-0/vm-9001-disk-0 vm-9001-cloudinit \
        base-9000-disk-0/vm-9002-disk-0 vm-9002-cloudinit \
        vm-9003-disk-0 vm-9004-disk-0 > "$mock_storage"
    rm -f "$mock_race" "$mock_list_fails" "$mock_origin_fails"
}

reset
expected=$'local-zfs:base-9000-disk-0/vm-9001-disk-0\nlocal-zfs:base-9000-disk-0/vm-9002-disk-0\nlocal-zfs:vm-9004-disk-0'
out=$(list_template_linked_clone_volids 9000) || fail "the scan failed with nothing destroyed"
[[ "$out" == "$expected" ]] || fail "the scan listed: $out"

# VM 9002 disappears mid-scan. Its cloud-init zvol is skipped and the scan
# still reports the clones it saw.
reset
printf 'destroy\n' > "$mock_race"
out=$(list_template_linked_clone_volids 9000 2>"$state/stderr") ||
    fail "a runner destroyed mid-scan failed the scan: $(cat "$state/stderr")"
[[ "$out" == "$expected" ]] || fail "after a runner was destroyed mid-scan the scan listed: $out"

# If the fresh listing fails, nothing proves the volume is gone.
reset
printf 'list-fails\n' > "$mock_race"
if list_template_linked_clone_volids 9000 >/dev/null 2>&1; then
    fail "a failed lookup passed although the storage could not be listed again"
fi

# A volume that still exists but cannot be read fails closed.
reset
printf 'rpool/data/vm-9003-disk-0\n' > "$mock_origin_fails"
if list_template_linked_clone_volids 9000 >/dev/null 2>&1; then
    fail "a failed origin lookup for a listed volume passed"
fi

printf 'inventory-zfs-scan: ok\n'
