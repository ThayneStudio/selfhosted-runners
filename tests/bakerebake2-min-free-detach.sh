#!/usr/bin/env bash
# The free-space refusal tells the operator to set BAKE_MIN_FREE_GIB. A plain
# `BAKE_MIN_FREE_GIB=<GiB> runner rebake` detached through the unit, which
# never sees the caller's environment, so the override was dropped and the
# bake refused again. It must detach through setsid, which keeps it; a bad
# value must be refused before detaching; and the refusal must name a command
# that applies the override.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bakerebake2-min-free-detach: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bakerebake2-min-free-detach: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by the bake and rebake functions
{
    NETWORK_BRIDGE=vmbr0
    VM_STORAGE=local-lvm
    LATEST_RUNNER_VERSION=2.330.0
    REBAKE_UNIT_FILE=$state/github-runner-rebake.service
    REBAKE_LOG_FILE=$state/github-runner-rebake.log
}
: > "$REBAKE_UNIT_FILE"
unset INVOCATION_ID REBAKE_FOREGROUND REBAKE_DETACHED BAKE_TIMEOUT BAKE_MIN_FREE_GIB
calls=$state/calls
log=$state/log
gib=1048576

# Record what each detach path hands to the detached rebake.
systemctl() { printf 'systemctl %s\n' "$*" >> "$calls"; }
setsid() {
    printf 'setsid BAKE_MIN_FREE_GIB=%s REBAKE_DETACHED=%s\n' \
        "$(printenv BAKE_MIN_FREE_GIB || printf unset)" "$(printenv REBAKE_DETACHED || printf unset)" >> "$calls"
}
require_root() { :; }
detach() {
    : > "$calls"
    detach_rc=0
    if [[ "$1" == unset ]]; then
        (detach_rebake_from_ssh) 2>"$log" || detach_rc=$?
    else
        (BAKE_MIN_FREE_GIB="$1" detach_rebake_from_ssh) 2>"$log" || detach_rc=$?
    fi
}

# No override: the installed unit runs the rebake.
detach unset
[[ "$detach_rc" == 0 ]] || fail "detaching through the unit failed: $(cat "$log")"
[[ "$(cat "$calls")" == "systemctl start --no-block github-runner-rebake.service" ]] \
    || fail "the rebake did not detach through the unit: $(cat "$calls")"

# The override reaches the detached rebake, including 0, which skips the check.
for value in 0 20; do
    detach "$value"
    [[ "$detach_rc" == 0 ]] || fail "detaching with BAKE_MIN_FREE_GIB=$value failed: $(cat "$log")"
    [[ "$(cat "$calls")" == "setsid BAKE_MIN_FREE_GIB=$value REBAKE_DETACHED=1" ]] \
        || fail "BAKE_MIN_FREE_GIB=$value did not reach the detached rebake: $(cat "$calls")"
done

# A bad value is refused in the caller's terminal, not in the detached log.
for value in lots 20G -1; do
    : > "$calls"
    rebake_rc=0
    (BAKE_MIN_FREE_GIB="$value" rebake_main) 2>"$log" || rebake_rc=$?
    [[ "$rebake_rc" != 0 ]] || fail "runner rebake accepted BAKE_MIN_FREE_GIB=$value"
    [[ ! -s "$calls" ]] || fail "BAKE_MIN_FREE_GIB=$value detached: $(cat "$calls")"
    grep -q 'BAKE_MIN_FREE_GIB must be a whole number of GiB' "$log" \
        || fail "BAKE_MIN_FREE_GIB=$value was not reported: $(cat "$log")"
done

# The refusals name the override as a command prefix, which the setsid path
# and setup's foreground run both pass on.
mock_row=""
pvesm() {
    [[ "$1" == status ]] || return 1
    printf 'Name Type Status Total Used Available %%\n'
    [[ -z "$mock_row" ]] || printf '%s\n' "$mock_row"
}
qm() { printf 'qm %s\n' "$*" >> "$calls"; }
refused() {
    : > "$calls"
    if create_bake_vm 9001 2>"$log"; then fail "$1: the bake VM was created"; fi
    grep -qF "$2" "$log" || fail "$1: the refusal does not name '$2': $(cat "$log")"
}
mock_row="local-lvm lvmthin active $((500 * gib)) $((478 * gib)) $((22 * gib)) 95.60%"
refused "22 GiB free" 'BAKE_MIN_FREE_GIB=<GiB> runner rebake (or runner setup)'
mock_row="local-lvm lvmthin inactive 0 0 0 0.00%"
refused "inactive storage" 'BAKE_MIN_FREE_GIB=0 runner rebake (or runner setup)'
# The named override then admits the bake.
mock_row="local-lvm lvmthin active $((500 * gib)) $((478 * gib)) $((22 * gib)) 95.60%"
: > "$calls"
(BAKE_MIN_FREE_GIB=20 create_bake_vm 9001) 2>"$log" || fail "BAKE_MIN_FREE_GIB=20 did not admit the bake: $(cat "$log")"
grep -q '^qm create 9001 ' "$calls" || fail "BAKE_MIN_FREE_GIB=20 did not create the bake VM"

printf 'bakerebake2-min-free-detach: ok\n'
