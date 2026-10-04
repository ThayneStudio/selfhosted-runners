#!/usr/bin/env bash
# `BAKE_TIMEOUT=<seconds> runner rebake`, as the bake timeout message advises,
# must reach the detached bake. systemctl start cannot pass the caller's
# environment to the unit, so an override has to detach through setsid.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'rebake-detach: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'rebake-detach: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# These globals are read by detach_rebake_from_ssh.
# shellcheck disable=SC2034
{
    REBAKE_UNIT_FILE=$state/github-runner-rebake.service
    REBAKE_LOG_FILE=$state/github-runner-rebake.log
}
: > "$REBAKE_UNIT_FILE"
calls=$state/calls
unset INVOCATION_ID REBAKE_FOREGROUND REBAKE_DETACHED BAKE_TIMEOUT

# Record what each detach path would hand to the detached rebake.
systemctl() { printf 'systemctl %s\n' "$*" >> "$calls"; }
setsid() {
    printf 'setsid BAKE_TIMEOUT=%s REBAKE_DETACHED=%s\n' \
        "$(printenv BAKE_TIMEOUT || printf unset)" "$(printenv REBAKE_DETACHED || printf unset)" >> "$calls"
}

# No override: the installed unit runs the rebake.
: > "$calls"
(detach_rebake_from_ssh) || fail "detaching through the unit failed"
[[ "$(cat "$calls")" == "systemctl start --no-block github-runner-rebake.service" ]] \
    || fail "the rebake did not detach through the unit: $(cat "$calls")"

# An override detaches through setsid, which passes it on.
: > "$calls"
(export BAKE_TIMEOUT=9000; detach_rebake_from_ssh) || fail "detaching with BAKE_TIMEOUT failed"
[[ "$(cat "$calls")" == "setsid BAKE_TIMEOUT=9000 REBAKE_DETACHED=1" ]] \
    || fail "BAKE_TIMEOUT did not reach the detached rebake: $(cat "$calls")"

printf 'rebake-detach: ok\n'
