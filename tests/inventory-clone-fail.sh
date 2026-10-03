#!/usr/bin/env bash
# clone_runner's _fail may free volumes only at a VMID this clone holds, and
# only once no guest config uses them. It read an empty `qm config` name as
# "nobody owns this VMID", so a container, or a VM with no name, that took the
# VMID lost its disks. It also freed our VM's disks after `qm destroy` failed
# (a vzdump lock), leaving a config with nothing behind it. And it passed
# --purge, which deletes the VMID from backup jobs.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'inventory-clone-fail: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'inventory-clone-fail: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
cd "$state"
PVE_NODES_DIR=$state/nodes
SNIPPETS_DIR=$state/snippets
INSTALL_DIR=$root
POOL_DRAIN_FILE=$state/drain
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
VMID_LOCK_FILE=$state/vmid.lock
VMID_RESERVATION_LOCK_PREFIX=$state/reserve
CLONE_SLOT_LOCK_PREFIX=$state/slot
TEMPLATE_ID=9000
VM_STORAGE=local-lvm
MIN_VMID=9001
GITHUB_ORG=acme
GITHUB_PAT=test-pat
mkdir -p "$SNIPPETS_DIR" "$PVE_NODES_DIR/pve1/qemu-server" "$PVE_NODES_DIR/pve1/lxc"
: > "$PVE_NODES_DIR/pve1/qemu-server/9000.conf"

fetch_jit_config() { printf 'jit-token'; }
flock() { return 0; }

# Mocks read only mock_* variables, which no lib function declares locally.
mock_storage=$state/storage
mock_freed=$state/freed
mock_calls=$state/calls
mock_list_args=$state/list-args
mock_clone=ok
mock_set=ok
mock_destroy=ok
mock_free=ok
mock_list_hook=""
vm_conf() { printf '%s/pve1/qemu-server/%s.conf' "$PVE_NODES_DIR" "$1"; }
ct_conf() { printf '%s/pve1/lxc/%s.conf' "$PVE_NODES_DIR" "$1"; }

qm() {
    printf 'qm %s\n' "$*" >> "$mock_calls"
    case "$1" in
        config)
            if [[ ! -f "$(vm_conf "$2")" ]]; then
                printf "Configuration file 'nodes/pve1/qemu-server/%s.conf' does not exist\n" "$2" >&2
                return 2
            fi
            cat "$(vm_conf "$2")"
            ;;
        clone)
            case "$mock_clone" in
                ok)
                    printf 'name: %s\nnet0: virtio=02:00:00:00:00:01,bridge=vmbr0\nide2: %s:vm-%s-cloudinit,media=cdrom\nscsi0: %s:base-9000-disk-0/vm-%s-disk-0,size=30G\n' \
                        "$5" "$VM_STORAGE" "$3" "$VM_STORAGE" "$3" > "$(vm_conf "$3")"
                    printf 'base-9000-disk-0/vm-%s-disk-0\nvm-%s-cloudinit\n' "$3" "$3" >> "$mock_storage"
                    ;;
                container)
                    # A container takes the VMID after reserve_vmid checked it.
                    printf 'rootfs: %s:vm-%s-disk-0,size=8G\n' "$VM_STORAGE" "$3" > "$(ct_conf "$3")"
                    printf 'vm-%s-disk-0\n' "$3" >> "$mock_storage"
                    printf 'unable to create VM %s: config file already exists\n' "$3" >&2
                    return 255
                    ;;
                unnamed)
                    # So does a VM created without a name.
                    printf 'scsi0: %s:vm-%s-disk-0,size=8G\n' "$VM_STORAGE" "$3" > "$(vm_conf "$3")"
                    printf 'vm-%s-disk-0\n' "$3" >> "$mock_storage"
                    printf 'unable to create VM %s: config file already exists\n' "$3" >&2
                    return 255
                    ;;
                residue)
                    # The clone died after allocating a disk and before its config.
                    printf 'vm-%s-disk-0\n' "$3" >> "$mock_storage"
                    printf 'clone failed: storage error\n' >&2
                    return 255
                    ;;
            esac
            ;;
        set)
            if [[ "$mock_set" == locked && "$3" == --net0 ]]; then
                printf 'VM is locked (backup)\n' >&2
                return 255
            fi
            ;;
        destroy)
            case "$mock_destroy" in
                locked)
                    printf 'VM is locked (backup)\n' >&2
                    return 255
                    ;;
                ok | residue)
                    rm -f "$(vm_conf "$2")"
                    grep -vxF "base-9000-disk-0/vm-$2-disk-0" "$mock_storage" > "$mock_storage.new" || true
                    if [[ "$mock_destroy" == ok ]]; then
                        grep -vxF "vm-$2-cloudinit" "$mock_storage.new" > "$mock_storage" || true
                        rm -f "$mock_storage.new"
                    else
                        # A busy dataset survives the destroy.
                        mv "$mock_storage.new" "$mock_storage"
                    fi
                    ;;
            esac
            ;;
        start) return 0 ;;
        *) return 1 ;;
    esac
}

# Like Proxmox, a volume whose VMID belongs to a container is rootdir content
# and every other volume is images.
pvesm() {
    local volume id content
    case "$1" in
        list)
            printf '%s\n' "$*" >> "$mock_list_args"
            printf 'Volid Format Type Size VMID\n'
            while read -r volume; do
                [[ -n "$volume" ]] || continue
                [[ "${volume##*/}" =~ ^(vm|base)-([0-9]+)- ]] || return 1
                id=${BASH_REMATCH[2]}
                content=images
                [[ ! -e "$(ct_conf "$id")" ]] || content=rootdir
                [[ "$*" != *"--content images"* || "$content" == images ]] || continue
                printf '%s:%s raw %s 1 %s\n' "$2" "$volume" "$content" "$id"
            done < "$mock_storage"
            if [[ "$mock_list_hook" == parallel-clone ]]; then
                # Another worker reserves the freed VMID and writes its config
                # right after this listing was taken.
                printf 'name: runner-2\nlock: clone\n' > "$(vm_conf 9001)"
            fi
            ;;
        free)
            printf '%s\n' "$2" >> "$mock_freed"
            if [[ "$mock_free" == busy ]]; then
                # The real CLI exits 0 when its deletion task fails.
                printf "cannot destroy '%s': dataset is busy\n" "${2#*:}" >&2
                return 0
            fi
            grep -vxF "${2#*:}" "$mock_storage" > "$mock_storage.new" || true
            mv "$mock_storage.new" "$mock_storage"
            ;;
        *) return 1 ;;
    esac
}

errlog=$state/stderr
reset() {
    rm -f "$(vm_conf 9001)" "$(ct_conf 9001)" "$VMID_RESERVATION_LOCK_PREFIX"-*
    printf 'base-9000-disk-0\n' > "$mock_storage"
    : > "$mock_freed"
    : > "$mock_calls"
    : > "$mock_list_args"
    mock_clone=ok
    mock_set=ok
    mock_destroy=ok
    mock_free=ok
    mock_list_hook=""
}
run_failing_clone() {
    if clone_runner runner-1 acme >/dev/null 2>"$errlog"; then
        fail "$1: clone_runner reported success"
    fi
}
freed() { sort "$mock_freed" | tr '\n' ' '; }
stored() { grep -qxF "$1" "$mock_storage"; }
logged() { grep -qF "$1" "$errlog"; }

# A vzdump lock makes qm set and then qm destroy fail. The config still uses
# both volumes, so nothing may be freed.
reset
mock_set=locked
mock_destroy=locked
run_failing_clone "locked VM"
[[ -z "$(freed)" ]] || fail "locked VM: freed $(freed) under a live config"
stored "base-9000-disk-0/vm-9001-disk-0" || fail "locked VM: its disk is gone"
stored "vm-9001-cloudinit" || fail "locked VM: its cloud-init volume is gone"
[[ -f "$(vm_conf 9001)" ]] || fail "locked VM: its config is gone"
grep -qx 'qm destroy 9001' "$mock_calls" || fail "locked VM: qm destroy was not called as 'qm destroy 9001': $(grep destroy "$mock_calls" || true)"
logged "qm destroy 9001 failed: VM is locked (backup)" || fail "locked VM: the destroy failure was not logged: $(cat "$errlog")"

# Once the destroy removed the config, a busy volume it left is freed.
reset
mock_set=locked
mock_destroy=residue
run_failing_clone "destroy residue"
[[ "$(freed)" == "local-lvm:vm-9001-cloudinit " ]] || fail "destroy residue: freed '$(freed)'"
grep -qx 'qm destroy 9001' "$mock_calls" || fail "destroy residue: qm destroy was not called as 'qm destroy 9001'"
grep -q -- '--content images' "$mock_list_args" || fail "_fail listed $VM_STORAGE without --content images"

# A residue volume that survives its free has to be reported.
reset
mock_set=locked
mock_destroy=residue
mock_free=busy
run_failing_clone "busy residue"
logged "Failed to free orphan volume local-lvm:vm-9001-cloudinit" ||
    fail "busy residue: a volume that was not freed was not reported: $(cat "$errlog")"

# A parallel clone that takes the VMID after the listing keeps its volumes.
reset
mock_set=locked
mock_destroy=residue
mock_list_hook=parallel-clone
run_failing_clone "parallel clone"
[[ -z "$(freed)" ]] || fail "parallel clone: freed $(freed) after another worker took VMID 9001"

# A container that took the reserved VMID is not ours.
reset
mock_clone=container
run_failing_clone "container"
[[ -z "$(freed)" ]] || fail "container: freed $(freed)"
stored "vm-9001-disk-0" || fail "container: its disk is gone"
if grep -q '^qm destroy' "$mock_calls"; then fail "container: qm destroy was called"; fi
logged "VMID 9001 belongs to another guest" || fail "container: the collision was not logged: $(cat "$errlog")"

# Nor is a VM without a name.
reset
mock_clone=unnamed
run_failing_clone "unnamed VM"
[[ -z "$(freed)" ]] || fail "unnamed VM: freed $(freed)"
stored "vm-9001-disk-0" || fail "unnamed VM: its disk is gone"
if grep -q '^qm destroy' "$mock_calls"; then fail "unnamed VM: qm destroy was called"; fi

# A clone that died before writing its config leaves a volume nobody owns.
reset
mock_clone=residue
run_failing_clone "clone residue"
[[ "$(freed)" == "local-lvm:vm-9001-disk-0 " ]] || fail "clone residue: freed '$(freed)'"

printf 'inventory-clone-fail: ok\n'
