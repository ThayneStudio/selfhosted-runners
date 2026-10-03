#!/usr/bin/env bash
# Locks and the drain flag used to live in /run/lock, which is 1777. Any local
# account could create, hold or delete them, or plant a symlink for root to
# write through. They now live in one root-only directory, created mode 0700
# before the first lock, and a directory with the wrong owner or mode is not
# trusted. The hookscript hardcodes the same drain path.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'run-dir-locks: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
# shellcheck source=../lib/watch.sh
source "$root/lib/watch.sh"
fail() { printf 'run-dir-locks: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

[[ "$RUN_DIR" == "/run/github-runners" ]] || fail "RUN_DIR is $RUN_DIR"
for path in "$POOL_DRAIN_FILE" "$POOL_ACTIVITY_LOCK_FILE" "$VMID_LOCK_FILE" \
    "$VMID_RESERVATION_LOCK_PREFIX" "$CLONE_SLOT_LOCK_PREFIX" "$SLOT_STATE_DIR" \
    "$SLOT_LOCK_PREFIX" "$EXTRA_RUNNERS_LOCK_FILE" "$REBAKE_LOCK_FILE"; do
    [[ "$path" == "$RUN_DIR" || "$path" == "$RUN_DIR"/* ]] ||
        fail "not under $RUN_DIR: $path"
done
[[ "$POOL_DRAIN_FILE" == "/run/github-runners/github-runner-drain" ]] ||
    fail "drain flag is $POOL_DRAIN_FILE"
[[ "$LEGACY_POOL_DRAIN_FILE" == "/run/lock/github-runner-drain" ]] ||
    fail "legacy drain flag is $LEGACY_POOL_DRAIN_FILE"
[[ "$SLOT_LOCK_PREFIX" == "$RUN_DIR/slot" ]] ||
    fail "slot lock prefix is $SLOT_LOCK_PREFIX"
[[ "$(slot_lock_file vmid)" == "$RUN_DIR/slot-vmid.lock" ]] ||
    fail "a runner named vmid uses $(slot_lock_file vmid)"
[[ "$(slot_lock_file vmid)" != "$VMID_LOCK_FILE" ]] ||
    fail "a runner named vmid shares the VMID lock"
[[ "$(slot_lock_file clone-slot-1)" != "${CLONE_SLOT_LOCK_PREFIX}-1.lock" ]] ||
    fail "a runner named clone-slot-1 shares a clone-slot lock"
[[ "$(slot_lock_file vmid-reserve-100)" != "$(vmid_reservation_lock_file 100)" ]] ||
    fail "a runner named vmid-reserve-100 shares a VMID reservation lock"
grep -qx 'POOL_DRAIN_FILE="/run/github-runners/github-runner-drain"' \
    "$root/templates/runner-hookscript.sh" ||
    fail "hookscript drain path does not match the libs"

run=$state/run
mkdir -m 1777 "$state/legacy"
printf 'keep\n' > "$state/canary"
ln -s "$state/canary" "$state/legacy/github-runner-drain"
POOL_DRAIN_FILE=$run/github-runner-drain
POOL_ACTIVITY_LOCK_FILE=$run/github-runner-pool.lock
VMID_LOCK_FILE=$run/runner-vmid.lock
VMID_RESERVATION_LOCK_PREFIX=$run/runner-vmid-reserve
CLONE_SLOT_LOCK_PREFIX=$run/runner-clone-slot
SLOT_STATE_DIR=$state/slots
SLOT_LOCK_PREFIX=$run/slot
EXTRA_RUNNERS_FILE=$state/extras
EXTRA_RUNNERS_LOCK_FILE=$run/github-runner-extras.lock
REBAKE_LOCK_FILE=$run/github-runner-rebake.lock
LEGACY_POOL_DRAIN_FILE=$state/legacy/github-runner-drain
PVE_NODES_DIR=$state/nodes
mkdir -p "$PVE_NODES_DIR/pve/qemu-server" "$state/orgs"
MIN_VMID=100
TEMPLATE_ID=9000
VM_STORAGE=local-zfs
ORG_CONFIG_DIR=$state/orgs

enable_pool_drain || fail "enable_pool_drain failed"
[[ -d "$run" && ! -L "$run" ]] || fail "runtime directory was not created"
[[ "$(file_mode "$run")" == "700" ]] || fail "runtime directory mode is $(file_mode "$run")"
[[ "$(file_owner "$run")" == "$EUID" ]] || fail "runtime directory owner is $(file_owner "$run")"
[[ -f "$POOL_DRAIN_FILE" && ! -L "$POOL_DRAIN_FILE" ]] || fail "drain flag is not a regular file in $run"
[[ "$(dirname "$POOL_DRAIN_FILE")" == "$run" ]] || fail "drain flag is not in the runtime directory"
pool_is_draining || fail "the new drain flag was not honoured"
[[ "$(cat "$state/canary")" == "keep" ]] || fail "the legacy drain flag was written through a symlink"
[[ -f "$LEGACY_POOL_DRAIN_FILE" && ! -L "$LEGACY_POOL_DRAIN_FILE" ]] ||
    fail "the legacy drain flag was not replaced with a regular file"
[[ "$(file_owner "$LEGACY_POOL_DRAIN_FILE")" == "$EUID" ]] ||
    fail "the legacy drain flag is owned by $(file_owner "$LEGACY_POOL_DRAIN_FILE")"

disable_pool_drain
[[ ! -e "$POOL_DRAIN_FILE" && ! -L "$POOL_DRAIN_FILE" ]] || fail "disable left the drain flag"
[[ ! -e "$LEGACY_POOL_DRAIN_FILE" && ! -L "$LEGACY_POOL_DRAIN_FILE" ]] ||
    fail "disable left the legacy drain flag"
if pool_is_draining; then fail "disable_pool_drain left the pool draining"; fi

# A file another account can create in /run/lock must not pause the pool.
# Root's own file is the drain the previous version set, so it does.
printf 'planted\n' > "$LEGACY_POOL_DRAIN_FILE"
if [[ "$EUID" -eq 0 ]]; then
    pool_is_draining || fail "a root-owned legacy drain flag was ignored"
    [[ -f "$POOL_DRAIN_FILE" ]] || fail "a root-owned legacy drain flag was not copied forward"
    disable_pool_drain
else
    if pool_is_draining; then fail "a non-root file at the old drain path paused the pool"; fi
    [[ ! -e "$POOL_DRAIN_FILE" ]] || fail "a non-root legacy flag was copied forward"
fi
rm -f "$LEGACY_POOL_DRAIN_FILE"

ln -s /bin/bash "$LEGACY_POOL_DRAIN_FILE"
if pool_is_draining; then fail "a symlink at the old drain path paused the pool"; fi
[[ ! -e "$POOL_DRAIN_FILE" ]] || fail "a legacy symlink was copied forward"
rm -f "$LEGACY_POOL_DRAIN_FILE"

# stat follows symlinks, so the owner check has to reject a link before that.
# Pretend the legacy file is root's: the flag moves to the new path.
printf 'old\n' > "$LEGACY_POOL_DRAIN_FILE"
(
    eval "orig_$(declare -f file_owner)"
    file_owner() {
        if [[ "$1" == "$LEGACY_POOL_DRAIN_FILE" ]]; then
            printf '0\n'
            return 0
        fi
        orig_file_owner "$1"
    }
    pool_is_draining || exit 1
    [[ -f "$POOL_DRAIN_FILE" && ! -L "$POOL_DRAIN_FILE" ]] || exit 1
) || fail "a root-owned legacy drain flag was ignored"
disable_pool_drain

mkdir -m 777 "$state/real"
ln -s "$state/real" "$state/linkdir"
if ensure_private_dir "$state/linkdir" 2>"$state/err"; then
    fail "a symlink was used as the runtime directory"
fi
[[ "$(file_mode "$state/real")" == "777" ]] || fail "chmod followed a symlink to the runtime directory"
: > "$state/notadir"
if ensure_private_dir "$state/notadir" 2>"$state/err"; then
    fail "a file was used as the runtime directory"
fi
mkdir -m 555 "$state/blocked"
if ensure_private_dir "$state/blocked/nope" 2>"$state/err"; then
    fail "created a runtime directory through a directory we cannot write"
fi
[[ "$(file_mode "$state/blocked")" == "555" ]] || fail "a non-writable parent was chmodded"
chmod 700 "$state/blocked"

# macOS has no flock(1). The lock file is created by the open; flock only
# has to succeed so the caller returns instead of walking the next VMID.
flock() { return 0; }

mkdir -m 777 "$state/loose"
printf 'secret\n' > "$state/secret"
ln -s "$state/secret" "$state/loose/pool.lock"
open_lock_fd 202 "$state/loose/pool.lock" || fail "could not replace a symlink lock"
[[ "$(cat "$state/secret")" == "secret" ]] || fail "opening a lock followed a symlink"
[[ -f "$state/loose/pool.lock" && ! -L "$state/loose/pool.lock" ]] ||
    fail "the lock path is still a symlink"
[[ "$(file_mode "$state/loose")" == "700" ]] ||
    fail "a loose lock directory was left mode $(file_mode "$state/loose")"
exec 202>&-

acquire_clone_slot || fail "clone slot lock was not acquired"
[[ -f "$run/runner-clone-slot-1.lock" ]] || fail "clone slot lock is not in $run"
release_clone_slot

reserve_vmid || fail "VMID reservation failed"
[[ -f "$run/runner-vmid-reserve-100.lock" ]] || fail "VMID reservation lock is not in $run"
release_vmid_reservation 100

(
    pvesm() { printf 'Volid\n'; }
    cleanup_runner_orphan_volumes
) || fail "pool lock was not opened"
[[ -f "$run/github-runner-pool.lock" ]] || fail "pool lock is not in $run"

record_extra_runner box acme || fail "extras lock was not taken"
[[ -f "$run/github-runner-extras.lock" ]] || fail "extras lock is not in $run"

(
    qm() { return 1; }
    fill_runner_slot runner-1 acme
) >"$state/fill.out" 2>&1 || true
[[ -f "$run/slot-runner-1.lock" ]] || fail "slot lock is not in $run: $(cat "$state/fill.out")"

(
    GITHUB_PAT="test"
    GITHUB_ORG="acme"
    fetch_jit_config() { printf 'jit-token'; }
    n=0
    pool_is_draining() { n=$((n + 1)); (( n >= 2 )); }
    clone_runner runner-9 acme
) >"$state/clone.out" 2>&1 || true
[[ -f "$run/runner-vmid.lock" ]] || fail "VMID lock is not in $run: $(cat "$state/clone.out")"

(
    require_root() { :; }
    REBAKE_FOREGROUND=1
    flock() { return 1; }
    qm() { :; }
    rebake_main
) >"$state/rebake.out" 2>&1 || fail "rebake lock was not opened: $(cat "$state/rebake.out")"
[[ -f "$run/github-runner-rebake.lock" ]] || fail "rebake lock is not in $run"

for lock in "$run/github-runner-pool.lock" "$run/runner-vmid.lock" \
    "$run/runner-clone-slot-1.lock" "$run/slot-runner-1.lock" \
    "$run/github-runner-extras.lock" "$run/github-runner-rebake.lock"; do
    [[ -f "$lock" && ! -L "$lock" ]] || fail "missing $lock"
    [[ "$(dirname "$lock")" == "$run" ]] || fail "$lock is outside the runtime directory"
done

printf 'run-dir-locks: ok\n'
