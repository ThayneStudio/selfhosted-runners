#!/usr/bin/env bash
# A setup bake beside the live template records its VMID in pending-bake. When
# create_bake_vm refused before `qm create` (too little free space, a bad
# BAKE_TIMEOUT, no release), setup's cleanup was not armed yet, so the record
# outlived a VM that never existed. A record can also outlive its VM after the
# hand removal setup asks for when its destroy fails. Once that VMID was used
# on another node, every rebake failed with "Could not confirm pending bake VM
# ... is absent", and setup refused to bake beside the live template without
# saying how to clear the record. Bake VMs are created on this node, so a
# VMID the cluster inventory places on another node is not one.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'records-pending-bake: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'records-pending-bake: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
actions=$state/actions
STATE_DIR=$state/lib
PENDING_BAKE_FILE=$STATE_DIR/pending-bake
PENDING_VERSION_FILE=$STATE_DIR/pending-version
REBAKE_LOCK_FILE=$state/rebake.lock
# shellcheck disable=SC2034 # read by cleanup_rebake's release_vmid_reservation
VMID_RESERVATION_LOCK_PREFIX=$state/reserve
NETWORK_BRIDGE=vmbr0 VLAN_TAG="" VM_STORAGE=local-lvm BALLOON=0
unset BAKE_MIN_FREE_GIB BAKE_TIMEOUT

# $vms/<node>/<vmid> is a VM config. qm on this node, pve1, sees only its own
# VMs; the cluster inventory lists every node's.
vms=$state/vm
host_name=pve1.lan
uname() { [[ "$1" == -n ]] && printf '%s\n' "$host_name"; }
status_fails=""
inventory_fails=0
qm() {
    local conf="$vms/pve1/${2:-}"
    case "$1" in
        config|status)
            [[ -f "$conf" && "$2" != "$status_fails" ]] || return 2
            if [[ "$1" == config ]]; then cat "$conf"; else printf 'status: running\n'; fi
            ;;
        create|stop|destroy)
            printf '%s\n' "$*" >> "$actions"
            [[ "$1" != destroy ]] || rm -f "$conf"
            ;;
        *) return 1 ;;
    esac
}
pvesh() {
    local f node sep=""
    [[ "$*" == "get /cluster/resources --type vm --output-format json" && "$inventory_fails" == 0 ]] || return 1
    printf '['
    for f in "$vms"/*/*; do
        [[ -f "$f" ]] || continue
        node=${f%/*}
        printf '%s{"vmid":%s,"type":"qemu","node":"%s"}' "$sep" "${f##*/}" "${node##*/}"
        sep=,
    done
    printf ']\n'
}
# 10 GiB free on VM_STORAGE: the real create_bake_vm refuses before qm create.
pvesm() {
    [[ "$1" == status ]] || return 1
    printf 'Name Type Status Total Used Available %%\n'
    printf 'local-lvm lvmthin active 104857600 94371840 10485760 90.00%%\n'
}
flock() { :; }
prepare_cloud_image() { :; }
pending() { cat "$PENDING_BAKE_FILE" 2>/dev/null || echo none; }
record() {
    install -d -m 700 "$STATE_DIR"
    printf '%s\n' "$1" > "$PENDING_BAKE_FILE"
}

# Setup bakes VM $1 beside live template $2 (empty: a first bake). Template
# 9000 is on this node.
start() {
    : > "$actions"
    rm -rf "$STATE_DIR" "$vms"
    mkdir -p "$vms/pve1" "$vms/pve2"
    printf 'name: ubuntu-cloud-template\nscsi0: local-lvm:base-9000-disk-0,size=30G\ntemplate: 1\n' > "$vms/pve1/9000"
    inventory_fails=0
    status_fails=""
    TEMPLATE_ID=$1
    LIVE_TEMPLATE_ID=$2
}
# errexit stays on inside, as when setup.sh runs it.
run_setup_bake() {
    set +e
    ( set -e; bake_setup_template ) 2> "$state/log"
    setup_rc=$?
    set -e
}
# The next daily rebake, with template 9000 live.
run_recover() {
    set +e
    ( set -e; TEMPLATE_ID=9000; recover_pending_bake ) 2> "$state/recover-log"
    recover_rc=$?
    set -e
}

# --- A side bake refused before qm create leaves no record behind ---
start 9100 9000
run_setup_bake
[[ "$setup_rc" != 0 ]] || fail "a bake refused for free space reported success"
grep -qF 'Not baking: storage local-lvm has 10 GiB free' "$state/log" ||
    fail "the bake was not refused before qm create: $(cat "$state/log")"
[[ ! -s "$actions" ]] || fail "a bake refused before qm create ran: $(cat "$actions")"
[[ "$(pending)" == none ]] || fail "VM 9100, which was never created, stayed recorded as a pending bake"
if grep -qF 'Could not read config' "$state/log"; then
    fail "cleanup reported a VM that was never created: $(cat "$state/log")"
fi

# --- Absence that cannot be proven keeps the record for the next rebake ---
start 9100 9000
inventory_fails=1
run_setup_bake
[[ "$setup_rc" != 0 && "$(pending)" == 9100 ]] ||
    fail "the record was dropped although the cluster inventory could not be read"
grep -qF 'Could not read config for VM 9100' "$state/log" || fail "keeping the record was not logged: $(cat "$state/log")"
inventory_fails=0
run_recover
[[ "$recover_rc" == 0 && "$(pending)" == none ]] ||
    fail "the next rebake kept the record of a VM that never existed: $(cat "$state/recover-log")"

# --- A refused first bake leaves another bake's record alone ---
start 9100 ""
printf 'name: ubuntu-cloud-template\nscsi0: local-lvm:vm-9001-disk-0,size=30G\n' > "$vms/pve1/9001"
record 9001
run_setup_bake
[[ "$setup_rc" != 0 ]] || fail "a refused first bake reported success"
[[ "$(pending)" == 9001 ]] || fail "a refused first bake dropped the record of VM 9001"

# --- A record whose VMID is now a VM on another node ---
# Left by the hand removal that cleanup_bake asks for, after which VMID 9100
# was used on node pve2.
start 9200 9000
printf 'name: build-box\n' > "$vms/pve2/9100"
record 9100
run_setup_bake
[[ "$setup_rc" != 0 && "$(pending)" == 9100 ]] || fail "setup replaced a record it could not prove stale"
[[ ! -s "$actions" ]] || fail "setup baked over the record of VM 9100: $(cat "$actions")"
grep -qF "runner rebake" "$state/log" || fail "the refusal did not name runner rebake: $(cat "$state/log")"
grep -qF "rm $PENDING_BAKE_FILE" "$state/log" ||
    fail "the refusal did not say how to remove a stale record by hand: $(cat "$state/log")"
run_recover
[[ "$recover_rc" == 0 ]] || fail "the rebake failed on the record of a VM on another node: $(cat "$state/recover-log")"
[[ "$(pending)" == none ]] || fail "the rebake kept the record of a VM on another node"
grep -qF 'Pending bake id 9100 is a guest on node pve2' "$state/recover-log" ||
    fail "dropping the record did not name the node: $(cat "$state/recover-log")"
[[ ! -s "$actions" && -e "$vms/pve2/9100" ]] || fail "the rebake acted on a VM on another node: $(cat "$actions")"
run_setup_bake
grep -qF 'Not baking' "$state/log" || fail "setup still refused once the stale record was gone: $(cat "$state/log")"

# --- The rebake's own record: its VMID was taken on another node ---
start 9100 9000
printf 'name: build-box\n' > "$vms/pve2/9001"
record 9001
set +e
# shellcheck disable=SC2034 # read by cleanup_rebake
( BAKE_VMID=9001; REBAKE_PUBLISHED=0; TEMPLATE_ID=9000; cleanup_rebake 1 ) 2> "$state/cleanup-log"
cleanup_rc=$?
set -e
[[ "$cleanup_rc" != 0 ]] || fail "cleanup_rebake reported a failed bake as a success"
run_recover
[[ "$recover_rc" == 0 && "$(pending)" == none ]] ||
    fail "the rebake's own record for a VM on another node was kept: $(cat "$state/recover-log")"
[[ ! -s "$actions" && -e "$vms/pve2/9001" ]] || fail "the rebake acted on a VM on another node: $(cat "$actions")"

# --- Nothing short of another node's name drops a record ---
# qm status fails, and the inventory lists the VM on this node, whose host
# name carries a domain.
start 9200 9000
printf 'name: ubuntu-cloud-template\nscsi0: local-lvm:vm-9100-disk-0,size=30G\n' > "$vms/pve1/9100"
record 9100
status_fails=9100
run_recover
[[ "$recover_rc" != 0 && "$(pending)" == 9100 ]] ||
    fail "the record of VM 9100 on this node ($host_name) was dropped when qm status failed"
# Without this node's name, a VM on pve2 is not proven to be elsewhere.
start 9200 9000
printf 'name: build-box\n' > "$vms/pve2/9100"
record 9100
host_name=""
run_recover
host_name=pve1.lan
[[ "$recover_rc" != 0 && "$(pending)" == 9100 ]] || fail "the record was dropped without this node's name"
[[ ! -s "$actions" ]] || fail "an unproven record led to: $(cat "$actions")"

printf 'records-pending-bake: ok\n'
