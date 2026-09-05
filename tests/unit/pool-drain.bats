#!/usr/bin/env bats
# Maintenance flag must survive a host reboot, and must still honor the
# pre-upgrade tmpfs path so an in-flight maintenance window is not dropped.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_DIR="$(mktemp -d)"
    DRAIN_FILE="$TEST_DIR/var/lib/github-runners/drain"
    LEGACY_DRAIN_FILE="$TEST_DIR/run/lock/github-runner-drain"
    mkdir -p "$TEST_DIR/run/lock"
}

teardown() {
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# Call a common.sh drain helper against the temp paths. Runs in a child shell
# because common.sh sets `set -euo pipefail`, which must not leak into bats.
drain_call() {
    bash -c '
        source "$1" >/dev/null 2>&1
        POOL_DRAIN_FILE="$2"
        POOL_DRAIN_FILE_LEGACY="$3"
        POOL_DRAIN_COORD_LOCK_FILE="$(dirname "$3")/drain-coord.lock"
        shift 3
        "$@"
    ' _ "$REPO_ROOT/lib/common.sh" "$DRAIN_FILE" "$LEGACY_DRAIN_FILE" "$@"
}

# Fake install tree so the hookscript's absolute /opt paths can be redirected:
# a common.sh whose drain paths point into the temp dir, a reclone.sh that only
# drops a marker, and a logger stub.
setup_hookscript() {
    HOOK_ROOT="$TEST_DIR/opt/selfhosted-runners"
    mkdir -p "$HOOK_ROOT/lib" "$TEST_DIR/bin"

    cp "$REPO_ROOT/lib/common.sh" "$HOOK_ROOT/lib/common.sh"
    cat >> "$HOOK_ROOT/lib/common.sh" <<EOF
POOL_DRAIN_FILE="$DRAIN_FILE"
POOL_DRAIN_FILE_LEGACY="$LEGACY_DRAIN_FILE"
POOL_DRAIN_COORD_LOCK_FILE="$TEST_DIR/run/lock/drain-coord.lock"
EOF

    cat > "$HOOK_ROOT/lib/reclone.sh" <<EOF
#!/bin/bash
echo "\$1" > "$TEST_DIR/reclone-marker"
EOF
    chmod 755 "$HOOK_ROOT/lib/reclone.sh"

    cat > "$TEST_DIR/bin/logger" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_DIR/logger-out"
EOF
    chmod 755 "$TEST_DIR/bin/logger"
    : > "$TEST_DIR/logger-out"

    sed -e "s#/opt/selfhosted-runners#$HOOK_ROOT#g" \
        -e "s#/var/log/github-runner.log#$TEST_DIR/github-runner.log#g" \
        "$REPO_ROOT/templates/runner-hookscript.sh" > "$TEST_DIR/hook.sh"
    chmod 755 "$TEST_DIR/hook.sh"
}

run_hookscript() {
    PATH="$TEST_DIR/bin:$PATH" "$TEST_DIR/hook.sh" "$@"
    HOOK_STATUS=$?
    # reclone.sh is nohup'd and disowned, so wait for the child to land.
    local i
    for ((i = 0; i < 40; i++)); do
        [[ -e "$TEST_DIR/reclone-marker" ]] && break
        sleep 0.05
    done
    return 0
}

reclone_triggered() {
    [[ -e "$TEST_DIR/reclone-marker" ]]
}

@test "drain flag lives outside tmpfs so it survives a host reboot" {
    # Assert the resolved path, not the source text: the definition derives
    # from RUNNER_STATE_DIR so the platform's state root is spelled once.
    run env -u RUNNER_STATE_DIR -u POOL_DRAIN_FILE_LEGACY bash -c \
        'source "$1/lib/common.sh"; printf "%s" "$POOL_DRAIN_FILE"' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "/var/lib/github-runners/drain" ]
    # The whole point: not on tmpfs.
    [[ "$output" != /run/* ]]
}

@test "pool_is_draining is false with no flag files" {
    run drain_call pool_is_draining
    [ "$status" -ne 0 ]
}

@test "enable_pool_drain creates the flag and its parent directory" {
    run drain_call enable_pool_drain
    [ "$status" -eq 0 ]
    [ -f "$DRAIN_FILE" ]
    run drain_call pool_is_draining
    [ "$status" -eq 0 ]
}

@test "enable_pool_drain also writes the legacy path so a rollback sees it" {
    drain_call enable_pool_drain
    [ -f "$LEGACY_DRAIN_FILE" ]
}

@test "maintenance entry waits for an in-flight rollover drain transaction" {
    local coord="$TEST_DIR/run/lock/drain-coord.lock"
    exec 212>"$coord"
    flock -s 212
    drain_call enable_pool_drain 212>&- &
    local drain_pid=$!
    sleep 0.1
    [ ! -e "$DRAIN_FILE" ]
    exec 212>&-
    wait "$drain_pid"
    [ -e "$DRAIN_FILE" ]
}

@test "enable_pool_drain reports failure instead of half-entering maintenance" {
    # A regular file where the state directory has to go. `install -d` fails on
    # that for every uid including root, so this models the real failure (a full
    # root filesystem) rather than a permission bit root would ignore.
    : > "$TEST_DIR/blocked"
    DRAIN_FILE="$TEST_DIR/blocked/drain"
    run drain_call enable_pool_drain
    [ "$status" -ne 0 ]
    [[ "$output" == *"maintenance mode NOT entered"* ]]
}

@test "pool_is_draining honors a drain set at the pre-upgrade tmpfs path" {
    : > "$LEGACY_DRAIN_FILE"
    run drain_call pool_is_draining
    [ "$status" -eq 0 ]
}

@test "disable_pool_drain clears both the current and legacy flags" {
    drain_call enable_pool_drain
    : > "$LEGACY_DRAIN_FILE"
    run drain_call disable_pool_drain
    [ "$status" -eq 0 ]
    [ ! -e "$DRAIN_FILE" ]
    [ ! -e "$LEGACY_DRAIN_FILE" ]
    run drain_call pool_is_draining
    [ "$status" -ne 0 ]
}

@test "hookscript reclones on post-stop when the pool is not draining" {
    setup_hookscript
    run_hookscript 101 post-stop
    [ "$HOOK_STATUS" -eq 0 ]
    reclone_triggered
    [ "$(cat "$TEST_DIR/reclone-marker")" = "101" ]
}

@test "hookscript skips reclone during a persisted drain" {
    setup_hookscript
    mkdir -p "$(dirname "$DRAIN_FILE")"
    : > "$DRAIN_FILE"
    run_hookscript 102 post-stop
    [ "$HOOK_STATUS" -eq 0 ]
    ! reclone_triggered
    grep -q "stopped during pool drain" "$TEST_DIR/logger-out"
}

@test "hookscript skips reclone during a legacy tmpfs drain" {
    setup_hookscript
    : > "$LEGACY_DRAIN_FILE"
    run_hookscript 103 post-stop
    [ "$HOOK_STATUS" -eq 0 ]
    ! reclone_triggered
}

@test "hookscript reclones again once the drain is cleared" {
    setup_hookscript
    mkdir -p "$(dirname "$DRAIN_FILE")"
    : > "$DRAIN_FILE"
    : > "$LEGACY_DRAIN_FILE"
    run_hookscript 104 post-stop
    ! reclone_triggered
    drain_call disable_pool_drain
    run_hookscript 105 post-stop
    reclone_triggered
    [ "$(cat "$TEST_DIR/reclone-marker")" = "105" ]
}

@test "hookscript ignores phases other than post-stop" {
    setup_hookscript
    run_hookscript 106 pre-start
    [ "$HOOK_STATUS" -eq 0 ]
    ! reclone_triggered
}

@test "hookscript fails closed when common.sh is missing" {
    setup_hookscript
    rm -f "$HOOK_ROOT/lib/common.sh"
    run_hookscript 107 post-stop
    [ "$HOOK_STATUS" -eq 0 ]
    ! reclone_triggered
    grep -q "inconclusive" "$TEST_DIR/logger-out"
}

# The state a host is in partway through `curl … install.sh | bash`: tar has
# written lib/common.sh but not yet a helper common.sh sources, so common.sh
# exists and is readable but cannot be sourced. An exit-status check reads that
# as "not draining" under bash 3.2 and reclones mid-maintenance.
@test "hookscript fails closed when common.sh cannot be sourced during a drain" {
    setup_hookscript
    mkdir -p "$(dirname "$DRAIN_FILE")"
    : > "$DRAIN_FILE"
    printf 'source "$LIB_DIR/definitely-not-extracted-yet.sh"\n' \
        >> "$HOOK_ROOT/lib/common.sh"
    run_hookscript 108 post-stop
    [ "$HOOK_STATUS" -eq 0 ]
    ! reclone_triggered
}

@test "hookscript fails closed when common.sh is truncated mid-function" {
    setup_hookscript
    head -n 20 "$REPO_ROOT/lib/common.sh" > "$HOOK_ROOT/lib/common.sh"
    run_hookscript 109 post-stop
    [ "$HOOK_STATUS" -eq 0 ]
    ! reclone_triggered
    grep -q "inconclusive" "$TEST_DIR/logger-out"
}

# install.sh's migration block, lifted verbatim and pointed at the temp dir.
# Extracting it keeps the assertion on the shipped text; install.sh itself
# cannot run here because it starts by curling a release tarball.
run_install_migration() {
    # The block sources the freshly-installed common.sh and works from its
    # constants, so point INSTALL_DIR at the repo and override the two paths
    # rather than rewriting literals that no longer exist.
    awk '/^source "\$INSTALL_DIR\/lib\/common.sh"$/,/^fi$/' \
        "$REPO_ROOT/install.sh" > "$TEST_DIR/migrate-body.sh"
    # Explicit: this runs inside `run`, where a bare failing test would not
    # abort the helper and the migration's removal would go unnoticed.
    [ -s "$TEST_DIR/migrate-body.sh" ] || return 1
    grep -q 'POOL_DRAIN_FILE_LEGACY' "$TEST_DIR/migrate-body.sh" || return 1
    {
        echo 'set -euo pipefail'
        cat "$TEST_DIR/migrate-body.sh"
    } > "$TEST_DIR/migrate.sh"
    INSTALL_DIR="$REPO_ROOT" \
    RUNNER_STATE_DIR="$(dirname "$DRAIN_FILE")" \
    POOL_DRAIN_FILE_LEGACY="$LEGACY_DRAIN_FILE" \
        bash "$TEST_DIR/migrate.sh"
}

@test "install.sh migrates an active tmpfs drain to the persistent flag" {
    : > "$LEGACY_DRAIN_FILE"
    run run_install_migration
    [ "$status" -eq 0 ]
    [ -f "$DRAIN_FILE" ]
    run drain_call pool_is_draining
    [ "$status" -eq 0 ]
}

@test "install.sh migration is a no-op, and not an error, with no drain set" {
    run run_install_migration
    [ "$status" -eq 0 ]
    [ ! -e "$DRAIN_FILE" ]
}
