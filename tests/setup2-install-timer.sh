#!/usr/bin/env bash
# install.sh enables the Persistent daily rebake timer. systemd runs a timer
# that has never run at its next OnCalendar slot, not when it is enabled, so
# install.sh must not promise an immediate check, and it names the command
# that runs the first check now.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup2-install-timer: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'setup2-install-timer: %s\n' "$1" >&2; exit 1; }

# The message is the run of echo lines right after the timer is enabled.
msg=$(awk '
    /systemctl enable --now github-runner-rebake\.timer/ { seen = 1; next }
    seen && /^[[:space:]]*echo / { print; next }
    seen { exit }
' "$root/install.sh")
[[ -n "$msg" ]] || fail "install.sh no longer explains the rebake timer it enables"
if grep -qiE 'immediately|at once' <<< "$msg"; then
    fail "install.sh says enabling the timer can start a check at once; a first enable waits for midnight"
fi
grep -qF 'next midnight' <<< "$msg" || fail "install.sh does not say when the first check runs"
grep -qF 'runner rebake' <<< "$msg" || fail "install.sh does not say how to run the first check now"

# "Midnight" is this unit's OnCalendar slot.
grep -qx 'OnCalendar=daily' "$root/templates/github-runner-rebake.timer" ||
    fail "the rebake timer no longer runs at midnight; update install.sh's message"

printf 'setup2-install-timer: ok\n'
