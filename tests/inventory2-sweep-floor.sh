#!/usr/bin/env bash
# With MIN_VMID=0 runners take the cluster's next free VMIDs, below a template
# at 9000, but the watcher's orphan sweep starts at TEMPLATE_ID + 1. A runner
# disk that qm destroy could not free (a busy zvol) stayed for good, and as a
# linked clone it kept its template from ever being retired. Below the floor
# the sweep now frees a config-less volume only when the listing shows it as
# a linked clone of the live template or of a retired one that is still a
# runner template; any other volume there is left alone.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'inventory2-sweep-floor: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'inventory2-sweep-floor: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
cd "$state"
PVE_NODES_DIR=$state/nodes
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
RETIRED_TEMPLATES_FILE=$state/retired-templates
VM_STORAGE=local-zfs
MIN_VMID=0
flock() { return 0; }

add_config() {
    mkdir -p "$PVE_NODES_DIR/$1/$2"
    : > "$PVE_NODES_DIR/$1/$2/$3.conf"
}
add_config pve1 qemu-server 9000 # the template until the rebake below
add_config pve1 qemu-server 8000 # a retired runner template
add_config pve1 qemu-server 7000 # a retired id that now holds another template
add_config pve1 qemu-server 5000 # the operator's template, named like ours
add_config pve1 qemu-server 104  # a runner
add_config pve2 qemu-server 110  # a runner on another node
add_config pve1 qemu-server 107  # the rebake's new template

# Mocks read only mock_* variables, which no lib function declares locally.
mock_qm_calls=$state/qm-calls
mock_volumes=$state/volumes
mock_freed=$state/freed
qm() {
    [[ "$1" == config ]] || return 1
    printf '%s\n' "$2" >> "$mock_qm_calls"
    case "$2" in
        9000 | 8000 | 107) printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1\n' "$2" ;;
        7000) printf 'name: win2022\nscsi0: local-zfs:base-7000-disk-0,size=60G\ntemplate: 1\n' ;;
        5000) printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:base-5000-disk-0,size=30G\ntemplate: 1\n' ;;
        *) return 2 ;;
    esac
}
pvesm() {
    local volume
    case "$1" in
        list)
            printf 'Volid Format Type Size VMID\n'
            while read -r volume; do
                grep -qxF "local-zfs:$volume" "$mock_freed" && continue
                printf 'local-zfs:%s raw images 1 0\n' "$volume"
            done < "$mock_volumes"
            ;;
        free) printf '%s\n' "$2" >> "$mock_freed" ;;
        *) return 1 ;;
    esac
}

# Runs one sweep over the volumes given and checks what it freed.
sweep_frees() {
    local expected="$1"
    shift
    printf '%s\n' "$@" > "$mock_volumes"
    : > "$mock_freed"
    : > "$mock_qm_calls"
    cleanup_runner_orphan_volumes 2>/dev/null
    [[ "$(sort "$mock_freed" | tr '\n' ' ')" == "$expected" ]] ||
        fail "TEMPLATE_ID=$TEMPLATE_ID: the sweep freed '$(sort "$mock_freed" | tr '\n' ' ')', expected '$expected'"
}

printf '%s\n' 8000 7000 6000 garbage > "$RETIRED_TEMPLATES_FILE"
TEMPLATE_ID=9000
# Freed: the leftover runner disk of VM 105, a leftover clone of retired
# template 8000, and an orphan above the floor. Kept: the volumes of runners
# 104 and 110, the cloud-init leftover of VM 105 (nothing ties a flat volume
# to a runner), a flat orphan, clones of the operator's template 5000 and of
# 7000, which the rebake still lists but which is no runner template.
sweep_frees 'local-zfs:base-8000-disk-0/vm-106-disk-0 local-zfs:base-9000-disk-0/vm-105-disk-0 local-zfs:vm-9005-disk-0 ' \
    base-9000-disk-0 vm-9000-cloudinit \
    base-9000-disk-0/vm-104-disk-0 vm-104-cloudinit \
    base-9000-disk-0/vm-105-disk-0 vm-105-cloudinit \
    base-8000-disk-0 base-8000-disk-0/vm-106-disk-0 \
    base-7000-disk-0 base-7000-disk-0/vm-108-disk-0 \
    base-5000-disk-0 base-5000-disk-0/vm-109-disk-0 \
    base-9000-disk-0/vm-110-disk-0 vm-150-disk-0 vm-9005-disk-0

# Without a retired list only the live template's clones count.
rm -f "$RETIRED_TEMPLATES_FILE"
sweep_frees 'local-zfs:base-9000-disk-0/vm-105-disk-0 ' \
    base-9000-disk-0 base-9000-disk-0/vm-105-disk-0 \
    base-8000-disk-0 base-8000-disk-0/vm-106-disk-0

# A rebake moved the template to the next free VMID, 107, and retired 9000.
# The floor is now 108, and VM 105's leftover still blocks 9000's retirement.
printf '9000\n' > "$RETIRED_TEMPLATES_FILE"
TEMPLATE_ID=107
sweep_frees 'local-zfs:base-9000-disk-0/vm-105-disk-0 ' \
    base-107-disk-0 vm-107-cloudinit \
    base-107-disk-0/vm-104-disk-0 vm-104-cloudinit \
    base-9000-disk-0 vm-9000-cloudinit base-9000-disk-0/vm-105-disk-0

# A tick with nothing to free below the floor reads no template config.
sweep_frees '' \
    base-107-disk-0 base-107-disk-0/vm-104-disk-0 vm-104-cloudinit \
    base-9000-disk-0 vm-100-disk-0
[[ ! -s "$mock_qm_calls" ]] || fail "a sweep with no candidate below the floor read template configs: $(tr '\n' ' ' < "$mock_qm_calls")"

printf 'inventory2-sweep-floor: ok\n'
