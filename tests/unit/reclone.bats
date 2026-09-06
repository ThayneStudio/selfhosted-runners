#!/usr/bin/env bats
# lib/reclone.sh — the hookscript's destroy-and-replace path, specifically what
# it does when the shared pool activity lock (fd 202) is already held
# exclusively by `runner stop`, promote, gc, bake or maintain.
#
# reclone must not *wait* for that lock: it already holds the per-slot lock
# (fd 200) and `runner stop` takes the two in the opposite order (exclusive 202,
# then fd 200 inside destroy.sh), so waiting would deadlock both.
#
# It must still destroy, though. watch.sh builds its slot inventory from
# `qm list`, which lists stopped VMs, so a slot left holding a stopped VM reads
# as filled and nothing refills it until the lifetime guard's stopped reap ~15
# minutes later — which also pages a warn-severity stopped_vm.reaped for routine
# promotion activity. Destroying and skipping only the clone leaves an empty
# slot, which the watcher fills on its next ~30s tick.
#
# flock is deliberately real (test_helper does not stub it) with a separate
# process holding the lock: a stub would pass just as happily against the wrong
# fd or the wrong file.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib
    write_infra_config
    write_org_config acme ghp_test acme-org
    NAME="runner-1"
    ORG="acme"
    VMID="9001"
    # The block under test starts at the fd 202 acquisition and runs to the end
    # of the script, so it covers the lock decision, the destroy, and the clone.
    RECLONE_TAIL=$(awk '/^# Hold shared pool activity/,0' "$REPO_ROOT/lib/reclone.sh")
    [ -n "$RECLONE_TAIL" ]

    stub_out qm 'destroy *' < /dev/null
    stub_out qm 'list*' <<'EOF'
      VMID NAME                 STATUS
EOF
    notify() { printf '%s\n' "$*" >> "$STUB_DIR/notify.log"; }
    load_org_config() { :; }
    clone_runner() { printf 'clone %s %s\n' "$1" "$2" >> "$STUB_DIR/clone.log"; }
}

teardown() {
    [[ -z "${HOLDER_PID:-}" ]] || kill "$HOLDER_PID" 2>/dev/null || true
}

# Take an exclusive fd 202 from a separate process, the way runner stop,
# promote, gc, bake and maintain all do. The lock lives on the open file
# description, so it is held for as long as that subshell lives.
hold_pool_lock() {
    local ready="$STUB_DIR/pool-holder-ready"
    rm -f "$ready"
    (
        exec 202>"$POOL_ACTIVITY_LOCK_FILE"
        flock -x 202 || exit 1
        : > "$ready"
        sleep 60
    ) &
    HOLDER_PID=$!
    local waited=0
    while [[ ! -e "$ready" && "$waited" -lt 200 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    [ -e "$ready" ]
}

run_reclone_tail() {
    run --separate-stderr eval "set -euo pipefail
$RECLONE_TAIL"
}

cloned() {
    [[ -f "$STUB_DIR/clone.log" ]]
}

@test "reclone destroys and reclones when the pool activity lock is free" {
    run_reclone_tail
    [ "$status" -eq 0 ]
    assert_called qm 'destroy 9001 --purge'
    cloned
    grep -qx 'clone runner-1 acme' "$STUB_DIR/clone.log"
    [ ! -f "$STUB_DIR/notify.log" ]
}

@test "reclone still destroys when the pool activity lock is held, and skips only the clone" {
    hold_pool_lock

    run_reclone_tail
    [ "$status" -eq 0 ]
    # The destroy is the whole point: a stopped VM left behind reads as a filled
    # slot to watch.sh, so nothing would refill it for ~15 minutes.
    assert_called qm 'destroy 9001 --purge'
    ! cloned
    [ ! -f "$STUB_DIR/notify.log" ]
    [[ "$stderr" == *"pool activity locked"* ]]
    [[ "$stderr" == *"leaving the empty runner-1 slot to the watcher"* ]]
}

@test "reclone does not block waiting for the pool activity lock" {
    hold_pool_lock

    # A blocking acquisition would sit here until the 60s holder exits, which is
    # the deadlock `runner stop` would hit. Anything near-instant proves -n.
    local started elapsed
    started=$(date +%s)
    run_reclone_tail
    elapsed=$(( $(date +%s) - started ))
    [ "$status" -eq 0 ]
    [ "$elapsed" -lt 15 ]
}

@test "reclone leaves the pool activity lock free for the exclusive waiter" {
    # Nothing else holds it, so reclone takes it shared and releases it on exit.
    run_reclone_tail
    [ "$status" -eq 0 ]

    exec 203>"$POOL_ACTIVITY_LOCK_FILE"
    run flock -x -n 203
    exec 203>&-
    [ "$status" -eq 0 ]
}
