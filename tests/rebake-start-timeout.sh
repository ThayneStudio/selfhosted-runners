#!/usr/bin/env bash
# The rebake oneshot's start timeout has to stay an hour above BAKE_TIMEOUT.
# The poll limit does not cover the image download or qm importdisk, and with
# no finite cap a hang holds the rebake lock so the daily timer never runs.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'rebake-start-timeout: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'rebake-start-timeout: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by rebake_main and the drop-in writer
{
    CONFIG_FILE=$state/github-runners.conf
    REBAKE_UNIT_FILE=$state/github-runner-rebake.service
    REBAKE_LOG_FILE=$state/github-runner-rebake.log
    REBAKE_LOCK_FILE=$state/rebake.lock
    REBAKE_DROPIN_FILE=$state/timeout.conf
    NETWORK_BRIDGE=vmbr0
    VM_STORAGE=local-zfs
    TEMPLATE_ID=9000
}
: > "$REBAKE_UNIT_FILE"
calls=$state/calls
: > "$calls"
unset INVOCATION_ID REBAKE_FOREGROUND REBAKE_DETACHED BAKE_TIMEOUT BAKE_MIN_FREE_GIB

require_root() { :; }
flock() { return 0; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$calls"; }
setsid() { printf 'setsid\n' >> "$calls"; }

write_conf() {
    cat > "$CONFIG_FILE" <<EOF
NETWORK_BRIDGE=vmbr0
VM_STORAGE=local-zfs
TEMPLATE_ID=9000
BAKE_TIMEOUT=$1
BAKE_MIN_FREE_GIB=$2
EOF
}

# The unit's own cap is the default poll limit plus the hour of headroom.
grep -qx 'TimeoutStartSec=9000' "$root/templates/github-runner-rebake.service" \
    || fail "the rebake unit's default TimeoutStartSec is not 9000"
grep -qx 'TimeoutStopSec=180' "$root/templates/github-runner-rebake.service" \
    || fail "TimeoutStopSec no longer gives cleanup time to destroy a partial VM"
grep -qx 'KillMode=mixed' "$root/templates/github-runner-rebake.service" \
    || fail "KillMode=mixed was dropped"

write_conf 7200 0
# A one-run environment value must not be what the service's cap is built from.
BAKE_TIMEOUT=100
write_rebake_timeout_dropin
unset BAKE_TIMEOUT
grep -qx 'TimeoutStartSec=10800' "$REBAKE_DROPIN_FILE" \
    || fail "the drop-in was not an hour above the conf BAKE_TIMEOUT: $(cat "$REBAKE_DROPIN_FILE")"
grep -q 'systemctl daemon-reload' "$calls" \
    || fail "writing the drop-in did not reload systemd: $(cat "$calls")"

# No BAKE_TIMEOUT in the conf: the same default the unit file carries.
cat > "$CONFIG_FILE" <<'EOF'
NETWORK_BRIDGE=vmbr0
VM_STORAGE=local-zfs
TEMPLATE_ID=9000
EOF
write_rebake_timeout_dropin
grep -qx 'TimeoutStartSec=9000' "$REBAKE_DROPIN_FILE" \
    || fail "an unset BAKE_TIMEOUT did not keep the 9000 default: $(cat "$REBAKE_DROPIN_FILE")"

# An invalid conf value cannot become TimeoutStartSec. The default stands.
write_conf 2h 0
write_rebake_timeout_dropin
grep -qx 'TimeoutStartSec=9000' "$REBAKE_DROPIN_FILE" \
    || fail "a non-numeric BAKE_TIMEOUT was written into the drop-in: $(cat "$REBAKE_DROPIN_FILE")"

# A valid conf still reaches the unit, and the drop-in was reloaded first.
write_conf 7200 0
: > "$calls"
rebake_rc=0
(
    unset BAKE_TIMEOUT BAKE_MIN_FREE_GIB REBAKE_FOREGROUND
    rebake_main
) >"$state/out" 2>"$state/log" || rebake_rc=$?
[[ "$rebake_rc" == 0 ]] || fail "a valid conf did not detach: $(cat "$state/log")"
grep -q 'systemctl daemon-reload' "$calls" || fail "detach did not reload the new start timeout"
grep -q 'systemctl start --no-block github-runner-rebake.service' "$calls" \
    || fail "a valid conf did not start the unit: $(cat "$calls")"

printf 'rebake-start-timeout: ok\n'
