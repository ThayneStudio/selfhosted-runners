#!/usr/bin/env bash
# A bake VMID can already have a config-less volume. reserve_vmid does not
# look at storage, and setup arms cleanup before qm create, so a refused
# admission used to free that volume. Below MIN_VMID the orphan sweep never
# does. Cleanup may free a disk only after this bake created the VM, a rebake
# skips a VMID that already has one, and a volume pvesm free cannot remove
# must not keep the pending record forever.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-preexisting-volume: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'bake-preexisting-volume: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by setup, rebake and the volume helpers
{
    STATE_DIR=$state/lib
    PENDING_BAKE_FILE=$STATE_DIR/pending-bake
    PENDING_VERSION_FILE=$STATE_DIR/pending-version
    RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
    PVE_NODES_DIR=$state/nodes
    VM_STORAGE=local-zfs
    TEMPLATE_ID=9100
    LIVE_TEMPLATE_ID=9000
    REBAKE_PUBLISHED=0
    NETWORK_BRIDGE=vmbr0
    VLAN_TAG=""
    LATEST_RUNNER_VERSION=2.330.0
    REBAKE_LOCK_FILE=$state/rebake.lock
    VMID_RESERVATION_LOCK_PREFIX=$state/reserve
}
unset BAKE_MIN_FREE_GIB BAKE_TIMEOUT BAKE_FREE_FLOOR_GIB BAKE_VM_CREATED
gib=1048576
actions=$state/actions
frees=$state/frees
pvesm_log=$state/pvesm.log
mock_storage=$state/storage
mock_busy=$state/busy
mock_list_fails=0
mock_avail=$((100 * gib))

conf_of() { printf '%s/pve1/qemu-server/%s.conf' "$PVE_NODES_DIR" "$1"; }
set_volumes() { cat > "$mock_storage"; }
pending() {
    printf '%s\n' "$1" > "$PENDING_BAKE_FILE"
    rm -f "${PENDING_BAKE_FILE}.created"
}
mark_created() { printf '%s\n' "$1" > "${PENDING_BAKE_FILE}.created"; }
record_kept() { [[ -f "$PENDING_BAKE_FILE" ]]; }
assert_kept() { grep -qxF "$1" "$mock_storage" || fail "$2: freed $1"; }
assert_gone() { if grep -qxF "$1" "$mock_storage"; then fail "$2: $1 was not freed"; fi; }
assert_not_freed() { if grep -qxF "free $1" "$frees"; then fail "$2: freed $1"; fi; }
reset_case() {
    : > "$actions"
    : > "$frees"
    : > "$pvesm_log"
    : > "$mock_busy"
    unset BAKE_VM_CREATED
    rm -rf "$PVE_NODES_DIR" "$STATE_DIR"
    mkdir -p "$STATE_DIR" "$PVE_NODES_DIR/pve1/qemu-server" "$PVE_NODES_DIR/pve1/lxc"
    printf '9005\n' > "$RETIRED_TEMPLATES_FILE"
    mock_list_fails=0
    mock_avail=$((100 * gib))
}

prepare_cloud_image() { :; }
flock() { :; }
qm() {
    printf '%s\n' "$*" >> "$actions"
    case "$1" in
        status|config)
            [[ -f "$(conf_of "$2")" ]] || return 2
            if [[ "$1" == config ]]; then cat "$(conf_of "$2")"; else printf 'status: running\n'; fi
            ;;
        create|stop) return 0 ;;
        destroy) rm -f "$(conf_of "$2")" ;;
        *) return 1 ;;
    esac
}
pvesh() { printf '[]\n'; }
pvesm() {
    local volume
    printf '%s\n' "$*" >> "$pvesm_log"
    case "$1" in
        list)
            [[ "$mock_list_fails" == 0 ]] || return 1
            printf 'Volid Format Type Size VMID\n'
            while read -r volume; do
                [[ -n "$volume" ]] || continue
                printf '%s raw images 1 0\n' "$volume"
            done < "$mock_storage"
            ;;
        free)
            printf 'free %s\n' "$2" >> "$frees"
            if grep -qxF "$2" "$mock_busy"; then
                return 0
            fi
            grep -vxF "$2" "$mock_storage" > "$mock_storage.new" || true
            mv "$mock_storage.new" "$mock_storage"
            ;;
        status)
            # lvmthin: the free-space check does not ask whether ZFS is sparse.
            printf 'Name Type Status Total Used Available %%\n'
            printf '%s lvmthin active %s %s %s 50.00%%\n' "$VM_STORAGE" \
                $((1000 * gib)) $((1000 * gib - mock_avail)) "$mock_avail"
            ;;
        *) return 1 ;;
    esac
}
# `||` would disable errexit inside the subshell, and a refused create would
# then fall through into the rest of the bake.
run_setup() {
    : > "$actions"
    : > "$frees"
    set +e
    ( set -e; bake_setup_template ) 2>"$state/log"
    setup_rc=$?
    set -e
}
run_setup_cleanup() {
    : > "$actions"
    : > "$frees"
    ( cleanup_bake ) 2>"$state/log"
}
run_cleanup() {
    : > "$actions"
    : > "$frees"
    set +e
    # shellcheck disable=SC2034 # cleanup_rebake reads both
    ( set -e; BAKE_VMID=$1; REBAKE_PUBLISHED=0; cleanup_rebake 1 ) 2>"$state/log"
    cleanup_rc=$?
    set -e
}
run_recover() {
    : > "$actions"
    : > "$frees"
    set +e
    ( set -e; recover_pending_bake ) 2>"$state/log"
    recover_rc=$?
    set -e
}
list_calls() { grep -c '^list ' "$pvesm_log" || true; }

# --- Setup refused for free space must not free a disk that was already there ---
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
mock_avail=$((10 * gib))
set_volumes <<'EOF'
local-zfs:base-9000-disk-0
local-zfs:vm-9100-disk-0
EOF
run_setup
[[ "$setup_rc" != 0 ]] || fail "a bake refused for free space reported success"
grep -qF 'Not baking: storage local-zfs has 10 GiB free' "$state/log" \
    || fail "the bake was not refused for free space: $(cat "$state/log")"
if grep -q '^create ' "$actions"; then fail "a refused admission ran qm create: $(cat "$actions")"; fi
assert_kept local-zfs:vm-9100-disk-0 "setup refused for free space"
assert_kept local-zfs:base-9000-disk-0 "setup refused for free space"
assert_not_freed local-zfs:vm-9100-disk-0 "setup refused for free space"
assert_not_freed local-zfs:base-9000-disk-0 "setup refused for free space"
if record_kept; then fail "a bake that never created a VM stayed recorded"; fi

# --- The same VMID is refused for the volume once storage has room ---
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
mock_avail=$((100 * gib))
set_volumes <<'EOF'
local-zfs:vm-9100-disk-0
EOF
run_setup
[[ "$setup_rc" != 0 ]] || fail "a VMID that already has a volume was baked"
grep -qF 'already has disk volumes' "$state/log" \
    || fail "the existing volume was not named: $(cat "$state/log")"
grep -qF 'local-zfs:vm-9100-disk-0' "$state/log" \
    || fail "the volid was not named: $(cat "$state/log")"
if grep -q '^create ' "$actions"; then fail "qm create ran on a VMID that already has a volume"; fi
assert_kept local-zfs:vm-9100-disk-0 "setup refused for an existing volume"
assert_not_freed local-zfs:vm-9100-disk-0 "setup refused for an existing volume"
if record_kept; then fail "the refused VMID stayed recorded"; fi

# A listing that cannot be read is not an empty storage.
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
mock_list_fails=1
set_volumes <<'EOF'
local-zfs:vm-9100-disk-0
EOF
run_setup
[[ "$setup_rc" != 0 ]] || fail "an unreadable volume list was baked on"
grep -qF 'Could not list volumes on local-zfs' "$state/log" \
    || fail "the unreadable list was not reported: $(cat "$state/log")"
if grep -q '^create ' "$actions"; then fail "qm create ran when the volume list failed"; fi
assert_kept local-zfs:vm-9100-disk-0 "unreadable volume list"
assert_not_freed local-zfs:vm-9100-disk-0 "unreadable volume list"

# --- No created marker: an absent VMID's old disk stays, and the record goes ---
reset_case
TEMPLATE_ID=9000
LIVE_TEMPLATE_ID=
set_volumes <<'EOF'
local-zfs:vm-9201-disk-0
local-zfs:base-9000-disk-0
EOF
pending 9201
run_cleanup 9201
[[ "$cleanup_rc" != 0 ]] || fail "cleanup of a bake that was never created reported success"
assert_kept local-zfs:vm-9201-disk-0 "cleanup absent, no marker"
assert_not_freed local-zfs:vm-9201-disk-0 "cleanup absent, no marker"
assert_not_freed local-zfs:base-9000-disk-0 "cleanup absent, no marker"
if record_kept; then fail "cleanup kept the record of a VM that was never created"; fi
pending 9201
run_recover
[[ "$recover_rc" == 0 ]] || fail "recover failed on an absent VM that was never created: $(cat "$state/log")"
assert_kept local-zfs:vm-9201-disk-0 "recover absent, no marker"
assert_not_freed local-zfs:vm-9201-disk-0 "recover absent, no marker"
if record_kept; then fail "recover kept the record of a VM that was never created"; fi

# --- reserve_vmid still returns a VMID that has a volume; the rebake skips it ---
reset_case
MIN_VMID=9201
set_volumes <<'EOF'
local-zfs:vm-9201-disk-0
EOF
reserve_vmid
[[ "$RESERVED_VMID" == 9201 ]] || fail "reserve_vmid skipped a VMID that only has a volume (got $RESERVED_VMID)"
release_vmid_reservation 9201
reserve_bake_vmid 2>"$state/log"
[[ "$RESERVED_VMID" == 9202 ]] || fail "reserve_bake_vmid took VMID $RESERVED_VMID, which has a volume or skipped a free one"
release_vmid_reservation "$RESERVED_VMID"
# A longer VMID is not this one. A cloud-init drive and a linked clone are.
set_volumes <<'EOF'
local-zfs:vm-92010-disk-0
EOF
clear_rc=0
bake_vmid_storage_clear 9201 2>"$state/log" || clear_rc=$?
[[ "$clear_rc" == 0 ]] || fail "vm-92010-disk-0 was treated as a volume of VMID 9201"
set_volumes <<'EOF'
local-zfs:vm-9201-cloudinit
EOF
clear_rc=0
bake_vmid_storage_clear 9201 2>"$state/log" || clear_rc=$?
[[ "$clear_rc" == 1 ]] || fail "a cloud-init drive did not block bake VMID 9201"
set_volumes <<'EOF'
local-zfs:base-9000-disk-0/vm-9201-disk-0
EOF
clear_rc=0
bake_vmid_storage_clear 9201 2>"$state/log" || clear_rc=$?
[[ "$clear_rc" == 1 ]] || fail "a linked clone of VMID 9201 did not block it"
set_volumes <<'EOF'
local-zfs:base-9000-disk-0
EOF
clear_rc=0
bake_vmid_storage_clear 9201 2>"$state/log" || clear_rc=$?
[[ "$clear_rc" == 0 ]] || fail "another VMID's base volume blocked 9201"
# An unreadable list stops the search. It must not walk every later VMID.
: > "$pvesm_log"
mock_list_fails=1
clear_rc=0
reserve_bake_vmid 2>"$state/log" || clear_rc=$?
[[ "$clear_rc" != 0 ]] || fail "reserve_bake_vmid baked on after the volume list failed"
[[ "$(list_calls)" == 1 ]] || fail "a failed volume list was retried $(list_calls) times"
grep -qF 'Could not list volumes on local-zfs' "$state/log" \
    || fail "reserve_bake_vmid did not report the unreadable list: $(cat "$state/log")"
unset MIN_VMID
mock_list_fails=0

# The free itself does not take a longer VMID's disk with it.
reset_case
set_volumes <<'EOF'
local-zfs:vm-9100-disk-0
local-zfs:vm-91000-disk-0
EOF
free_rc=0
free_bake_leftover_volumes 9100 9000 2>"$state/log" || free_rc=$?
[[ "$free_rc" == 0 ]] || fail "freeing VMID 9100 failed: $(cat "$state/log")"
assert_gone local-zfs:vm-9100-disk-0 "prefix"
assert_kept local-zfs:vm-91000-disk-0 "prefix"

# --- A created bake's leaked disk is still freed; one that stays does not wedge ---
reset_case
TEMPLATE_ID=9000
set_volumes <<'EOF'
local-zfs:base-9201-disk-0
local-zfs:base-9000-disk-0
EOF
pending 9201
mark_created 9201
run_recover
[[ "$recover_rc" == 0 ]] || fail "recover failed on a created bake's leaked volume: $(cat "$state/log")"
assert_gone local-zfs:base-9201-disk-0 "created marker"
assert_kept local-zfs:base-9000-disk-0 "created marker"
assert_not_freed local-zfs:base-9000-disk-0 "created marker"
if record_kept; then fail "recover kept the record after freeing the leaked volume"; fi
[[ ! -e "${PENDING_BAKE_FILE}.created" ]] || fail "the created marker survived the free"

pending 9201
mark_created 9201
set_volumes <<'EOF'
local-zfs:base-9201-disk-0
EOF
printf 'local-zfs:base-9201-disk-0\n' > "$mock_busy"
run_recover
[[ "$recover_rc" == 0 ]] || fail "a volume pvesm free could not remove failed the rebake: $(cat "$state/log")"
assert_kept local-zfs:base-9201-disk-0 "created marker, busy"
if record_kept; then fail "a volume pvesm free could not remove kept the pending record"; fi
grep -qF "pvesm free 'local-zfs:base-9201-disk-0'" "$state/log" \
    || fail "the volume left behind was not named: $(cat "$state/log")"
grep -qxF 'vmid=9201 volid=local-zfs:base-9201-disk-0' "$STATE_DIR/bake-leftover-volumes" \
    || fail "the volume was not quarantined: $(cat "$STATE_DIR/bake-leftover-volumes" 2>/dev/null)"
run_recover
[[ "$recover_rc" == 0 ]] || fail "the next rebake was still wedged: $(cat "$state/log")"
assert_kept local-zfs:base-9201-disk-0 "second recover does not retry"
: > "$mock_busy"

# qm create records the VM, so a later recover can tell it from a reserved id.
reset_case
TEMPLATE_ID=9100
mock_avail=$((100 * gib))
set_volumes <<'EOF'
EOF
create_rc=0
create_bake_vm 9100 2>"$state/log" || create_rc=$?
[[ "$create_rc" == 0 ]] || fail "create_bake_vm failed on an empty storage: $(cat "$state/log")"
grep -q '^create 9100 ' "$actions" || fail "qm create did not run"
[[ "${BAKE_VM_CREATED:-}" == 9100 ]] || fail "create_bake_vm did not remember the VM in this process"
[[ "$(tr -d '[:space:]' < "${PENDING_BAKE_FILE}.created")" == 9100 ]] \
    || fail "create_bake_vm did not record the VM for a later recover"
unset BAKE_VM_CREATED

# A marker left from an older bake of this VMID must not apply to a new
# reservation that qm create never made.
reset_case
TEMPLATE_ID=9000
mock_avail=$((10 * gib))
set_volumes <<'EOF'
local-zfs:vm-9201-disk-0
EOF
install -d -m 700 "$STATE_DIR"
printf '9201\n' > "$PENDING_BAKE_FILE"
printf '9201\n' > "${PENDING_BAKE_FILE}.created"
saved_reserve=$(declare -f reserve_bake_vmid)
# shellcheck disable=SC2329 # perform_bake calls this override
reserve_bake_vmid() { RESERVED_VMID=9201; }
set +e
( set -e; perform_bake ) 2>"$state/log"
perf_rc=$?
set -e
eval "$saved_reserve"
[[ "$perf_rc" != 0 ]] || fail "a rebake refused for free space reported success"
grep -qF 'Not baking: storage local-zfs has 10 GiB free' "$state/log" \
    || fail "the rebake was not refused for free space: $(cat "$state/log")"
assert_kept local-zfs:vm-9201-disk-0 "stale created marker"
assert_not_freed local-zfs:vm-9201-disk-0 "stale created marker"
if record_kept; then fail "the refused rebake stayed recorded"; fi

# A first setup writes no pending record. Publishing still has to remove the
# created marker, or the next setup of this VMID treats it as its own VM.
reset_case
TEMPLATE_ID=9100
unset BAKE_VM_CREATED BAKE_RUN_TOKEN
mark_bake_vm_created 9100
unset BAKE_VM_CREATED
[[ -f "${PENDING_BAKE_FILE}.created" ]] || fail "mark_bake_vm_created wrote no marker"
forget_setup_bake
[[ ! -e "${PENDING_BAKE_FILE}.created" ]] || fail "a first setup left its created marker behind"
[[ ! -e "$PENDING_BAKE_FILE" ]] || fail "forgetting a first setup created a pending record"
# Another bake's marker is not this template's.
printf '9001\n' > "${PENDING_BAKE_FILE}.created"
forget_setup_bake
[[ -f "${PENDING_BAKE_FILE}.created" ]] || fail "forget removed a marker for a different VMID"

# The marker is cleared before create, so a refusal cannot free a disk that
# was already on the VMID. A first setup never calls record_setup_bake.
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=
mock_avail=$((100 * gib))
set_volumes <<'EOF'
local-zfs:vm-9100-disk-0
EOF
install -d -m 700 "$STATE_DIR"
printf '9100\n' > "${PENDING_BAKE_FILE}.created"
unset BAKE_VM_CREATED BAKE_RUN_TOKEN
saved_create=$(declare -f create_bake_vm)
eval "real_$(declare -f create_bake_vm)"
# shellcheck disable=SC2329 # bake_setup_template calls this override
create_bake_vm() {
    if [[ -f "${PENDING_BAKE_FILE}.created" ]]; then
        printf 'present\n' > "$state/marker-at-create"
    else
        printf 'absent\n' > "$state/marker-at-create"
    fi
    real_create_bake_vm "$@"
}
run_setup
eval "$saved_create"
[[ "$(cat "$state/marker-at-create" 2>/dev/null)" == absent ]] \
    || fail "setup did not clear the created marker before qm create"
[[ "$setup_rc" != 0 ]] || fail "a VMID that already has a volume was baked"
if grep -q '^create ' "$actions"; then fail "qm create ran on a VMID that already has a volume"; fi
assert_kept local-zfs:vm-9100-disk-0 "stale marker from a first setup"
assert_not_freed local-zfs:vm-9100-disk-0 "stale marker from a first setup"

# A marker that carries another run's token does not count while this process
# is baking, even if it was not removed. Recover, which did not start a bake,
# still honours it.
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=
unset BAKE_VM_CREATED
# shellcheck disable=SC2034 # bake_vm_was_created reads it
BAKE_RUN_TOKEN=this-run
set_volumes <<'EOF'
local-zfs:vm-9100-disk-0
EOF
printf '9100 other-run\n' > "${PENDING_BAKE_FILE}.created"
run_setup_cleanup
assert_kept local-zfs:vm-9100-disk-0 "marker from another run"
assert_not_freed local-zfs:vm-9100-disk-0 "marker from another run"
printf '9100 this-run\n' > "${PENDING_BAKE_FILE}.created"
run_setup_cleanup
assert_gone local-zfs:vm-9100-disk-0 "marker from this run"
# The next rebake is not this process's bake. The old marker is enough.
set_volumes <<'EOF'
local-zfs:base-9100-disk-0
EOF
pending 9100
printf '9100 other-run\n' > "${PENDING_BAKE_FILE}.created"
# shellcheck disable=SC2034 # recover_pending_bake clears it; the marker must still count
BAKE_RUN_TOKEN=this-run
TEMPLATE_ID=9000
run_recover
[[ "$recover_rc" == 0 ]] || fail "recover ignored a created marker because a token was set: $(cat "$state/log")"
assert_gone local-zfs:base-9100-disk-0 "recover with a foreign token in the environment"
unset BAKE_RUN_TOKEN

# qm template renamed the disk and failed; qm destroy left the base volume.
# A listing that cannot be read is not an empty storage: the record and the
# marker stay, and the next recover frees the volume once the list works.
reset_case
TEMPLATE_ID=9000
unset BAKE_VM_CREATED BAKE_RUN_TOKEN
printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:vm-9201-disk-0,size=30G\n' > "$(conf_of 9201)"
set_volumes <<'EOF'
local-zfs:base-9201-disk-0
EOF
pending 9201
mark_created 9201
mock_list_fails=1
run_cleanup 9201
[[ "$cleanup_rc" != 0 ]] || fail "cleanup reported success when the volume list failed"
assert_kept local-zfs:base-9201-disk-0 "unlistable after destroy"
assert_not_freed local-zfs:base-9201-disk-0 "unlistable after destroy"
if ! record_kept; then fail "an unreadable volume list dropped the pending record"; fi
grep -qF 'could not be checked' "$state/log" \
    || fail "an unreadable volume list was not reported: $(cat "$state/log")"
[[ -f "${PENDING_BAKE_FILE}.created" ]] || fail "an unreadable volume list dropped the created marker"
if [[ -f "$STATE_DIR/bake-leftover-volumes" ]] \
    && grep -q 'base-9201-disk-0' "$STATE_DIR/bake-leftover-volumes"; then
    fail "an unreadable volume list was quarantined: $(cat "$STATE_DIR/bake-leftover-volumes")"
fi
[[ ! -e "$(conf_of 9201)" ]] || fail "the bake VM was not destroyed before the list failed"
mock_list_fails=0
run_recover
[[ "$recover_rc" == 0 ]] || fail "the next recover did not free the volume once the list worked: $(cat "$state/log")"
assert_gone local-zfs:base-9201-disk-0 "retry after an unreadable list"
if record_kept; then fail "the record stayed after the leftover volume was freed"; fi
[[ ! -e "${PENDING_BAKE_FILE}.created" ]] || fail "the created marker stayed after the leftover volume was freed"

# A side setup replaces a pending record whose VM is already gone. The
# leftover base volume has to be freed while the old marker still exists.
# An unreadable listing keeps that record. A volume pvesm free cannot
# remove is quarantined, and the new bake still takes the record.
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
# shellcheck disable=SC2034 # record_setup_bake clears it; the old marker must still count
BAKE_RUN_TOKEN=this-run
set_volumes <<'EOF'
local-zfs:base-9001-disk-0
local-zfs:base-9000-disk-0
local-zfs:vm-9001-cloudinit
EOF
pending 9001
printf '9001 tok\n' > "${PENDING_BAKE_FILE}.created"
record_rc=0
record_setup_bake 2>"$state/log" || record_rc=$?
[[ "$record_rc" == 0 ]] || fail "setup refused to replace a record whose VM is gone: $(cat "$state/log")"
[[ "$(tr -d '[:space:]' < "$PENDING_BAKE_FILE")" == 9100 ]] \
    || fail "the side bake did not take the pending record"
[[ ! -e "${PENDING_BAKE_FILE}.created" ]] || fail "the old created marker survived the new record"
assert_gone local-zfs:base-9001-disk-0 "side setup replaced an unsettled record"
assert_kept local-zfs:base-9000-disk-0 "side setup replaced an unsettled record"
assert_kept local-zfs:vm-9001-cloudinit "side setup replaced an unsettled record"
assert_not_freed local-zfs:base-9000-disk-0 "side setup replaced an unsettled record"
assert_not_freed local-zfs:vm-9001-cloudinit "side setup replaced an unsettled record"

# No marker: the volume was not this bake's disk, so replacing the record leaves it.
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
unset BAKE_VM_CREATED BAKE_RUN_TOKEN
set_volumes <<'EOF'
local-zfs:base-9001-disk-0
EOF
pending 9001
record_rc=0
record_setup_bake 2>"$state/log" || record_rc=$?
[[ "$record_rc" == 0 ]] || fail "a record with no created marker blocked setup: $(cat "$state/log")"
[[ "$(tr -d '[:space:]' < "$PENDING_BAKE_FILE")" == 9100 ]] \
    || fail "a record with no created marker was not replaced"
assert_kept local-zfs:base-9001-disk-0 "no created marker"
assert_not_freed local-zfs:base-9001-disk-0 "no created marker"

# The listing still cannot be read: keep the old record and the marker.
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
unset BAKE_VM_CREATED BAKE_RUN_TOKEN
set_volumes <<'EOF'
local-zfs:base-9001-disk-0
EOF
pending 9001
printf '9001 tok\n' > "${PENDING_BAKE_FILE}.created"
mock_list_fails=1
record_rc=0
record_setup_bake 2>"$state/log" || record_rc=$?
[[ "$record_rc" != 0 ]] || fail "an unreadable volume list let setup replace the record"
[[ "$(tr -d '[:space:]' < "$PENDING_BAKE_FILE")" == 9001 ]] \
    || fail "an unreadable volume list replaced the pending record"
[[ "$(cat "${PENDING_BAKE_FILE}.created")" == "9001 tok" ]] \
    || fail "an unreadable volume list removed the created marker: $(cat "${PENDING_BAKE_FILE}.created" 2>/dev/null)"
assert_kept local-zfs:base-9001-disk-0 "unlistable during setup"
assert_not_freed local-zfs:base-9001-disk-0 "unlistable during setup"
grep -qF 'could not be checked' "$state/log" \
    || fail "the unreadable list was not reported: $(cat "$state/log")"
grep -qF 'runner rebake' "$state/log" \
    || fail "the refusal did not say to run rebake: $(cat "$state/log")"
if [[ -f "$STATE_DIR/bake-leftover-volumes" ]] \
    && grep -q 'base-9001-disk-0' "$STATE_DIR/bake-leftover-volumes"; then
    fail "an unreadable volume list was quarantined: $(cat "$STATE_DIR/bake-leftover-volumes")"
fi

# pvesm free left the volume. It is quarantined, and the side bake proceeds.
reset_case
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
unset BAKE_VM_CREATED BAKE_RUN_TOKEN
set_volumes <<'EOF'
local-zfs:base-9001-disk-0
EOF
printf 'local-zfs:base-9001-disk-0\n' > "$mock_busy"
pending 9001
printf '9001 tok\n' > "${PENDING_BAKE_FILE}.created"
record_rc=0
record_setup_bake 2>"$state/log" || record_rc=$?
[[ "$record_rc" == 0 ]] || fail "a volume pvesm free could not remove blocked setup: $(cat "$state/log")"
[[ "$(tr -d '[:space:]' < "$PENDING_BAKE_FILE")" == 9100 ]] \
    || fail "a stuck volume kept the old pending record"
[[ ! -e "${PENDING_BAKE_FILE}.created" ]] || fail "the old marker stayed after the stuck volume was quarantined"
assert_kept local-zfs:base-9001-disk-0 "stuck volume during setup"
grep -qF "pvesm free 'local-zfs:base-9001-disk-0'" "$state/log" \
    || fail "the stuck volume was not named: $(cat "$state/log")"
grep -qxF 'vmid=9001 volid=local-zfs:base-9001-disk-0' "$STATE_DIR/bake-leftover-volumes" \
    || fail "the stuck volume was not quarantined: $(cat "$STATE_DIR/bake-leftover-volumes" 2>/dev/null)"
: > "$mock_busy"

printf 'bake-preexisting-volume: ok\n'

