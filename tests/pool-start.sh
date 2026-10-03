#!/usr/bin/env bash
# `runner start` must retry every slot at once instead of waiting out a
# failure backoff from before maintenance, and must run its pool fill in the
# watcher's unit: from the SSH session, a dropped connection kills a clone
# halfway through.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool-start: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# start.sh sources these too; naming them lets shellcheck follow them.
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
# shellcheck source=../lib/start.sh
source "$root/lib/start.sh"
fail() { printf 'pool-start: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

CONFIG_FILE=$state/github-runners.conf
POOL_DRAIN_FILE=$state/drain
SLOT_STATE_DIR=$state/slots
WATCH_SERVICE_FILE=$state/github-runner-watch.service
LIB_DIR=$state/lib
actions=$state/actions
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=9000\n' > "$CONFIG_FILE"
mkdir -p "$LIB_DIR" "$SLOT_STATE_DIR"
printf '#!/bin/sh\necho inline-watch >> "%s"\n' "$actions" > "$LIB_DIR/watch.sh"
chmod +x "$LIB_DIR/watch.sh"

require_root() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$actions"; }

prepare() {
    : > "$actions"
    : > "$POOL_DRAIN_FILE"
    printf 'hold_until=99999999999\nfailures=7\n' > "$SLOT_STATE_DIR/slot-runner-1"
    printf '9001 runner-1 1000\n' > "$SLOT_STATE_DIR/watch-stopped"
}

prepare
: > "$WATCH_SERVICE_FILE"
( start_main ) > "$state/out" 2>&1 || fail "start failed: $(tail -n 3 "$state/out")"
[[ ! -e "$POOL_DRAIN_FILE" ]] || fail "the pool drain was not cleared"
[[ ! -e "$SLOT_STATE_DIR/slot-runner-1" ]] || fail "the failure backoff survived runner start"
[[ -e "$SLOT_STATE_DIR/watch-stopped" ]] || fail "runner start dropped the watcher's stopped-VM record"
grep -qx 'systemctl start github-runner-watch.timer' "$actions" || fail "the watcher timer was not started"
grep -qx 'systemctl start github-runner-watch.service' "$actions" || fail "the fill did not run in the watcher's unit"
grep -q 'inline-watch' "$actions" && fail "the fill also ran from the shell"

# Without the unit (setup never finished), fill from the shell as before.
prepare
rm -f "$WATCH_SERVICE_FILE"
( start_main ) > "$state/out" 2>&1 || fail "start without the unit failed"
grep -qx 'inline-watch' "$actions" || fail "the fill did not run without the unit"

printf 'pool-start: ok\n'
