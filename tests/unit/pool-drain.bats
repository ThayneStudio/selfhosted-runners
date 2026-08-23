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
    run grep -m1 '^POOL_DRAIN_FILE=' "$REPO_ROOT/lib/common.sh"
    [ "$status" -eq 0 ]
    [ "$output" = 'POOL_DRAIN_FILE="/var/lib/github-runners/drain"' ]
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

@test "hookscript fails closed when the install tree is unreadable" {
    setup_hookscript
    chmod 000 "$HOOK_ROOT/lib/common.sh"
    run_hookscript 107 post-stop
    chmod 644 "$HOOK_ROOT/lib/common.sh"
    [ "$HOOK_STATUS" -eq 0 ]
    ! reclone_triggered
    grep -q "unreadable" "$TEST_DIR/logger-out"
}
