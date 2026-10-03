#!/usr/bin/env bash
# Setup bakes a new Template VM ID beside the live template, so neither
# TEMPLATE_ID nor the retired list names that VM. Setup records it in the
# rebake's pending-bake file for the whole bake. If setup is killed, or
# cleanup_bake cannot destroy the VM, the next rebake's recover_pending_bake
# finishes or removes it. Setup never replaces a record whose VM may still
# exist, and it drops its record once the VM is published or destroyed.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup2-pending-bake: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'setup2-pending-bake: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
actions=$state/actions
: > "$actions"
CONFIG_FILE=$state/github-runners.conf
ORG_CONFIG_DIR=$state/github-runners.d
STATE_DIR=$state/lib
RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
BAKED_VERSION_FILE=$STATE_DIR/baked-runner-version
PENDING_BAKE_FILE=$STATE_DIR/pending-bake
PENDING_VERSION_FILE=$STATE_DIR/pending-version
REBAKE_LOCK_FILE=$state/rebake.lock
NETWORK_BRIDGE=vmbr0 VLAN_TAG="" VM_STORAGE=local-zfs MIN_VMID=9001 BALLOON=0
DNS_SERVERS="" DOCKER_MIRROR_URL=""

converted() {
    printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1' "$1" "$1"
}
baking() {
    printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:vm-%s-disk-0,size=30G' "$1" "$1"
}

# VMs are files, so they outlive a setup subshell that is killed.
vms=$state/vm
mkdir -p "$vms"
destroy_fails=0
inventory_fails=0
qm() {
    case "$1" in
        config|status)
            [[ -f "$vms/$2" ]] || return 2
            if [[ "$1" == config ]]; then cat "$vms/$2"; else printf 'status: running\n'; fi
            ;;
        stop) printf '%s\n' "$*" >> "$actions" ;;
        destroy)
            printf '%s\n' "$*" >> "$actions"
            if [[ "$destroy_fails" == 1 ]]; then
                printf "can't lock file '/var/lock/qemu-server/lock-%s.conf' - got timeout\n" "$2" >&2
                return 255
            fi
            rm -f "$vms/$2"
            ;;
        *) return 1 ;;
    esac
}
# The cluster inventory lists the VMs that exist.
pvesh() {
    local f sep=""
    [[ "$inventory_fails" == 0 ]] || return 1
    printf '['
    for f in "$vms"/*; do
        [[ -f "$f" ]] || continue
        printf '%s{"vmid":%s,"type":"qemu"}' "$sep" "${f##*/}"
        sep=,
    done
    printf ']\n'
}
flock() { :; }
prepare_cloud_image() { :; }
create_bake_vm() {
    printf 'create %s\n' "$1" >> "$actions"
    baking "$1" > "$vms/$1"
}
bake_result=converted
bake_and_publish_vm() {
    printf 'bake %s, pending-bake names %s\n' "$1" "$(cat "$PENDING_BAKE_FILE" 2>/dev/null || echo nothing)" >> "$actions"
    case "$bake_result" in
        failed) return 1 ;;
        # SIGKILL or a power loss: no EXIT trap runs.
        killed) kill -KILL "$BASHPID" ;;
        killed-converted) converted "$1" > "$vms/$1"; kill -KILL "$BASHPID" ;;
        converted) converted "$1" > "$vms/$1" ;;
    esac
    BAKE_RUNNER_VERSION=2.330.0
}
commit_baked_version() { printf 'commit %s %s\n' "$1" "$2" >> "$actions"; }
# The real config writer, failing on demand.
switch_fails=0
eval "real_$(declare -f set_conf_assignment)"
set_conf_assignment() { [[ "$switch_fails" == 0 ]] && real_set_conf_assignment "$@"; }
conf_template_id() { sed -n 's/^TEMPLATE_ID=//p' "$CONFIG_FILE"; }
pending() { cat "$PENDING_BAKE_FILE" 2>/dev/null || echo none; }
did() { grep -qxF "$1" "$actions"; }

# Template 9000 is live, and setup bakes the new Template VM ID 9100 beside it.
start_bake() {
    : > "$actions"
    rm -rf "$STATE_DIR" "$vms"
    mkdir -p "$vms"
    converted 9000 > "$vms/9000"
    destroy_fails=0
    inventory_fails=0
    switch_fails=0
    bake_result=converted
    TEMPLATE_ID=9100
    LIVE_TEMPLATE_ID=$1
    write_infra_config
}
# errexit stays on inside, as when setup.sh runs it. The outer redirection
# hides the shell's "Killed" notice.
run_setup_bake() {
    set +e
    { ( set -e; bake_setup_template ) 2> "$state/log"; } 2>/dev/null
    setup_rc=$?
    set -e
}
# The next daily rebake, which reads TEMPLATE_ID from the config.
run_recover() {
    local rc
    set +e
    (
        set -e
        TEMPLATE_ID=$(conf_template_id)
        recover_pending_bake
    ) 2> "$state/recover-log"
    rc=$?
    set -e
    [[ "$rc" == 0 ]] || fail "recover_pending_bake failed: $(cat "$state/recover-log")"
}

# --- A successful bake is recorded until TEMPLATE_ID names it ---
start_bake 9000
run_setup_bake
[[ "$setup_rc" == 0 ]] || fail "a successful bake failed: $(cat "$state/log")"
did 'bake 9100, pending-bake names 9100' || fail "the bake beside the live template was not recorded for the rebake"
[[ "$(conf_template_id)" == 9100 ]] || fail "TEMPLATE_ID did not move to the finished template"
[[ "$(pending)" == none ]] || fail "the published template stayed recorded as a pending bake"

# --- A failed bake is destroyed, and its record goes with it ---
start_bake 9000
bake_result=failed
run_setup_bake
[[ "$setup_rc" != 0 ]] || fail "a failed bake reported success"
[[ ! -e "$vms/9100" ]] || fail "the failed bake VM was not destroyed"
[[ "$(pending)" == none ]] || fail "the destroyed bake VM stayed recorded"
[[ "$(conf_template_id)" == 9000 ]] || fail "a failed bake moved TEMPLATE_ID"

# --- A destroy that fails is logged, and the next rebake removes the VM ---
start_bake 9000
bake_result=failed
destroy_fails=1
run_setup_bake
did 'destroy 9100' || fail "cleanup did not try to destroy the failed bake VM"
grep -qF 'Could not destroy VM 9100' "$state/log" || fail "a failed qm destroy was not logged"
grep -qF "can't lock file" "$state/log" || fail "qm destroy's own error was discarded"
[[ -e "$vms/9100" && "$(pending)" == 9100 ]] || fail "a VM cleanup could not destroy lost its pending-bake record"
destroy_fails=0
run_recover
[[ ! -e "$vms/9100" && "$(pending)" == none ]] || fail "the next rebake did not remove the VM setup left"
[[ "$(conf_template_id)" == 9000 ]] || fail "removing setup's failed bake moved TEMPLATE_ID"

# --- Setup killed during the bake: the next rebake removes the running VM ---
start_bake 9000
bake_result=killed
run_setup_bake
[[ "$setup_rc" == 137 ]] || fail "the killed setup exited with $setup_rc"
[[ -e "$vms/9100" && "$(pending)" == 9100 ]] || fail "a killed setup left its bake VM untracked"
run_recover
did 'destroy 9100' || fail "the next rebake did not destroy the VM a killed setup left"
[[ ! -e "$vms/9100" && "$(pending)" == none ]] || fail "the killed setup's bake VM or record survived the rebake"
[[ "$(conf_template_id)" == 9000 ]] || fail "removing a killed setup's bake moved TEMPLATE_ID"

# --- Setup killed after qm template: the next rebake publishes the template ---
start_bake 9000
bake_result=killed-converted
run_setup_bake
[[ "$(conf_template_id)" == 9000 && "$(pending)" == 9100 ]] || fail "a template finished before the kill was not left for the rebake"
run_recover
[[ "$(conf_template_id)" == 9100 ]] || fail "the next rebake did not publish the template a killed setup finished"
[[ "$(cat "$RETIRED_TEMPLATES_FILE")" == 9000 ]] || fail "publishing setup's template did not retire the old one"
[[ -e "$vms/9100" && "$(pending)" == none ]] || fail "publishing setup's template left its record or destroyed it"

# --- Switching TEMPLATE_ID fails: the record stays, so the next rebake publishes ---
start_bake 9000
switch_fails=1
run_setup_bake
switch_fails=0
[[ "$setup_rc" != 0 && "$(pending)" == 9100 ]] || fail "a template whose switch failed lost its pending-bake record"
run_recover
[[ "$(conf_template_id)" == 9100 ]] || fail "the next rebake did not publish the template setup could not switch to"

# --- Another bake's record is replaced only once its VM is proven gone ---
for owner in rebake unreadable; do
    start_bake 9000
    baking 9001 > "$vms/9001"
    install -d -m 700 "$STATE_DIR"
    printf '9001\n' > "$PENDING_BAKE_FILE"
    printf 'version=2.329.0\n' > "$PENDING_VERSION_FILE"
    # The cluster inventory cannot prove that VM 9001 is gone.
    if [[ "$owner" == unreadable ]]; then
        rm -f "$vms/9001"
        inventory_fails=1
    fi
    run_setup_bake
    [[ "$setup_rc" != 0 ]] || fail "setup baked over the pending record of VM 9001 ($owner)"
    if grep -q '^create ' "$actions"; then
        fail "setup created a bake VM over the pending record of VM 9001 ($owner)"
    fi
    [[ "$(pending)" == 9001 && "$(cat "$PENDING_VERSION_FILE")" == version=2.329.0 ]] ||
        fail "setup replaced the pending record of VM 9001 ($owner)"
    grep -qF 'runner rebake' "$state/log" || fail "the refusal did not say how to clear the record"
done

# --- A record whose VM is gone is stale, and its version is dropped ---
for stale in 9001 9100; do
    start_bake 9000
    install -d -m 700 "$STATE_DIR"
    printf '%s\n' "$stale" > "$PENDING_BAKE_FILE"
    printf 'version=2.329.0\n' > "$PENDING_VERSION_FILE"
    bake_result=killed-converted
    run_setup_bake
    did 'bake 9100, pending-bake names 9100' || fail "a stale record for VM $stale blocked the bake"
    run_recover
    [[ "$(conf_template_id)" == 9100 ]] || fail "the next rebake did not publish setup's template"
    if grep -q '^commit ' "$actions"; then
        fail "the next rebake recorded the stale record's runner version for setup's template"
    fi
done

# --- A first bake writes no record, and leaves other bakes' records alone ---
start_bake ""
bake_result=failed
baking 9001 > "$vms/9001"
install -d -m 700 "$STATE_DIR"
printf '9001\n' > "$PENDING_BAKE_FILE"
run_setup_bake
did 'bake 9100, pending-bake names 9001' || fail "a first bake replaced another bake's record"
did 'destroy 9100' || fail "the failed first bake was not destroyed"
[[ "$(pending)" == 9001 ]] || fail "cleanup of a first bake dropped another bake's record"

printf 'setup2-pending-bake: ok\n'
