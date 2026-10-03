#!/usr/bin/env bash
# While a bake runs, qm resize has already reserved the disk. On thick ZFS
# that reservation is the whole 30 GiB, and linked clones writing job data
# can then fill the pool and pause every VM on it. The poll must read free
# space about once a minute, abort below the floor through the caller's
# cleanup, and keep going when the reading cannot be taken.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-free-floor: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bake-free-floor: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by the bake and rebake functions
{
    INSTALL_DIR=$root
    SNIPPETS_DIR=$state/snippets
    VM_STORAGE=local-zfs
    LATEST_RUNNER_VERSION=2.330.0
    TEMPLATE_ID=9000
    STATE_DIR=$state/lib
    PENDING_BAKE_FILE=$STATE_DIR/pending-bake
    PENDING_VERSION_FILE=$STATE_DIR/pending-version
    RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
    REBAKE_UNIT_FILE=$state/github-runner-rebake.service
    REBAKE_LOG_FILE=$state/github-runner-rebake.log
    NETWORK_BRIDGE=vmbr0
}
mkdir -p "$SNIPPETS_DIR" "$STATE_DIR"
: > "$REBAKE_UNIT_FILE"
unset BAKE_FREE_FLOOR_GIB BAKE_MIN_FREE_GIB BAKE_TIMEOUT
unset INVOCATION_ID REBAKE_FOREGROUND REBAKE_DETACHED
gib=1048576

mock_avail=$((100 * gib))
mock_status_fails=0
mock_polls=$state/polls
mock_ready_after=0
mock_stopped=0
mock_destroyed=0
mock_converted=0
printf '0\n' > "$mock_polls"
sleep() { :; }
release_vmid_reservation() { printf '%s\n' "$1" > "$state/released"; }
qm() {
    printf '%s\n' "$*" >> "$state/qm.log"
    case "$1" in
        importdisk) printf "unused0: successfully imported disk '%s:vm-9001-disk-0'\n" "$VM_STORAGE" ;;
        config)
            [[ "$mock_destroyed" == 0 ]] || return 2
            if [[ "$mock_converted" == 1 ]]; then
                printf 'name: ubuntu-cloud-template\nscsi0: %s:base-9001-disk-0,size=30G\ntemplate: 1\n' "$VM_STORAGE"
            else
                printf 'name: ubuntu-cloud-template\nscsi0: %s:vm-9001-disk-0,size=30G\n' "$VM_STORAGE"
            fi
            ;;
        status)
            [[ "$mock_destroyed" == 0 ]] || return 2
            if [[ "$mock_stopped" == 1 ]]; then
                printf 'status: stopped\n'
            else
                printf 'status: running\n'
            fi
            ;;
        shutdown|stop) mock_stopped=1 ;;
        destroy) mock_destroyed=1 ;;
        template) mock_converted=1 ;;
        guest)
            case "${*:4}" in
                *template-setup-complete*)
                    # guest exec runs in a command substitution, so a variable
                    # incremented here would not be visible to the next poll.
                    printf '%s\n' "$(( $(cat "$mock_polls") + 1 ))" > "$mock_polls"
                    if (( mock_ready_after > 0 && $(cat "$mock_polls") >= mock_ready_after )); then
                        printf '{"exitcode":0,"exited":1}\n'
                    else
                        printf '{"exitcode":1,"exited":1}\n'
                    fi
                    ;;
                *baked-runner-version*) printf '{"exitcode":0,"exited":1,"out-data":"2.330.0\\n"}\n' ;;
                *) printf '{"exitcode":0,"exited":1}\n' ;;
            esac
            ;;
        set|resize|start) return 0 ;;
        *) return 1 ;;
    esac
}
pvesm() {
    printf '%s\n' "$*" >> "$state/pvesm.log"
    case "$1" in
        status)
            [[ "$mock_status_fails" == 0 ]] || return 1
            printf 'Name Type Status Total Used Available %%\n'
            printf '%s zfspool active %s %s %s 50.00%%\n' "$VM_STORAGE" \
                $((1000 * gib)) $((1000 * gib - mock_avail)) "$mock_avail"
            ;;
        list) printf 'Volid Format Type Size VMID\n' ;;
        *) return 1 ;;
    esac
}
status_reads() {
    local n
    n=$(grep -c '^status --storage ' "$state/pvesm.log" || true)
    printf '%s' "$n"
}
run_bake() {
    : > "$state/qm.log"
    : > "$state/pvesm.log"
    printf '0\n' > "$mock_polls"
    mock_stopped=0
    mock_destroyed=0
    mock_converted=0
    bake_rc=0
    bake_and_publish_vm 9001 2>"$state/log" || bake_rc=$?
}

# Nine polls is 135s: free space is read at 60s and 120s, not every 15s.
mock_avail=$((100 * gib))
mock_ready_after=9
run_bake
[[ "$bake_rc" == 0 ]] || fail "a bake with space to spare failed: $(tail -n 5 "$state/log")"
[[ "$(status_reads)" == 2 ]] || fail "free space was read $(status_reads) times in 135s, not once a minute"
grep -q '^template 9001$' "$state/qm.log" || fail "a bake with space to spare was not converted"

# Exactly the floor is still enough. One KiB under it aborts.
mock_avail=$((5 * gib))
mock_ready_after=5
run_bake
[[ "$bake_rc" == 0 ]] || fail "exactly 5 GiB free aborted the bake: $(tail -n 5 "$state/log")"
mock_avail=$((5 * gib - 1))
mock_ready_after=0
run_bake
[[ "$bake_rc" != 0 ]] || fail "1 KiB under 5 GiB was accepted"
grep -qF "storage $VM_STORAGE has 4 GiB free, under the 5 GiB floor" "$state/log" \
    || fail "the abort did not name the storage and the free space: $(cat "$state/log")"
if grep -q '^template ' "$state/qm.log"; then fail "qm template ran after the floor abort"; fi
[[ "$(status_reads)" == 1 ]] || fail "the abort read free space $(status_reads) times before 60s"

# The caller's EXIT trap is the normal failure path: the partial VM is
# destroyed and its VMID reservation released.
mock_avail=$((4 * gib))
mock_ready_after=0
: > "$state/qm.log"
: > "$state/pvesm.log"
: > "$state/released"
printf '9001\n' > "$PENDING_BAKE_FILE"
rm -f "$PENDING_VERSION_FILE"
printf '0\n' > "$mock_polls"
mock_stopped=0
mock_destroyed=0
mock_converted=0
trap_rc=0
(
    set -e
    trap cleanup_rebake EXIT
    BAKE_VMID=9001
    REBAKE_PUBLISHED=0
    bake_and_publish_vm 9001
) 2>"$state/log" || trap_rc=$?
[[ "$trap_rc" != 0 ]] || fail "the floor abort reported success"
grep -qF "storage $VM_STORAGE has 4 GiB free, under the 5 GiB floor" "$state/log" \
    || fail "the trapped abort did not name the storage: $(cat "$state/log")"
grep -q '^destroy 9001$' "$state/qm.log" || fail "the caller's cleanup did not destroy the partial VM"
[[ "$(cat "$state/released")" == 9001 ]] || fail "the VMID reservation was not released"
[[ ! -e "$PENDING_BAKE_FILE" ]] || fail "the destroyed bake stayed recorded"
if grep -q '^template ' "$state/qm.log"; then fail "qm template ran on the aborted bake"; fi
if grep -q '^destroy 9000$' "$state/qm.log"; then fail "the abort destroyed the live template"; fi

# A reading that cannot be taken does not abort a guest that finishes.
mock_status_fails=1
mock_avail=0
mock_ready_after=5
run_bake
[[ "$bake_rc" == 0 ]] || fail "an unreadable free-space reading aborted the bake: $(tail -n 5 "$state/log")"
grep -qF "Could not read free space on storage $VM_STORAGE during the bake; continuing" "$state/log" \
    || fail "the unreadable reading was not warned: $(cat "$state/log")"
grep -q '^template 9001$' "$state/qm.log" || fail "the bake did not finish after an unreadable reading"
mock_status_fails=0

# BAKE_FREE_FLOOR_GIB replaces the floor. 0 turns the check off, so a full
# storage is not even queried.
mock_avail=$((10 * gib))
mock_ready_after=5
BAKE_FREE_FLOOR_GIB=20
run_bake
[[ "$bake_rc" != 0 ]] || fail "BAKE_FREE_FLOOR_GIB=20 accepted 10 GiB free"
grep -qF "under the 20 GiB floor" "$state/log" || fail "the override floor was not reported: $(cat "$state/log")"
unset BAKE_FREE_FLOOR_GIB
mock_avail=$((20 * gib))
BAKE_FREE_FLOOR_GIB=20
mock_ready_after=5
run_bake
[[ "$bake_rc" == 0 ]] || fail "exactly BAKE_FREE_FLOOR_GIB=20 aborted the bake: $(tail -n 5 "$state/log")"
unset BAKE_FREE_FLOOR_GIB
mock_avail=0
mock_ready_after=8
BAKE_FREE_FLOOR_GIB=0
run_bake
[[ "$bake_rc" == 0 ]] || fail "BAKE_FREE_FLOOR_GIB=0 aborted the bake: $(tail -n 5 "$state/log")"
[[ "$(status_reads)" == 0 ]] || fail "BAKE_FREE_FLOOR_GIB=0 still read free space"
unset BAKE_FREE_FLOOR_GIB

# A bad floor is refused before a VM exists, and before rebake detaches.
: > "$state/qm.log"
: > "$state/pvesm.log"
create_rc=0
(BAKE_FREE_FLOOR_GIB=lots create_bake_vm 9001) 2>"$state/log" || create_rc=$?
[[ "$create_rc" != 0 ]] || fail "create_bake_vm accepted BAKE_FREE_FLOOR_GIB=lots"
[[ ! -s "$state/qm.log" ]] || fail "a bad floor created a VM: $(cat "$state/qm.log")"
[[ ! -s "$state/pvesm.log" ]] || fail "a bad floor queried storage: $(cat "$state/pvesm.log")"
grep -qF "BAKE_FREE_FLOOR_GIB must be a whole number of GiB, not 'lots'" "$state/log" \
    || fail "the bad floor was not reported: $(cat "$state/log")"
create_rc=0
(BAKE_FREE_FLOOR_GIB=5G create_bake_vm 9001) 2>"$state/log" || create_rc=$?
[[ "$create_rc" != 0 ]] || fail "create_bake_vm accepted BAKE_FREE_FLOOR_GIB=5G"

require_root() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$state/detach"; }
setsid() {
    printf 'setsid BAKE_FREE_FLOOR_GIB=%s\n' \
        "$(printenv BAKE_FREE_FLOOR_GIB || printf unset)" >> "$state/detach"
}
: > "$state/detach"
rebake_rc=0
(BAKE_FREE_FLOOR_GIB=lots rebake_main) 2>"$state/log" || rebake_rc=$?
[[ "$rebake_rc" != 0 ]] || fail "runner rebake accepted BAKE_FREE_FLOOR_GIB=lots"
[[ ! -s "$state/detach" ]] || fail "a bad floor detached: $(cat "$state/detach")"
grep -qF "BAKE_FREE_FLOOR_GIB must be a whole number of GiB, not 'lots'" "$state/log" \
    || fail "rebake did not report the bad floor: $(cat "$state/log")"
: > "$state/detach"
detach_rc=0
(BAKE_FREE_FLOOR_GIB=3 detach_rebake_from_ssh) 2>"$state/log" || detach_rc=$?
[[ "$detach_rc" == 0 ]] || fail "detaching with BAKE_FREE_FLOOR_GIB=3 failed: $(cat "$state/log")"
[[ "$(cat "$state/detach")" == "setsid BAKE_FREE_FLOOR_GIB=3" ]] \
    || fail "BAKE_FREE_FLOOR_GIB did not reach the detached rebake: $(cat "$state/detach")"

printf 'bake-free-floor: ok\n'
