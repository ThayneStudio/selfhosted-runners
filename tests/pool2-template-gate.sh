#!/usr/bin/env bash
# A reclone must not clone from TEMPLATE_ID while that VM is not a finished
# template. Recreating the template at the same VMID (`qm destroy` and
# `runner setup`, which LVM-thin allows while linked clones run) leaves a
# plain VM there for the whole bake: a clone of it is a full copy, with no
# disk before the bake attaches one, and its lock can fail the bake. The dead
# VM still goes, the slot stays empty without counting a failure, and the
# watcher fills it once the template is converted.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool2-template-gate: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# reclone.sh sources these too; naming them lets shellcheck follow them.
# template_is_converted must come from reclone.sh's own source of bake.sh.
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
# shellcheck source=../lib/reclone.sh
source "$root/lib/reclone.sh"
fail() { printf 'pool2-template-gate: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

CONFIG_FILE=$state/github-runners.conf
ORG_CONFIG_DIR=$state/orgs
SNIPPETS_DIR=$state/snippets
POOL_DRAIN_FILE=$state/drain
LEGACY_POOL_DRAIN_FILE=$state/legacy-drain
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
SLOT_STATE_DIR=$state/slots
SLOT_LOCK_PREFIX=$state/slot
mkdir -p "$ORG_CONFIG_DIR" "$SNIPPETS_DIR" "$state/vm"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-lvm\nTEMPLATE_ID=9000\n' > "$CONFIG_FILE"
printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="runner"\nRUNNER_COUNT="1"\n' > "$ORG_CONFIG_DIR/acme.conf"
actions=$state/actions

clock=1000000
date() {
    if [[ "${1:-}" == "+%s" ]]; then
        printf '%s\n' "$clock"
    else
        command date "$@"
    fi
}
# Every runner here ran a long job, so no death counts toward the backoff.
file_mtime() { [[ -e "$1" ]] && printf '%s\n' "$((clock - 3600))"; }

# Config of VM 9000; empty while no VM exists there.
template_config=""
make_vm() {
    mkdir -p "$state/vm/9001"
    printf 'runner-1\n' > "$state/vm/9001/name"
    : > "$SNIPPETS_DIR/runner-9001-meta.yaml"
    : > "$SNIPPETS_DIR/runner-9001-user-acme.yaml"
}
qm() {
    local dir="$state/vm/${2:-none}"
    case "$1" in
        config)
            if [[ "$2" == 9000 ]]; then
                [[ -n "$template_config" ]] || return 2
                printf '%s\n' "$template_config"
                return 0
            fi
            [[ -d "$dir" ]] || return 2
            printf 'name: %s\ndescription: selfhosted-runners org=acme kind=slot\n' "$(cat "$dir/name")"
            printf 'cicustom: user=local:snippets/runner-%s-user-acme.yaml,meta=local:snippets/runner-%s-meta.yaml\n' "$2" "$2"
            ;;
        status)
            [[ -d "$dir" ]] || return 2
            printf 'status: stopped\n'
            ;;
        destroy)
            printf 'destroy %s\n' "$2" >> "$actions"
            rm -rf "$dir"
            ;;
        list)
            printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
            local d
            for d in "$state"/vm/*; do
                [[ -d "$d" ]] || continue
                printf '%10s %-20s %-10s 8192 30.00 0\n' "${d##*/}" "$(cat "$d/name")" stopped
            done
            ;;
        *) return 1 ;;
    esac
}
flock() { :; }
sleep() { :; }
logger() { :; }
# The real clone_runner mints a JIT runner on GitHub, then runs `qm clone`.
clone_runner() {
    printf 'clone %s %s\n' "$1" "$2" >> "$actions"
    CLONE_MINT_CONFLICT=0
}

run_reclone() {
    : > "$actions"
    make_vm
    set +e
    ( set -e; reclone_main 9001 ) > "$state/out" 2>&1
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$1: reclone failed (rc=$rc): $(tail -n 3 "$state/out")"
}

# expect_gated <case>: the dead VM is destroyed, nothing is minted or cloned,
# and the slot is neither failed nor held.
expect_gated() {
    run_reclone "$1"
    [[ "$(cat "$actions")" == "destroy 9001" ]] || fail "$1: unexpected actions: $(tr '\n' ' ' < "$actions")"
    grep -q 'template 9000 is not a finished template; leaving runner-1 empty for the watcher' "$state/out" \
        || fail "$1: the skipped refill was not logged"
    slot_state_load runner-1
    [[ "$SLOT_FAILURES" == 0 && "$SLOT_HOLD_UNTIL" == 0 ]] \
        || fail "$1: the skipped refill counted as a failed clone (failures=$SLOT_FAILURES hold_until=$SLOT_HOLD_UNTIL)"
}

# `qm destroy 9000` ran, and setup has not created the bake VM yet.
template_config=""
expect_gated "no VM at TEMPLATE_ID"

# The bake VM exists before its disk is imported and attached.
template_config=$'name: ubuntu-cloud-template\nmemory: 8192\nide2: local-lvm:vm-9000-cloudinit,media=cdrom'
expect_gated "bake VM without a disk"

# The bake VM runs the template setup.
template_config=$'name: ubuntu-cloud-template\nide2: local-lvm:vm-9000-cloudinit,media=cdrom\nscsi0: local-lvm:vm-9000-disk-0,size=30G'
expect_gated "bake VM still running its setup"

# `qm template` wrote the flag but has not converted the disk.
template_config=$'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local-lvm:vm-9000-disk-0,size=30G'
expect_gated "template flag without a converted disk"

# The finished template is cloned from again.
template_config=$'name: ubuntu-cloud-template\ntemplate: 1\nide2: local-lvm:vm-9000-cloudinit,media=cdrom\nscsi0: local-lvm:base-9000-disk-0,size=30G'
run_reclone "finished template"
[[ "$(cat "$actions")" == $'destroy 9001\nclone runner-1 acme' ]] \
    || fail "a reclone did not clone from the finished template: $(tr '\n' ' ' < "$actions")"

printf 'pool2-template-gate: ok\n'
