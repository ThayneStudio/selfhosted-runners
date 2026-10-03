#!/usr/bin/env bash
# BAKE_TIMEOUT is whole seconds. bash reads "2h" as a bad number, the poll's
# timeout test then fails on every pass, and a detached `runner rebake` also
# escapes the unit's TimeoutStartSec, so a stalled guest held the bake forever.
# A bad value must be refused before any VM work, and before a rebake detaches.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bakerebake2-bake-timeout: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bakerebake2-bake-timeout: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by the bake and rebake functions
{
    NETWORK_BRIDGE=vmbr0
    VM_STORAGE=local-zfs
    LATEST_RUNNER_VERSION=2.330.0
    REBAKE_UNIT_FILE=$state/github-runner-rebake.service
    REBAKE_LOG_FILE=$state/github-runner-rebake.log
}
: > "$REBAKE_UNIT_FILE"
unset INVOCATION_ID REBAKE_FOREGROUND REBAKE_DETACHED BAKE_TIMEOUT BAKE_MIN_FREE_GIB
calls=$state/calls
log=$state/log
bad_values=(2h 90m 1.5h 0 0900 -5 ' 7200' abc)

# Every host command is recorded. The import fails, so a bake that gets past
# the check stops at its first VM step instead of polling.
qm() {
    printf 'qm %s\n' "$*" >> "$calls"
    [[ "$1" == create ]]
}
pvesm() {
    printf 'pvesm %s\n' "$*" >> "$calls"
    [[ "$1" == status ]] || return 1
    printf 'Name Type Status Total Used Available %%\n'
    printf 'local-zfs lvmthin active 1000000000 100000000 900000000 10.00%%\n'
}
pvesh() { printf '{"type":"lvmthin"}\n'; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$calls"; }
setsid() { printf 'setsid BAKE_TIMEOUT=%s\n' "$(printenv BAKE_TIMEOUT || printf unset)" >> "$calls"; }
require_root() { :; }
sleep() { :; }

# bake_and_publish_vm reads BAKE_TIMEOUT for its poll.
bake() {
    : > "$calls"
    bake_rc=0
    if [[ "$1" == unset ]]; then
        (bake_and_publish_vm 9001) 2>"$log" || bake_rc=$?
    else
        (BAKE_TIMEOUT="$1" bake_and_publish_vm 9001) 2>"$log" || bake_rc=$?
    fi
}
for value in "${bad_values[@]}"; do
    bake "$value"
    [[ "$bake_rc" != 0 ]] || fail "bake_and_publish_vm accepted BAKE_TIMEOUT='$value'"
    [[ ! -s "$calls" ]] || fail "BAKE_TIMEOUT='$value' reached the VM: $(cat "$calls")"
    grep -q 'BAKE_TIMEOUT must be a whole number of seconds' "$log" \
        || fail "BAKE_TIMEOUT='$value' was not reported: $(cat "$log")"
done
for value in unset '' 7200; do
    bake "$value"
    grep -q '^qm importdisk 9001 ' "$calls" || fail "BAKE_TIMEOUT='$value' did not reach the import: $(cat "$log")"
    if grep -q 'BAKE_TIMEOUT must be' "$log"; then fail "BAKE_TIMEOUT='$value' was refused"; fi
done

# setup creates the bake VM through create_bake_vm: no VM for a bad value.
create() {
    : > "$calls"
    create_rc=0
    (BAKE_TIMEOUT="$1" create_bake_vm 9001) 2>"$log" || create_rc=$?
}
create 2h
[[ "$create_rc" != 0 ]] || fail "create_bake_vm accepted BAKE_TIMEOUT=2h"
if grep -q '^qm create' "$calls"; then fail "create_bake_vm created a VM with BAKE_TIMEOUT=2h"; fi
create 7200
[[ "$create_rc" == 0 ]] || fail "create_bake_vm refused BAKE_TIMEOUT=7200: $(cat "$log")"
grep -q '^qm create 9001 ' "$calls" || fail "create_bake_vm did not create the VM with BAKE_TIMEOUT=7200"

# `runner rebake` refuses before it detaches: a detached rebake would report
# the refusal only in its log, after "Rebake started".
rebake() {
    : > "$calls"
    rebake_rc=0
    (BAKE_TIMEOUT="$1" rebake_main) 2>"$log" || rebake_rc=$?
}
for value in "${bad_values[@]}"; do
    rebake "$value"
    [[ "$rebake_rc" != 0 ]] || fail "runner rebake accepted BAKE_TIMEOUT='$value'"
    [[ ! -s "$calls" ]] || fail "BAKE_TIMEOUT='$value' detached: $(cat "$calls")"
    grep -q 'BAKE_TIMEOUT must be a whole number of seconds' "$log" \
        || fail "runner rebake did not report BAKE_TIMEOUT='$value': $(cat "$log")"
done
rebake 10800
[[ "$rebake_rc" == 0 ]] || fail "runner rebake refused BAKE_TIMEOUT=10800: $(cat "$log")"
[[ "$(cat "$calls")" == "setsid BAKE_TIMEOUT=10800" ]] \
    || fail "BAKE_TIMEOUT=10800 did not detach through setsid: $(cat "$calls")"

printf 'bakerebake2-bake-timeout: ok\n'
