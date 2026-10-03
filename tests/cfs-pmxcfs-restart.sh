#!/usr/bin/env bash
# pmxcfs serves /etc/pve, and every pve-cluster upgrade restarts it. While it
# restarts /etc/pve is an empty directory (unreadable after a crash), and the
# config glob finds no guest at all. The watcher's orphan sweep, runner
# stop's template cleanup and clone_runner's _fail took that as proof that a
# VMID had no config, so a stopped VM in the swept range lost its disk. A
# lookup now counts only when pmxcfs listed the node directories both before
# and after it, and the freeing stops when it did not.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'cfs-pmxcfs-restart: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'cfs-pmxcfs-restart: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
cd "$state"

# $cfs stands for /etc/pve.
cfs=$state/pve
PVE_NODES_DIR=$cfs/nodes
SNIPPETS_DIR=$state/snippets
INSTALL_DIR=$root
POOL_DRAIN_FILE=$state/drain
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
VMID_LOCK_FILE=$state/vmid.lock
VMID_RESERVATION_LOCK_PREFIX=$state/reserve
CLONE_SLOT_LOCK_PREFIX=$state/slot
TEMPLATE_ID=9000
MIN_VMID=9001
VM_STORAGE=local-lvm
GITHUB_ORG=acme
GITHUB_PAT=test-pat
mkdir -p "$SNIPPETS_DIR" "$PVE_NODES_DIR/pve1/qemu-server"
ln -s nodes/pve1 "$cfs/local"
vm_conf() { printf '%s/pve1/qemu-server/%s.conf' "$PVE_NODES_DIR" "$1"; }
printf 'name: ubuntu-cloud-template\nscsi0: local-lvm:base-9000-disk-0,size=30G\ntemplate: 1\n' > "$(vm_conf 9000)"
# A runner VM, and the operator's stopped VM in the swept range.
printf 'name: runner-2\nscsi0: local-lvm:base-9000-disk-0/vm-9002-disk-0,size=30G\n' > "$(vm_conf 9002)"
printf 'name: db01\nscsi0: local-lvm:vm-9050-disk-0,size=64G\n' > "$(vm_conf 9050)"

# pmxcfs stops: /etc/pve is an empty directory until it mounts again.
pmxcfs_stop() {
    [[ ! -d "$state/pve.away" ]] || return 0
    mv "$cfs" "$state/pve.away"
    mkdir "$cfs"
}
# pmxcfs crashes: nothing in /etc/pve can be listed or read any more, but
# the kernel still answers a lookup of /etc/pve/local from its cache.
pmxcfs_crash() {
    [[ -d "$cfs/nodes" ]] || return 0
    mv "$cfs/nodes" "$state/nodes.away"
}
pmxcfs_start() {
    if [[ -d "$state/pve.away" ]]; then
        rmdir "$cfs"
        mv "$state/pve.away" "$cfs"
    fi
    if [[ -d "$state/nodes.away" ]]; then
        mv "$state/nodes.away" "$cfs/nodes"
    fi
}

fetch_jit_config() { printf 'jit-token'; }
generate_mac() { printf '02:00:00:00:00:01\n'; }
flock() { return 0; }

# Mocks read only mock_* variables, which no lib function declares locally.
mock_storage=$state/storage
mock_freed=$state/freed
# Holds stop or crash: pmxcfs does that as the next listing is taken.
mock_list_hook=$state/list-hook
# Holds stop or start: pmxcfs does that while the next config glob runs.
mock_lookup_hook=$state/lookup-hook

# qm reads configs from pmxcfs over IPC, which waits out a restart, so it
# sees them while /etc/pve is not mounted too. A backup lock makes qm set and
# qm destroy fail.
qm_conf() {
    if [[ -d "$state/pve.away" ]]; then
        printf '%s/nodes/pve1/qemu-server/%s.conf' "$state/pve.away" "$1"
    else
        vm_conf "$1"
    fi
}
qm() {
    case "$1" in
        config)
            [[ -f "$(qm_conf "$2")" ]] || return 2
            cat "$(qm_conf "$2")"
            ;;
        clone)
            printf 'name: %s\nnet0: virtio=02:00:00:00:00:01,bridge=vmbr0\nscsi0: %s:base-9000-disk-0/vm-%s-disk-0,size=30G\n' \
                "$5" "$VM_STORAGE" "$3" > "$(qm_conf "$3")"
            printf 'base-9000-disk-0/vm-%s-disk-0\nvm-%s-cloudinit\n' "$3" "$3" >> "$mock_storage"
            ;;
        set | destroy)
            printf 'VM is locked (backup)\n' >&2
            return 255
            ;;
        *) return 1 ;;
    esac
}
pvesm() {
    local volume hook
    case "$1" in
        list)
            if [[ -e "$mock_list_hook" ]]; then
                hook=$(cat "$mock_list_hook")
                rm -f "$mock_list_hook"
                "pmxcfs_$hook"
            fi
            printf 'Volid Format Type Size VMID\n'
            while read -r volume; do
                printf '%s:%s raw images 1 0\n' "$2" "$volume"
            done < "$mock_storage"
            ;;
        free)
            printf '%s\n' "$2" >> "$mock_freed"
            grep -vxF "${2#*:}" "$mock_storage" > "$mock_storage.new" || true
            mv "$mock_storage.new" "$mock_storage"
            ;;
        path) printf '/dev/pve/%s\n' "${2#*:}" ;;
        *) return 1 ;;
    esac
}
eval "real_$(declare -f vm_config_path)"
vm_config_path() {
    local hook="" rc=0
    if [[ -e "$mock_lookup_hook" ]]; then
        hook=$(cat "$mock_lookup_hook")
        rm -f "$mock_lookup_hook"
    fi
    [[ "$hook" != stop ]] || pmxcfs_stop
    real_vm_config_path "$1" || rc=$?
    [[ "$hook" != start ]] || pmxcfs_start
    return "$rc"
}

errlog=$state/stderr
freed() { sort "$mock_freed" | tr '\n' ' '; }
warnings() { grep -c 'pmxcfs is not serving /etc/pve' "$errlog" || true; }

# The lookup the freeing callers use.
[[ "$(vm_config_path_checked 9050)" == "$(vm_conf 9050)" ]] || fail "VM 9050's config was not found"
[[ -z "$(vm_config_path_checked 9060)" ]] || fail "free VMID 9060 has a config"
vm_config_path_checked 9060 > /dev/null || fail "a lookup while pmxcfs serves /etc/pve failed"
for hook in stop crash; do
    "pmxcfs_$hook"
    if vm_config_path_checked 9050 > /dev/null; then fail "a lookup after pmxcfs_$hook succeeded"; fi
    pmxcfs_start
done

# The watcher's sweep. VM 9050 has a config, 9060 is an orphan.
sweep() {
    printf '%s\n' base-9000-disk-0 vm-9050-disk-0 vm-9060-disk-0 base-9000-disk-0/vm-9002-disk-0 > "$mock_storage"
    : > "$mock_freed"
    cleanup_runner_orphan_volumes 2> "$errlog"
    pmxcfs_start
    rm -f "$mock_list_hook" "$mock_lookup_hook"
}
sweep
[[ "$(freed)" == "local-lvm:vm-9060-disk-0 " ]] || fail "with pmxcfs up the sweep freed '$(freed)'"
[[ "$(warnings)" == 0 ]] || fail "with pmxcfs up the sweep warned: $(cat "$errlog")"

# pmxcfs stops, or crashes, once the listing is taken: no config shows for
# VM 9050.
for hook in stop crash; do
    printf '%s\n' "$hook" > "$mock_list_hook"
    sweep
    [[ -z "$(freed)" ]] || fail "pmxcfs_$hook: the sweep freed $(freed)"
    [[ "$(warnings)" == 1 ]] || fail "pmxcfs_$hook: the sweep did not warn once and stop: $(cat "$errlog")"
done

# It is up when the lookup starts and stops while the glob runs.
printf 'stop\n' > "$mock_lookup_hook"
sweep
[[ -z "$(freed)" ]] || fail "pmxcfs stopped during the lookup: the sweep freed $(freed)"
[[ "$(warnings)" == 1 ]] || fail "pmxcfs stopped during the lookup: the sweep did not warn once and stop: $(cat "$errlog")"

# It is down when the lookup starts and back once the glob has run.
printf 'stop\n' > "$mock_list_hook"
printf 'start\n' > "$mock_lookup_hook"
sweep
[[ -z "$(freed)" ]] || fail "pmxcfs back during the lookup: the sweep freed $(freed)"
[[ "$(warnings)" == 1 ]] || fail "pmxcfs back during the lookup: the sweep did not warn once and stop: $(cat "$errlog")"

# runner stop's cleanup of the template's linked clones. Runner VM 9002 has
# a config, 9005 is an orphan.
template_cleanup() {
    printf '%s\n' base-9000-disk-0 base-9000-disk-0/vm-9002-disk-0 base-9000-disk-0/vm-9005-disk-0 > "$mock_storage"
    : > "$mock_freed"
    cleanup_rc=0
    cleanup_template_orphan_volumes 2> "$errlog" || cleanup_rc=$?
    pmxcfs_start
}
template_cleanup
[[ "$cleanup_rc" == 2 ]] || fail "with pmxcfs up the template cleanup returned $cleanup_rc, not 2 (blocked by VM 9002)"
[[ "$(freed)" == "local-lvm:base-9000-disk-0/vm-9005-disk-0 " ]] || fail "with pmxcfs up the template cleanup freed '$(freed)'"
printf 'stop\n' > "$mock_list_hook"
template_cleanup
[[ "$cleanup_rc" == 1 ]] || fail "pmxcfs down: the template cleanup returned $cleanup_rc, not 1"
[[ -z "$(freed)" ]] || fail "pmxcfs down: the template cleanup freed $(freed)"
grep -qF "run 'runner stop' again" "$errlog" || fail "pmxcfs down: the template cleanup did not say what to do: $(cat "$errlog")"

# clone_runner: a backup lock refused qm set and then qm destroy, so VM
# 9001's config still uses both volumes when _fail lists them, and pmxcfs
# stops as it does.
printf 'base-9000-disk-0\n' > "$mock_storage"
: > "$mock_freed"
printf 'stop\n' > "$mock_list_hook"
if clone_runner runner-1 acme > /dev/null 2> "$errlog"; then fail "clone_runner reported success"; fi
pmxcfs_start
[[ -f "$(vm_conf 9001)" ]] || fail "clone_runner: VM 9001's config is gone"
[[ -z "$(freed)" ]] || fail "clone_runner: _fail freed $(freed) under VM 9001's config while pmxcfs was down"
grep -qF 'pmxcfs is not serving /etc/pve; not freeing the volumes of VMID 9001' "$errlog" ||
    fail "clone_runner: _fail did not say why it kept the volumes: $(cat "$errlog")"

printf 'cfs-pmxcfs-restart: ok\n'
