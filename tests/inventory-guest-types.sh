#!/usr/bin/env bash
# VMIDs are shared by VMs and containers on every node. vm_config_path only
# looked for qemu-server configs, so reserve_vmid handed a container's VMID to
# qm clone and the 30 s orphan sweep freed a container's LVM-thin disks, which
# are named vm-<ctid>-disk-N like a VM's. MIN_VMID=0 ("auto") also removed the
# sweep's lower bound, putting every guest on the storage in range.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'inventory-guest-types: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'inventory-guest-types: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
cd "$state"
PVE_NODES_DIR=$state/nodes
VMID_RESERVATION_LOCK_PREFIX=$state/reserve
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
TEMPLATE_ID=9000
VM_STORAGE=local-lvm

add_config() {
    mkdir -p "$PVE_NODES_DIR/$1/$2"
    : > "$PVE_NODES_DIR/$1/$2/$3.conf"
}
add_config pve1 qemu-server 9000 # the template
add_config pve1 qemu-server 9001 # a runner
add_config pve1 lxc 105          # a container below the runner range
add_config pve1 lxc 9002         # a container inside the runner range
add_config pve2 lxc 9050         # a container on another node
add_config pve2 qemu-server 9060 # a VM on another node

[[ "$(vm_config_path 105)" == "$PVE_NODES_DIR/pve1/lxc/105.conf" ]] || fail "a container config was not found"
[[ "$(vm_config_path 9001)" == "$PVE_NODES_DIR/pve1/qemu-server/9001.conf" ]] || fail "a VM config was not found"
for id in 9001 9002 9050 9060; do
    vmid_in_use "$id" || fail "VMID $id has a guest config but looked free"
done
if vmid_in_use 9003; then fail "free VMID 9003 looked in use"; fi
if vm_config_path 9003 >/dev/null; then fail "vm_config_path succeeded for a free VMID"; fi

# 9001 is a VM and 9002 a container, so the first free VMID is 9003.
flock() { return 0; }
MIN_VMID=9001
reserve_vmid
[[ "$RESERVED_VMID" == 9003 ]] || fail "reserve_vmid picked VMID $RESERVED_VMID"
release_vmid_reservation

# Like Proxmox, a volume whose VMID belongs to a container is rootdir content
# and every other volume is images. Freed volumes leave the listing.
mock_freed=$state/freed
mock_list_args=$state/list-args
: > "$mock_freed"
mock_volumes=(
    vm-105-disk-0 vm-150-disk-0 base-9000-disk-0 vm-9000-cloudinit
    base-9000-disk-0/vm-9001-disk-0 vm-9001-cloudinit vm-9002-disk-0 vm-9002-disk-1
    vm-9005-disk-0 vm-9005-cloudinit vm-9050-disk-0 base-9000-disk-0/vm-9060-disk-0
)
pvesm() {
    local volume id content
    case "$1" in
        list)
            printf '%s\n' "$*" >> "$mock_list_args"
            printf 'Volid Format Type Size VMID\n'
            for volume in "${mock_volumes[@]}"; do
                grep -qxF "$2:$volume" "$mock_freed" && continue
                [[ "${volume##*/}" =~ ^(vm|base)-([0-9]+)- ]] || return 1
                id=${BASH_REMATCH[2]}
                content=images
                compgen -G "$PVE_NODES_DIR/*/lxc/$id.conf" >/dev/null && content=rootdir
                [[ "$*" != *"--content images"* || "$content" == images ]] || continue
                printf '%s:%s raw %s 1 %s\n' "$2" "$volume" "$content" "$id"
            done
            ;;
        free) printf '%s\n' "$2" >> "$mock_freed" ;;
        *) return 1 ;;
    esac
}

sweep_frees() {
    : > "$mock_freed"
    : > "$mock_list_args"
    MIN_VMID=$1
    cleanup_runner_orphan_volumes 2>/dev/null
    [[ "$(sort "$mock_freed" | tr '\n' ' ')" == "$2" ]] ||
        fail "MIN_VMID='$1': the sweep freed '$(sort "$mock_freed" | tr '\n' ' ')', expected '$2'"
    grep -q -- '--content images' "$mock_list_args" ||
        fail "the sweep listed $VM_STORAGE without --content images: $(cat "$mock_list_args")"
}

runner_orphans='local-lvm:vm-9005-cloudinit local-lvm:vm-9005-disk-0 '
# 0 means "auto". The floor is then TEMPLATE_ID + 1, so VM 150's volume stays.
sweep_frees 0 "$runner_orphans"
sweep_frees "" "$runner_orphans"
sweep_frees garbage "$runner_orphans"
# A MIN_VMID the operator set is the runner range, even below the template.
sweep_frees 100 "local-lvm:vm-150-disk-0 $runner_orphans"
sweep_frees 9001 "$runner_orphans"

printf 'inventory-guest-types: ok\n'
