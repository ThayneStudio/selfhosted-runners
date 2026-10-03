#!/usr/bin/env bash
# `pvesm free` runs the deletion as a task and exits 0 even when that task
# fails (a busy zvol, an open LV). Orphan cleanup took the exit status as
# proof: `runner stop` reported freed volumes that still existed, and the
# watcher's sweep logged "reaped" for the same volume every tick.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'inventory-volume-free: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'inventory-volume-free: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
cd "$state"
PVE_NODES_DIR=$state/nodes
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
TEMPLATE_ID=9000
MIN_VMID=9001
VM_STORAGE=local-lvm
mkdir -p "$PVE_NODES_DIR/pve1/qemu-server"
: > "$PVE_NODES_DIR/pve1/qemu-server/9000.conf"

flock() { return 0; }
qm() {
    [[ "$1" == config ]] || return 1
    printf 'name: ubuntu-cloud-template\nscsi0: local-lvm:base-9000-disk-0,size=30G\ntemplate: 1\n'
}

# Mocks read only mock_* variables, which no lib function declares locally.
mock_storage=$state/storage
mock_busy=$state/busy
mock_list_fails=0
pvesm() {
    local volume
    case "$1" in
        list)
            [[ "$mock_list_fails" == 0 ]] || return 1
            printf 'Volid Format Type Size VMID\n'
            while read -r volume; do
                printf '%s:%s raw images 1 0\n' "$2" "$volume"
            done < "$mock_storage"
            ;;
        free)
            if grep -qxF "$2" "$mock_busy"; then
                # What the real CLI does when its imgdel task fails.
                printf "cannot remove '%s': Logical volume in use\n" "${2#*:}" >&2
                return 0
            fi
            grep -vxF "${2#*:}" "$mock_storage" > "$mock_storage.new" || true
            mv "$mock_storage.new" "$mock_storage"
            ;;
        path) printf '/dev/pve/%s\n' "${2#*:}" ;;
        *) return 1 ;;
    esac
}
reset() {
    printf '%s\n' base-9000-disk-0 base-9000-disk-0/vm-9001-disk-0 vm-9005-disk-0 > "$mock_storage"
    : > "$mock_busy"
    mock_list_fails=0
}

reset
free_volume local-lvm:vm-9005-disk-0 || fail "a volume that was removed was not reported freed"
if grep -qxF vm-9005-disk-0 "$mock_storage"; then fail "the free did not run"; fi

reset
printf 'local-lvm:vm-9005-disk-0\n' > "$mock_busy"
if free_volume local-lvm:vm-9005-disk-0 2>/dev/null; then
    fail "a volume still listed after pvesm free was reported freed"
fi

# Without a listing nothing proves the volume is gone.
reset
mock_list_fails=1
if free_volume local-lvm:vm-9005-disk-0 2>/dev/null; then
    fail "a free whose result could not be listed was reported freed"
fi

# runner stop: a linked-clone child that survives its free fails the cleanup.
reset
printf 'local-lvm:base-9000-disk-0/vm-9001-disk-0\n' > "$mock_busy"
rc=0
cleanup_template_orphan_volumes 2> "$state/stderr" || rc=$?
[[ "$rc" -ne 0 ]] || fail "template cleanup succeeded while its orphan volume still exists"
if grep -q "Freed 1 orphaned" "$state/stderr"; then
    fail "template cleanup counted a volume that still exists as freed"
fi
reset
cleanup_template_orphan_volumes 2> "$state/stderr" || fail "template cleanup failed: $(cat "$state/stderr")"
grep -q "Freed 1 orphaned linked-clone volume" "$state/stderr" || fail "template cleanup did not report its free"

# The watcher's sweep frees both orphans (VMs 9001 and 9005 have no config).
# It must warn about the one that stays and count only the other.
reset
printf 'local-lvm:vm-9005-disk-0\n' > "$mock_busy"
cleanup_runner_orphan_volumes 2> "$state/stderr"
grep -q "pvesm free local-lvm:vm-9005-disk-0 failed" "$state/stderr" || fail "the sweep did not report a failed free: $(cat "$state/stderr")"
grep -q "reaped 1 orphan volume" "$state/stderr" || fail "the sweep miscounted its frees: $(cat "$state/stderr")"

printf 'inventory-volume-free: ok\n'
