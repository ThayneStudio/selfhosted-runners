#!/usr/bin/env bash
# clear_slot_backoff deletes slot-* in the runtime directory, which is also
# where the slot locks live. The default lock prefix has to stay outside
# that glob: removing a held lock drops its inode, and the next opener
# creates a new file and takes the lock as well.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'slot-lock-backoff: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'slot-lock-backoff: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
hold_pid=
cleanup() {
    if [[ -n "${hold_pid:-}" ]]; then
        kill "$hold_pid" 2>/dev/null || true
        wait "$hold_pid" 2>/dev/null || true
    fi
    rm -rf "$state"
}
trap cleanup EXIT

# The default prefix, computed by recycle.sh from RUN_DIR. This test does
# not assign SLOT_LOCK_PREFIX: an override hides the glob.
grep -q '^SLOT_LOCK_PREFIX=' "$0" && fail "this test assigns SLOT_LOCK_PREFIX"
RUN_DIR=$state/run
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
[[ "$SLOT_STATE_DIR" == "$state/run" ]] || fail "SLOT_STATE_DIR is $SLOT_STATE_DIR"
[[ "$SLOT_LOCK_PREFIX" == "$SLOT_STATE_DIR/lock-slot" ]] ||
    fail "default slot lock prefix is $SLOT_LOCK_PREFIX"

# One deletion glob over the runtime directory, and it is the state files.
globs=$(grep -nE 'rm .*(SLOT_STATE_DIR|RUN_DIR).*\*' "$root"/lib/*.sh || true)
[[ -n "$globs" ]] || fail "no state-dir deletion glob found"
[[ "$(printf '%s\n' "$globs" | grep -c '\*')" == 1 ]] ||
    fail "unexpected state-dir deletion globs: $globs"
printf '%s\n' "$globs" | grep -q 'slot-\*' ||
    fail "the state-dir deletion glob is not slot-*: $globs"

mkdir -p "$SLOT_STATE_DIR"
lock=$(slot_lock_file runner-1)
printf 'hold_until=1\nfailures=3\nrapid=0\ndeferrals=0\n' > "$(slot_state_file runner-1)"
printf 'keep\n' > "$SLOT_STATE_DIR/watch-stopped"
for name in runner-vmid.lock runner-vmid-reserve-100.lock runner-clone-slot-1.lock \
    github-runner-extras.lock github-runner-pool.lock github-runner-rebake.lock \
    github-runner-drain; do
    printf 'keep\n' > "$SLOT_STATE_DIR/$name"
done
[[ $(basename "$lock") != slot-* ]] || fail "default lock name $lock matches slot-*"

python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
sys.stdout.write("%s\n" % os.fstat(fd).st_ino)
sys.stdout.flush()
time.sleep(60)
' "$lock" > "$state/hold.out" &
hold_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$state/hold.out" ]] && break
    sleep 0.05
done
held_ino=$(head -1 "$state/hold.out" || true)
[[ -n "$held_ino" ]] || fail "could not hold $lock"

if python3 -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
sys.exit(0)
' "$lock"; then
    fail "the slot lock was not held before clear_slot_backoff"
fi

clear_slot_backoff

[[ ! -e "$(slot_state_file runner-1)" ]] || fail "clear_slot_backoff left the state file"
[[ -f "$lock" ]] || fail "clear_slot_backoff removed $lock"
now_ino=$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$lock")
[[ "$now_ino" == "$held_ino" ]] ||
    fail "clear_slot_backoff replaced held lock inode $held_ino with $now_ino"
if python3 -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
sys.exit(0)
' "$lock"; then
    fail "a second process took the slot lock after clear_slot_backoff"
fi
for name in watch-stopped runner-vmid.lock runner-vmid-reserve-100.lock \
    runner-clone-slot-1.lock github-runner-extras.lock github-runner-pool.lock \
    github-runner-rebake.lock github-runner-drain; do
    [[ "$(cat "$SLOT_STATE_DIR/$name")" == keep ]] ||
        fail "clear_slot_backoff removed $name"
done

printf 'slot-lock-backoff: ok\n'
