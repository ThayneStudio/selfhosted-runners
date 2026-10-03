#!/usr/bin/env bash
# qm template renames vm-<vmid>-disk-N to base-<vmid>-disk-N before it
# rewrites the config, and can fail there for lack of space (it also writes
# `template: 1` first and exits 0 when the worker fails). The config still
# lists the old disk, so qm destroy does not free the base volume. The bake
# failure path must destroy that VM and free a base-<vmid>-disk-N or
# vm-<vmid>-disk-N of its own VMID left on VM_STORAGE, and nothing else.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-template-leak: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'bake-template-leak: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by cleanup_rebake, cleanup_bake and the free
{
    STATE_DIR=$state/lib
    PENDING_BAKE_FILE=$STATE_DIR/pending-bake
    PENDING_VERSION_FILE=$STATE_DIR/pending-version
    RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
    PVE_NODES_DIR=$state/nodes
    VM_STORAGE=local-zfs
    TEMPLATE_ID=9000
    REBAKE_PUBLISHED=0
    LIVE_TEMPLATE_ID=9000
}
mkdir -p "$STATE_DIR" "$PVE_NODES_DIR/pve1/qemu-server" "$PVE_NODES_DIR/pve1/lxc"
actions=$state/actions
frees=$state/frees
mock_storage=$state/storage
mock_busy=$state/busy
destroy_fails=0
: > "$actions"
: > "$frees"
: > "$mock_storage"
: > "$mock_busy"
printf '9005\n' > "$RETIRED_TEMPLATES_FILE"

conf_of() { printf '%s/pve1/qemu-server/%s.conf' "$PVE_NODES_DIR" "$1"; }
half_conf() {
    printf 'name: ubuntu-cloud-template\nscsi0: %s:vm-%s-disk-0,size=30G\ntemplate: 1\n' \
        "$VM_STORAGE" "$1"
}
write_half() { half_conf "$1" > "$(conf_of "$1")"; }
set_volumes() { cat > "$mock_storage"; }
pending() {
    printf '%s\n' "$1" > "$PENDING_BAKE_FILE"
    rm -f "${PENDING_BAKE_FILE}.created"
}
mark_created() { printf '%s\n' "$1" > "${PENDING_BAKE_FILE}.created"; }
record_kept() { [[ -f "$PENDING_BAKE_FILE" ]]; }
assert_gone() {
    if grep -qxF "$1" "$mock_storage"; then fail "$2: $1 was not freed"; fi
}
assert_kept() {
    grep -qxF "$1" "$mock_storage" || fail "$2: freed $1"
}
assert_freed() {
    grep -qxF "free $1" "$frees" || fail "$2: pvesm free was not run for $1"
}
assert_not_freed() {
    if grep -qxF "free $1" "$frees"; then fail "$2: freed $1"; fi
}

qm() {
    printf '%s\n' "$*" >> "$actions"
    case "$1" in
        status) [[ -f "$(conf_of "$2")" ]] ;;
        config)
            [[ -f "$(conf_of "$2")" ]] || return 2
            cat "$(conf_of "$2")"
            ;;
        stop) return 0 ;;
        destroy)
            [[ "$destroy_fails" == 0 ]] || return 1
            rm -f "$(conf_of "$2")"
            ;;
        *) return 1 ;;
    esac
}
# No guest is in the cluster inventory unless a test says so. An empty list
# is what vm_confirmed_absent requires.
pvesh() { printf '[]\n'; }
pvesm() {
    local volume
    case "$1" in
        list)
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
        *) return 1 ;;
    esac
}
release_vmid_reservation() { printf 'release %s\n' "$1" >> "$actions"; }
run_cleanup() {
    : > "$actions"
    : > "$frees"
    cleanup_rc=0
    # shellcheck disable=SC2034 # cleanup_rebake reads both
    ( set -e; BAKE_VMID=$1; REBAKE_PUBLISHED=0; cleanup_rebake "${2:-1}" ) 2>"$state/log" || cleanup_rc=$?
}
run_recover() {
    : > "$actions"
    : > "$frees"
    recover_rc=0
    recover_pending_bake 2>"$state/log" || recover_rc=$?
}
run_setup_cleanup() {
    : > "$actions"
    : > "$frees"
    ( cleanup_bake ) 2>"$state/log"
}

# The leaked set: the bake's own disks (the base name the conversion wrote,
# and the vm- name the config still lists), plus disks that must be left
# alone. cloudinit is not a disk-N. The linked-clone path names this VMID
# but is a child of the live template.
leak_set() {
    set_volumes <<'EOF'
local-zfs:base-9000-disk-0
local-zfs:base-9000-disk-0/vm-9001-disk-0
local-zfs:base-9001-disk-0
local-zfs:base-9001-disk-1
local-zfs:base-9005-disk-0
local-zfs:vm-9001-cloudinit
local-zfs:vm-9001-disk-0
local-zfs:vm-9002-disk-0
EOF
}
assert_decoys() {
    local where="$1"
    assert_kept local-zfs:base-9000-disk-0 "$where"
    assert_kept 'local-zfs:base-9000-disk-0/vm-9001-disk-0' "$where"
    assert_kept local-zfs:base-9005-disk-0 "$where"
    assert_kept local-zfs:vm-9001-cloudinit "$where"
    assert_kept local-zfs:vm-9002-disk-0 "$where"
    assert_not_freed local-zfs:base-9000-disk-0 "$where"
    assert_not_freed 'local-zfs:base-9000-disk-0/vm-9001-disk-0' "$where"
    assert_not_freed local-zfs:base-9005-disk-0 "$where"
    assert_not_freed local-zfs:vm-9001-cloudinit "$where"
    assert_not_freed local-zfs:vm-9002-disk-0 "$where"
}
assert_bake_disks_freed() {
    local where="$1"
    assert_gone local-zfs:base-9001-disk-0 "$where"
    assert_gone local-zfs:base-9001-disk-1 "$where"
    assert_gone local-zfs:vm-9001-disk-0 "$where"
    assert_freed local-zfs:base-9001-disk-0 "$where"
    assert_freed local-zfs:vm-9001-disk-0 "$where"
    assert_decoys "$where"
}

# cleanup_rebake: template: 1, config still names vm-9001-disk-0, the base
# volume is already on the storage.
VM_STORAGE=local-zfs
TEMPLATE_ID=9000
write_half 9001
leak_set
pending 9001
run_cleanup 9001
[[ "$cleanup_rc" != 0 ]] || fail "cleanup_rebake reported success after a failed bake"
grep -qx 'destroy 9001' "$actions" || fail "cleanup_rebake did not destroy the half-converted VM"
[[ ! -f "$(conf_of 9001)" ]] || fail "the bake VM config survived destroy"
assert_bake_disks_freed "cleanup_rebake"
if record_kept; then fail "cleanup_rebake kept the record after the volumes were freed"; fi
grep -q 'release 9001' "$actions" || fail "cleanup_rebake did not release the VMID reservation"

# A volume pvesm free does not remove is logged and the record is dropped.
# Keeping it would fail every later rebake. The next run does not retry it.
write_half 9001
leak_set
printf 'local-zfs:base-9001-disk-0\n' > "$mock_busy"
pending 9001
run_cleanup 9001
[[ "$cleanup_rc" != 0 ]] || fail "a leftover volume was reported freed"
assert_kept local-zfs:base-9001-disk-0 "busy free"
assert_gone local-zfs:vm-9001-disk-0 "busy free"
if record_kept; then fail "a volume pvesm free could not remove kept the pending record"; fi
grep -qF "pvesm free 'local-zfs:base-9001-disk-0'" "$state/log" \
    || fail "the remaining volume was not named: $(cat "$state/log")"
grep -qF 'Later rebakes will not retry it' "$state/log" \
    || fail "the operator was not told the volume will not be retried: $(cat "$state/log")"
grep -qxF 'vmid=9001 volid=local-zfs:base-9001-disk-0' "$STATE_DIR/bake-leftover-volumes" \
    || fail "the remaining volume was not quarantined: $(cat "$STATE_DIR/bake-leftover-volumes" 2>/dev/null)"
# The next rebake finds no record, so it proceeds, and the volume stays.
run_recover
[[ "$recover_rc" == 0 ]] || fail "recover failed after a volume was left for the operator: $(cat "$state/log")"
if record_kept; then fail "recover recreated the dropped record"; fi
assert_kept local-zfs:base-9001-disk-0 "recover does not retry a volume pvesm free left"
assert_decoys "recover does not retry"
: > "$mock_busy"

# A cleanup entered with status 0 (a signal can leave $? at 0) still fails
# this run when a volume is left, and still drops the record.
write_half 9001
leak_set
printf 'local-zfs:base-9001-disk-0\n' > "$mock_busy"
pending 9001
run_cleanup 9001 0
[[ "$cleanup_rc" != 0 ]] || fail "a leftover volume let cleanup report success"
if record_kept; then fail "status 0 kept the record of a volume pvesm free left"; fi
assert_kept local-zfs:base-9001-disk-0 "status 0 busy free"
: > "$mock_busy"

# recover destroys a half-converted VM whose config still lists the old disk.
write_half 9001
leak_set
pending 9001
run_recover
[[ "$recover_rc" == 0 ]] || fail "recover failed on a half-converted VM: $(cat "$state/log")"
grep -qx 'destroy 9001' "$actions" || fail "recover did not destroy the half-converted VM"
[[ "$TEMPLATE_ID" == 9000 ]] || fail "recover published the half-converted VM"
assert_bake_disks_freed "recover"
if record_kept; then fail "recover kept the record of a destroyed VM"; fi

# The VM is already gone (destroy succeeded, the process died before the
# free). The created marker is how the next run knows the base volume is
# this bake's.
rm -f "$(conf_of 9001)"
leak_set
pending 9001
mark_created 9001
run_recover
[[ "$recover_rc" == 0 ]] || fail "recover failed on an absent VM with a leaked volume: $(cat "$state/log")"
if grep -q '^destroy ' "$actions"; then fail "recover destroyed a VM that was already gone"; fi
assert_bake_disks_freed "absent recover"
if record_kept; then fail "absent recover kept the record after the free"; fi

# A destroy that fails leaves the config, and must not free under it.
write_half 9001
leak_set
pending 9001
destroy_fails=1
run_cleanup 9001
destroy_fails=0
[[ "$cleanup_rc" != 0 ]] || fail "a failed destroy was reported as success"
[[ -f "$(conf_of 9001)" ]] || fail "a failed destroy removed the config"
assert_kept local-zfs:base-9001-disk-0 "failed destroy"
assert_kept local-zfs:vm-9001-disk-0 "failed destroy"
[[ ! -s "$frees" ]] || fail "a failed destroy freed volumes: $(cat "$frees")"
record_kept || fail "a failed destroy dropped the pending record"

# The live template and a retired template are not this bake's leftovers,
# even when asked for by VMID. A VMID that still has a guest config, or an
# unreadable /etc/pve, is left alone too.
set_volumes <<'EOF'
local-zfs:base-9000-disk-0
EOF
: > "$frees"
if ! free_bake_leftover_volumes 9000 9000 2>"$state/log"; then
    fail "refusing the live template reported a remaining volume"
fi
assert_kept local-zfs:base-9000-disk-0 "live template"
[[ ! -s "$frees" ]] || fail "the live template's volume was freed"
set_volumes <<'EOF'
local-zfs:base-9005-disk-0
EOF
if ! free_bake_leftover_volumes 9005 9000 2>"$state/log"; then
    fail "refusing a retired template reported a remaining volume"
fi
assert_kept local-zfs:base-9005-disk-0 "retired template"
[[ ! -s "$frees" ]] || fail "a retired template's volume was freed"
write_half 9001
set_volumes <<'EOF'
local-zfs:base-9001-disk-0
EOF
free_rc=0
free_bake_leftover_volumes 9001 9000 2>"$state/log" || free_rc=$?
[[ "$free_rc" != 0 ]] || fail "a VMID with a guest config was treated as free"
assert_kept local-zfs:base-9001-disk-0 "guest config"
grep -qF 'still has a guest config' "$state/log" || fail "the guest config was not reported"
rm -f "$(conf_of 9001)"
saved_nodes=$PVE_NODES_DIR
PVE_NODES_DIR=$state/cfs-down
mkdir -p "$PVE_NODES_DIR"
free_rc=0
free_bake_leftover_volumes 9001 9000 2>"$state/log" || free_rc=$?
[[ "$free_rc" != 0 ]] || fail "an unreadable /etc/pve was treated as no guest config"
assert_kept local-zfs:base-9001-disk-0 "pmxcfs down"
grep -qF 'pmxcfs is not serving /etc/pve' "$state/log" || fail "pmxcfs being down was not reported"
pending 9001
mark_created 9001
run_recover
[[ "$recover_rc" != 0 ]] || fail "recover dropped a record while pmxcfs was down"
record_kept || fail "recover dropped the record while pmxcfs was down"
assert_kept local-zfs:base-9001-disk-0 "recover while pmxcfs is down"
PVE_NODES_DIR=$saved_nodes

# Directory storage appends the format. The VMID directory is part of the name.
VM_STORAGE=local
write_half 9001
set_volumes <<'EOF'
local:9000/base-9000-disk-0.raw
local:9001/base-9001-disk-0.raw
local:9001/vm-9001-disk-0.qcow2
local:9002/vm-9002-disk-0.raw
EOF
pending 9001
run_cleanup 9001
assert_gone 'local:9001/base-9001-disk-0.raw' "dir storage"
assert_gone 'local:9001/vm-9001-disk-0.qcow2' "dir storage"
assert_kept 'local:9000/base-9000-disk-0.raw' "dir storage"
assert_kept 'local:9002/vm-9002-disk-0.raw' "dir storage"
VM_STORAGE=local-zfs

# setup bakes TEMPLATE_ID itself. Beside a live template that id is the new
# VM, not the one still serving; a first bake has no other template. Either
# way the bake's own leftover is freed and the live template's disk is not.
VM_STORAGE=local-zfs
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
write_half 9100
set_volumes <<'EOF'
local-zfs:base-9000-disk-0
local-zfs:base-9100-disk-0
local-zfs:vm-9100-disk-0
EOF
pending 9100
run_setup_cleanup
[[ ! -f "$(conf_of 9100)" ]] || fail "cleanup_bake left the half-converted VM"
assert_gone local-zfs:base-9100-disk-0 "setup beside a live template"
assert_gone local-zfs:vm-9100-disk-0 "setup beside a live template"
assert_kept local-zfs:base-9000-disk-0 "setup beside a live template"
assert_not_freed local-zfs:base-9000-disk-0 "setup beside a live template"
if record_kept; then fail "cleanup_bake kept the record after the free"; fi

# A first bake: the shell's TEMPLATE_ID is the bake VM, and there is no live one.
LIVE_TEMPLATE_ID=
TEMPLATE_ID=9100
write_half 9100
set_volumes <<'EOF'
local-zfs:base-9100-disk-0
EOF
pending 9100
run_setup_cleanup
assert_gone local-zfs:base-9100-disk-0 "setup first bake"
if record_kept; then fail "a first bake kept its record after the free"; fi

# The VM is already gone and this bake never created it. A volume that was
# already on the VMID stays, and the record goes.
rm -f "$(conf_of 9100)"
set_volumes <<'EOF'
local-zfs:base-9000-disk-0
local-zfs:base-9100-disk-0
EOF
pending 9100
run_setup_cleanup
if grep -q '^destroy ' "$actions"; then fail "setup destroyed a VM that was already gone"; fi
assert_kept local-zfs:base-9100-disk-0 "setup absent, bake never created"
assert_kept local-zfs:base-9000-disk-0 "setup absent, bake never created"
assert_not_freed local-zfs:base-9100-disk-0 "setup absent, bake never created"
assert_not_freed local-zfs:base-9000-disk-0 "setup absent, bake never created"
if record_kept; then fail "setup kept the record of a bake that never created a VM"; fi

# Once this bake's qm create had succeeded, the leaked base volume is freed.
# A volume pvesm free cannot remove is logged and the record is dropped.
pending 9100
mark_created 9100
run_setup_cleanup
assert_gone local-zfs:base-9100-disk-0 "setup absent after create"
assert_kept local-zfs:base-9000-disk-0 "setup absent after create"
assert_not_freed local-zfs:base-9000-disk-0 "setup absent after create"
if record_kept; then fail "setup kept the record after freeing an absent VM's volume"; fi
[[ ! -e "${PENDING_BAKE_FILE}.created" ]] || fail "setup left the created marker after the free"
printf 'local-zfs:base-9100-disk-0\n' > "$mock_busy"
set_volumes <<'EOF'
local-zfs:base-9100-disk-0
EOF
pending 9100
mark_created 9100
run_setup_cleanup
assert_kept local-zfs:base-9100-disk-0 "setup absent busy"
if record_kept; then fail "setup kept the record of a volume pvesm free could not remove"; fi
grep -qF "pvesm free 'local-zfs:base-9100-disk-0'" "$state/log" \
    || fail "setup did not name the volume left behind: $(cat "$state/log")"
: > "$mock_busy"

# The same cleanup drops the record when the volume cannot be freed after
# destroy, and does not free when destroy fails.
write_half 9100
set_volumes <<'EOF'
local-zfs:base-9100-disk-0
EOF
printf 'local-zfs:base-9100-disk-0\n' > "$mock_busy"
pending 9100
run_setup_cleanup
assert_kept local-zfs:base-9100-disk-0 "setup busy free"
if record_kept; then fail "setup kept the record of a volume pvesm free could not remove after destroy"; fi
grep -qF "pvesm free 'local-zfs:base-9100-disk-0'" "$state/log" \
    || fail "setup did not report the remaining volume: $(cat "$state/log")"
: > "$mock_busy"
write_half 9100
set_volumes <<'EOF'
local-zfs:base-9100-disk-0
EOF
pending 9100
destroy_fails=1
run_setup_cleanup
destroy_fails=0
[[ -f "$(conf_of 9100)" ]] || fail "setup removed a VM it could not destroy"
assert_kept local-zfs:base-9100-disk-0 "setup failed destroy"
[[ ! -s "$frees" ]] || fail "setup freed volumes after a failed destroy: $(cat "$frees")"
record_kept || fail "setup dropped the record after a failed destroy"

# An absent pending id that is the live template is not an excuse to free
# its base volume.
TEMPLATE_ID=9000
LIVE_TEMPLATE_ID=
rm -f "$(conf_of 9000)" "$(conf_of 9100)"
set_volumes <<'EOF'
local-zfs:base-9000-disk-0
EOF
pending 9000
run_recover
[[ "$recover_rc" == 0 ]] || fail "recover failed on an absent live template id"
assert_kept local-zfs:base-9000-disk-0 "absent live template"
[[ ! -s "$frees" ]] || fail "an absent live template id had a volume freed"
if record_kept; then fail "the stale record of the live template id was kept"; fi

printf 'bake-template-leak: ok\n'
