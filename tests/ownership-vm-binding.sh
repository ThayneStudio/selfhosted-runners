#!/usr/bin/env bash
# Ownership must be bound to the VM's own VMID and to this tool's snippet
# paths. get_vm_org matched runner-<any vmid>-user-<x>.yaml or
# runner-user-data-<x>.yaml anywhere in cicustom, and a description marker
# that every full clone copies, so the watcher stopped and destroyed an
# operator's VM named runner-2 whose snippet was runner-2-user-data.yaml, a
# VM at a reused VMID whose snippet was gitlab-runner-user-data-prod.yaml,
# and a debugging clone of a runner VM. Removed orgs' own runners must still
# be reclaimed.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'ownership-vm-binding: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# watch.sh and reclone.sh source these too; naming them lets shellcheck follow them.
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
# shellcheck source=../lib/watch.sh
source "$root/lib/watch.sh"
# shellcheck source=../lib/reclone.sh
source "$root/lib/reclone.sh"
fail() { printf 'ownership-vm-binding: %s\n' "$1" >&2; exit 1; }
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
EXTRA_RUNNERS_FILE=$state/extras
EXTRA_RUNNERS_LOCK_FILE=$state/extras.lock
PVE_NODES_DIR=$state/nodes
mkdir -p "$ORG_CONFIG_DIR" "$SNIPPETS_DIR" "$state/vm"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=9000\n' > "$CONFIG_FILE"
printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="runner"\nRUNNER_COUNT="1"\n' > "$ORG_CONFIG_DIR/acme.conf"
actions=$state/actions

# What clone_runner gives VM $1 of org $2 (kind slot by default).
own_cicustom() { printf 'user=local:snippets/runner-%s-user-%s.yaml,meta=local:snippets/runner-%s-meta.yaml' "$1" "$2" "$1"; }
own_marker() { printf 'selfhosted-runners org=%s kind=%s vmid=%s' "$2" "${3:-slot}" "$1"; }

# --- get_vm_org: what counts as this tool's mark on VM 9001 ---
org_of() { get_vm_org 9001 "$1"; }
expect_org() {
    [[ "$(org_of "$2")" == "$1" ]] || fail "$3: got $(org_of "$2") for: $2"
}
expect_org acme "cicustom: $(own_cicustom 9001 acme)" "a runner's own snippets"
expect_org my-org "cicustom: meta=local:snippets/runner-9001-meta.yaml,user=local:snippets/runner-9001-user-my-org.yaml" \
    "the user snippet after another property"
expect_org unknown "cicustom: $(own_cicustom 301 acme)" "the snippets of runner 301 (a full clone of it)"
expect_org unknown 'cicustom: user=local:snippets/runner-2-user-data.yaml' "an operator's runner-2-user-data.yaml"
expect_org unknown 'cicustom: user=local:snippets/gitlab-runner-user-data-prod.yaml' "a name that ends like the legacy snippet"
expect_org unknown 'cicustom: user=local:snippets/myrunner-9001-user-acme.yaml' "a name that ends like a per-VM snippet"
expect_org unknown 'cicustom: user=nfs:snippets/runner-9001-user-acme.yaml' "a per-VM snippet name on another storage"
expect_org unknown 'cicustom: user=local:snippets/runner-9001-user-acme.yaml.bak' "a per-VM snippet name with a suffix"
expect_org unknown 'cicustom: vendor=local:snippets/runner-9001-user-acme.yaml' "a per-VM snippet name as vendor data"
expect_org legacy 'cicustom: user=local:snippets/runner-user-data-legacy.yaml,meta=local:snippets/runner-9001-meta.yaml' \
    "a legacy per-org snippet"
expect_org unknown 'cicustom: user=nfs:snippets/runner-user-data-legacy.yaml' "a legacy snippet name on another storage"
expect_org acme "description: $(own_marker 9001 acme)" "a clone cut off before --cicustom"
expect_org acme "description: selfhosted-runners org=acme vmid=9001" "a marker without a kind"
expect_org acme "description: $(own_marker 9001 acme extra)%0Aoperator note" "a marker the operator added a line to"
expect_org unknown "description: $(own_marker 301 acme)" "a marker copied from runner 301"
expect_org unknown "description: $(own_marker 90011 acme)" "a marker of VMID 90011"
expect_org unknown 'description: selfhosted-runners org=acme kind=slot' "a marker without a VMID"
[[ "$(get_vm_org '' "description: $(own_marker 9001 acme)")" == unknown ]] || fail "a VM without a VMID was managed"
[[ "$(runner_vm_kind "description: $(own_marker 9001 acme extra)")" == extra ]] \
    || fail "runner_vm_kind did not read the kind before the VMID"

# --- clone_runner writes the VMID it reserved into the marker ---
(
    INSTALL_DIR=$root
    VMID_LOCK_FILE=$state/vmid.lock
    VMID_RESERVATION_LOCK_PREFIX=$state/reserve
    CLONE_SLOT_LOCK_PREFIX=$state/clone-slot
    VM_STORAGE=local-zfs
    TEMPLATE_ID=9000
    MIN_VMID=9001
    GITHUB_ORG=acme
    GITHUB_PAT=ghp_test
    RUNNER_PREFIX=runner
    RUNNER_COUNT=1
    # 9001 is taken, so the clone gets 9002.
    mkdir -p "$PVE_NODES_DIR/pve1/qemu-server"
    : > "$PVE_NODES_DIR/pve1/qemu-server/9001.conf"
    flock() { :; }
    generate_mac() { printf '02:00:00:00:00:01\n'; }
    fetch_jit_config() { printf 'Zm9v\n'; }
    qm() {
        printf '%s\n' "$*" >> "$state/clone-calls"
        [[ "$1" != config ]] || printf 'name: runner-1\nnet0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0\n'
    }
    vmid=$(clone_runner runner-1 acme) || fail "clone_runner failed"
    [[ "$vmid" == 9002 ]] || fail "clone_runner used VMID $vmid"
) > "$state/clone-out" 2>&1 || fail "the clone check failed: $(tail -n 3 "$state/clone-out")"
grep -qx 'clone 9000 9002 --name runner-1 --description selfhosted-runners org=acme kind=slot vmid=9002' "$state/clone-calls" \
    || fail "the marker does not name the clone's VMID: $(grep '^clone' "$state/clone-calls")"

# --- The watcher, which acts with no operator in the loop ---
clock=2000000
date() {
    if [[ "${1:-}" == "+%s" ]]; then
        printf '%s\n' "$clock"
    else
        command date "$@"
    fi
}
# vm <vmid> <name> <status> [key=value ...]: uptime, cicustom, desc (the
# description), hookscript=1, meta=1 (a meta snippet for that VMID, written
# at born), born (default: now).
vm() {
    local dir="$state/vm/$1" kv
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/name"
    printf '%s\n' "$3" > "$dir/status"
    printf '0\n' > "$dir/uptime"
    printf '%s\n' "$clock" > "$dir/born"
    shift 3
    for kv in "$@"; do
        if [[ "$kv" == meta=1 ]]; then
            : > "$SNIPPETS_DIR/runner-${dir##*/}-meta.yaml"
        else
            printf '%s\n' "${kv#*=}" > "$dir/${kv%%=*}"
        fi
    done
}
# A runner of org $3 at VMID $1, as clone_runner made it, cloned an hour ago.
runner() { vm "$1" "$2" stopped cicustom="$(own_cicustom "$1" "$3")" desc="$(own_marker "$1" "$3")" meta=1 born=$((clock - 3600)); }
field() { cat "$state/vm/$1/$2" 2>/dev/null || true; }
gone() { [[ ! -d "$state/vm/$1" ]]; }
pvesh() {
    [[ "$*" == "get /nodes/localhost/qemu --output-format json" ]] || return 1
    local d id sep=""
    printf '['
    for d in "$state"/vm/*; do
        [[ -d "$d" ]] || continue
        id=${d##*/}
        printf '%s{"vmid":%s,"name":"%s","status":"%s","uptime":%s}' "$sep" "$id" "$(field "$id" name)" \
            "$(field "$id" status)" "$(field "$id" uptime)"
        sep=","
    done
    printf ']\n'
}
qm() {
    local id="${2:-}"
    case "$1" in
        config)
            if [[ "$id" == 9000 ]]; then
                printf 'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local-zfs:base-9000-disk-0,size=30G\n'
                return 0
            fi
            gone "$id" && return 2
            [[ -z "$(field "$id" desc)" ]] || printf 'description: %s\n' "$(field "$id" desc)"
            [[ -z "$(field "$id" cicustom)" ]] || printf 'cicustom: %s\n' "$(field "$id" cicustom)"
            [[ -z "$(field "$id" hookscript)" ]] || printf 'hookscript: local:snippets/runner-hookscript.sh\n'
            printf 'name: %s\n' "$(field "$id" name)"
            ;;
        status)
            gone "$id" && return 2
            printf 'status: %s\n' "$(field "$id" status)"
            [[ "${3:-}" != --verbose ]] || printf 'uptime: %s\n' "$(field "$id" uptime)"
            ;;
        stop)
            printf 'stop %s\n' "$id" >> "$actions"
            printf 'stopped\n' > "$state/vm/$id/status"
            ;;
        destroy)
            printf 'destroy %s\n' "$id" >> "$actions"
            rm -rf "$state/vm/$id"
            ;;
        list)
            printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
            local d
            for d in "$state"/vm/*; do
                [[ -d "$d" ]] || continue
                printf '%10s %-20s %-10s 8192 30.00 0\n' "${d##*/}" "$(field "${d##*/}" name)" "$(field "${d##*/}" status)"
            done
            ;;
        *) return 1 ;;
    esac
}
file_mtime() {
    local id="${1##*/runner-}"
    [[ -e "$1" ]] || return 1
    field "${id%-meta.yaml}" born
}
flock() { :; }
sleep() { :; }
logger() { printf '%s\n' "$*" >> "$state/logger"; }
require_root() { :; }
cleanup_runner_orphan_volumes() { :; }
clone_runner() {
    printf 'clone %s %s\n' "$1" "$2" >> "$actions"
    CLONE_MINT_CONFLICT=0
}

tick() {
    : > "$actions"
    set +e
    ( set -e; watch_main ) > "$state/out" 2>&1
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "watch_main failed (rc=$rc): $(tail -n 5 "$state/out")"
}
# Two ticks a grace period apart, with the actions and output of both: a
# running VM is reclaimed on the first, a stopped one on the second.
ticks() {
    tick
    cp "$actions" "$state/actions-1"
    cp "$state/out" "$state/out-1"
    clock=$((clock + 61))
    tick
    cat "$state/actions-1" "$actions" > "$state/actions-2"
    mv "$state/actions-2" "$actions"
    cat "$state/out-1" "$state/out" > "$state/out-2"
    mv "$state/out-2" "$state/out"
}
reset() {
    rm -rf "$state/vm" "$SNIPPETS_DIR" "$SLOT_STATE_DIR"
    mkdir -p "$state/vm" "$SNIPPETS_DIR"
    : > "$state/logger"
    # Slot runner-1 is healthy: a runner on its first boot.
    vm 9001 runner-1 running cicustom="$(own_cicustom 9001 acme)" desc="$(own_marker 9001 acme)" meta=1 \
        uptime=100 born=$((clock - 100))
}
touched() { grep -qE "^(stop|destroy) $1\$" "$actions"; }

# Case A: the operator's own stopped VM runner-2, whose cloud-init snippet
# follows the <vmname>-user-data.yaml convention. Slot-named, so reported.
reset
vm 300 runner-2 stopped cicustom='user=local:snippets/runner-2-user-data.yaml'
ticks
touched 300 && fail "the operator's VM runner-2 was stopped or destroyed: $(tr '\n' ' ' < "$actions")"
grep -q 'runner-2 (VMID 300) is stopped but carries no selfhosted-runners snippet or marker' "$state/out" \
    || fail "the operator's VM runner-2 was not reported: $(cat "$state/out")"

# Case B: a runner removed with plain `qm destroy` left its meta snippet, and
# the operator's VM builder took its VMID. It runs, so it looks restarted.
reset
vm 302 builder running cicustom='user=local:snippets/gitlab-runner-user-data-prod.yaml' meta=1 uptime=3600 \
    born=$((clock - 86400))
ticks
touched 302 && fail "the operator's VM builder was stopped or destroyed: $(tr '\n' ' ' < "$actions")"
[[ ! -e "$SNIPPETS_DIR/runner-302-meta.yaml" ]] || fail "the snippet left behind at VMID 302 was kept"

# The same VM with a snippet named exactly like this tool's legacy per-org
# one. get_vm_org reads an org from it, but that name is tied to no VMID, so
# the watcher still leaves the VM alone.
reset
vm 302 builder running cicustom='user=local:snippets/runner-user-data-prod.yaml' meta=1 uptime=3600 \
    born=$((clock - 86400))
[[ "$(get_vm_org 302)" == prod ]] || fail "the legacy snippet name was not read"
ticks
touched 302 && fail "a VM with only the legacy snippet name was stopped or destroyed: $(tr '\n' ' ' < "$actions")"

# Case C: the operator full-cloned runner VM 301 to debug a job, as runner-7.
# Proxmox copies the description, cicustom and hookscript; the copy is
# powered off. Its marker is this version's or an older one without a VMID.
for desc in "$(own_marker 301 acme)" 'selfhosted-runners org=acme kind=slot'; do
    reset
    vm 303 runner-7 stopped cicustom="$(own_cicustom 301 acme)" desc="$desc" hookscript=1
    ticks
    touched 303 && fail "a full clone of a runner ($desc) was stopped or destroyed: $(tr '\n' ' ' < "$actions")"
    # The copied hookscript runs reclone.sh when the copy stops.
    : > "$actions"
    set +e
    ( set -e; reclone_main 303 ) > "$state/out" 2>&1
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "reclone failed on a full clone (rc=$rc): $(tail -n 3 "$state/out")"
    touched 303 && fail "reclone destroyed a full clone of a runner ($desc)"
    grep -q 'could not identify VM 303' "$state/logger" || fail "reclone did not skip a full clone: $(cat "$state/logger")"
done

# A snippet that a VM's own config names stays, even when the VM is not one
# of this tool's: removing it would keep the VM from starting.
reset
vm 304 scratch stopped cicustom='user=local:snippets/mine.yaml,meta=local:snippets/runner-304-meta.yaml' meta=1
ticks
touched 304 && fail "a VM that names a runner meta snippet was stopped or destroyed"
[[ -e "$SNIPPETS_DIR/runner-304-meta.yaml" ]] || fail "a snippet that the VM's own config names was removed"

# --- What the watcher must still reclaim ---
# A runner of this version, one cloned before the marker named its VMID,
# one with the legacy per-org snippet, and a clone cut off before --cicustom.
reset
runner 9002 runner-2 acme
vm 9003 runner-3 stopped cicustom="$(own_cicustom 9003 acme)" desc='selfhosted-runners org=acme kind=slot' meta=1
vm 9004 runner-4 stopped cicustom='user=local:snippets/runner-user-data-acme.yaml,meta=local:snippets/runner-9004-meta.yaml' meta=1
vm 9005 runner-5 stopped desc="$(own_marker 9005 acme)"
ticks
for id in 9002 9003 9004 9005; do
    grep -qx "destroy $id" "$actions" || fail "runner VM $id was not reclaimed: $(tr '\n' ' ' < "$actions")"
done

# A runner of an org that was removed is still the tool's own: reclaimed,
# and not cloned again.
reset
rm -f "$ORG_CONFIG_DIR/gone.conf"
runner 9006 build-box gone
ticks
grep -qx 'destroy 9006' "$actions" || fail "a removed org's runner was not reclaimed: $(tr '\n' ' ' < "$actions")"
grep -q '^clone build-box' "$actions" && fail "a removed org's runner was cloned again"
grep -q 'not re-cloning build-box: org gone is no longer configured' "$state/out" \
    || fail "the removed org's runner was not retired: $(cat "$state/out")"

printf 'ownership-vm-binding: ok\n'
