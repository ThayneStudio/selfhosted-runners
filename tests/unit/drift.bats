#!/usr/bin/env bats
# Drift alarm: fleet runner version vs the 30-day actions/runner window (spec 11.4).
#
# Clock is frozen at 2026-08-25T00:00:00Z via gen_now so remaining-day math
# does not depend on wall time. notify is stubbed to a log file.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib drift.sh
    MIN_VMID=9001
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults

    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }

    jq_stub() {
        local json val=""
        json=$(cat)
        if [[ "$*" == *tag_name* ]]; then
            if [[ "$json" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            printf '%s\n' "$val"
            return 0
        fi
        if [[ "$*" == *published_at* ]]; then
            if [[ "$json" =~ \"published_at\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            printf '%s\n' "$val"
            return 0
        fi
        printf 'jq stub: unhandled args: %s\n' "$*" >&2
        return 1
    }
    export -f jq_stub

    notify() {
        printf '%s\n' "$*" >> "$STUB_DIR/notify.log"
        return "${NOTIFY_RC:-0}"
    }

    bake_main() {
        printf 'called\n' >> "$STUB_DIR/bake_main.log"
        return 0
    }
}

notify_log() {
    [[ -f "$STUB_DIR/notify.log" ]] && cat "$STUB_DIR/notify.log"
    return 0
}

notify_count() {
    [[ -f "$STUB_DIR/notify.log" ]] || { printf '0\n'; return 0; }
    wc -l < "$STUB_DIR/notify.log" | tr -d ' '
}

stub_latest() {
    local tag="${1:-v2.336.0}" published="${2:-2026-07-20T00:00:00Z}"
    stub_out curl '*' <<EOF
{"tag_name":"${tag}","published_at":"${published}"}
EOF
}

make_template_gen() {
    local ver="${1:-2.336.0}"
    shift || true
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=abc \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION="$ver" \
        "$@"
}

# ---------------------------------------------------------------------------
# Syntax / wiring
# ---------------------------------------------------------------------------

@test "lib/drift.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/drift.sh"
}

@test "runner dispatches the drift verb" {
    grep -Eq '^[[:space:]]*drift\)' "$REPO_ROOT/runner"
    grep -q 'drift' "$REPO_ROOT/runner"
}

@test "runner help lists drift" {
    grep -q 'echo "  drift ' "$REPO_ROOT/runner"
}

@test "drift timer is low-frequency with Persistent=true" {
    local timer="$REPO_ROOT/templates/github-runner-drift.timer"
    [ -f "$timer" ]
    grep -q 'OnCalendar=' "$timer"
    grep -q 'Persistent=true' "$timer"
    grep -q 'WantedBy=timers.target' "$timer"
    ! grep -q 'OnUnitInactiveSec=30' "$timer"
}

@test "drift service runs runner drift as oneshot" {
    local unit="$REPO_ROOT/templates/github-runner-drift.service"
    [ -f "$unit" ]
    grep -q 'Type=oneshot' "$unit"
    grep -q 'ExecStart=/usr/local/bin/runner drift' "$unit"
    grep -q 'SyslogIdentifier=github-runner-drift' "$unit"
}

@test "setup.sh installs drift units, enables the timer, and documents disable" {
    grep -q 'github-runner-drift.service' "$REPO_ROOT/lib/setup.sh"
    grep -q 'github-runner-drift.timer' "$REPO_ROOT/lib/setup.sh"
    grep -q 'enable --now github-runner-drift.timer' "$REPO_ROOT/lib/setup.sh"
    grep -q 'systemctl disable --now github-runner-drift.timer' "$REPO_ROOT/lib/setup.sh"
}

@test "install.sh refreshes drift units and enables the timer" {
    grep -q 'github-runner-drift.service' "$REPO_ROOT/install.sh"
    grep -q 'github-runner-drift.timer' "$REPO_ROOT/install.sh"
    grep -q 'enable --now github-runner-drift.timer' "$REPO_ROOT/install.sh"
}

@test "watch.sh does not run the drift check" {
    ! grep -q 'drift' "$REPO_ROOT/lib/watch.sh"
}

@test "drift.sh does not source bake.sh or call bake_main" {
    ! grep -E 'source .*bake\.sh|bake_main' "$REPO_ROOT/lib/drift.sh"
}

@test "DRIFT_FAIL_FILE is a sandboxed host path" {
    [[ "$DRIFT_FAIL_FILE" == "$HOST_SANDBOX"* ]]
    [[ "$DRIFT_FAIL_FILE" == *drift-fail ]]
}

@test "drift CLI is a library: main only when BASH_SOURCE is 0" {
    grep -q 'BASH_SOURCE\[0\]' "$REPO_ROOT/lib/drift.sh"
    grep -q 'drift_main' "$REPO_ROOT/lib/drift.sh"
    grep -q 'require_root' "$REPO_ROOT/lib/drift.sh"
}

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

@test "fleet on latest reports clean and notifies nothing" {
    stub_latest v2.336.0 2026-08-20T00:00:00Z
    make_template_gen 2.336.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=clean$' <<< "$output"
    grep -q '^fleet=2.336.0$' <<< "$output"
    grep -q '^upstream=2.336.0$' <<< "$output"
    [ "$(notify_count)" -eq 0 ]
    refute_called qm 'destroy *'
    refute_called qm 'guest exec *'
    [ ! -f "$STUB_DIR/bake_main.log" ]
}

@test "fleet on latest is clean even after the 30-day calendar elapsed" {
    stub_latest v2.336.0 2026-07-20T00:00:00Z
    make_template_gen 2.336.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=clean$' <<< "$output"
    [ "$(notify_count)" -eq 0 ]
}

@test "2.334.0 vs 2.336.0 past the window fires error drift.critical" {
    stub_latest v2.336.0 2026-07-20T00:00:00Z
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=error$' <<< "$output"
    grep -q '^fleet=2.334.0$' <<< "$output"
    grep -q '^upstream=2.336.0$' <<< "$output"
    grep -q '^days_remaining=-6$' <<< "$output"
    [ "$(notify_count)" -eq 1 ]
    grep -q '^error drift.critical ' "$STUB_DIR/notify.log"
}

@test "10 days remaining notifies warn drift.warning" {
    stub_latest v2.336.0 2026-08-05T00:00:00Z
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=warn$' <<< "$output"
    grep -q '^days_remaining=10$' <<< "$output"
    [ "$(notify_count)" -eq 1 ]
    grep -q '^warn drift.warning ' "$STUB_DIR/notify.log"
}

@test "11 days remaining is behind and notifies nothing" {
    stub_latest v2.336.0 2026-08-06T00:00:00Z
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=behind$' <<< "$output"
    grep -q '^days_remaining=11$' <<< "$output"
    [ "$(notify_count)" -eq 0 ]
}

@test "3 days remaining fires error not warn" {
    stub_latest v2.336.0 2026-07-29T00:00:00Z
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=error$' <<< "$output"
    grep -q '^days_remaining=3$' <<< "$output"
    grep -q '^error drift.critical ' "$STUB_DIR/notify.log"
    ! grep -q 'drift.warning' "$STUB_DIR/notify.log"
}

@test "4 days remaining is still warn" {
    stub_latest v2.336.0 2026-07-30T00:00:00Z
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=warn$' <<< "$output"
    grep -q '^days_remaining=4$' <<< "$output"
    grep -q '^warn drift.warning ' "$STUB_DIR/notify.log"
}

@test "strips a leading v from GEN_RUNNER_VERSION before comparing" {
    stub_latest v2.336.0 2026-08-20T00:00:00Z
    make_template_gen v2.336.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=clean$' <<< "$output"
    grep -q '^fleet=2.336.0$' <<< "$output"
}

# ---------------------------------------------------------------------------
# Version sources
# ---------------------------------------------------------------------------

@test "prefers GEN_RUNNER_VERSION on TEMPLATE_ID over a running clone" {
    stub_latest v2.336.0 2026-07-20T00:00:00Z
    make_template_gen 2.334.0
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 acme-1               running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out qm 'guest exec 9001 -- /home/runner/actions-runner/bin/Runner.Listener --version' <<'EOF'
{
   "exitcode" : 0,
   "exited" : 1,
   "out-data" : "2.336.0\n"
}
EOF

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^fleet=2.334.0$' <<< "$output"
    grep -q '^status=error$' <<< "$output"
    refute_called qm 'guest exec *'
}

@test "two actives: TEMPLATE_ID version wins, not the other record" {
    stub_latest v2.336.0 2026-07-20T00:00:00Z
    gen_store_init
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^fleet=2.334.0$' <<< "$output"
    grep -q '^status=error$' <<< "$output"
}

@test "falls back to probing a running clone when GEN_RUNNER_VERSION is unknown" {
    stub_latest v2.336.0 2026-07-20T00:00:00Z
    make_template_gen unknown
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 acme-1               running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out qm 'guest exec 9001 -- /home/runner/actions-runner/bin/Runner.Listener --version' <<'EOF'
{
   "exitcode" : 0,
   "exited" : 1,
   "out-data" : "2.334.0\n"
}
EOF

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^fleet=2.334.0$' <<< "$output"
    grep -q '^status=error$' <<< "$output"
    assert_called qm 'guest exec 9001 -- /home/runner/actions-runner/bin/Runner.Listener --version'
}

@test "falls back to probing when TEMPLATE_ID has no generation record" {
    stub_latest v2.336.0 2026-08-20T00:00:00Z
    gen_store_init
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9001 acme-1               running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out qm 'guest exec 9001 -- /home/runner/actions-runner/bin/Runner.Listener --version' <<'EOF'
{
   "exitcode" : 0,
   "exited" : 1,
   "out-data" : "2.336.0\n"
}
EOF

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=clean$' <<< "$output"
    grep -q '^fleet=2.336.0$' <<< "$output"
}

@test "falls back to probing when the generation record is corrupt after its version" {
    stub_latest v2.336.0 2026-08-20T00:00:00Z
    make_template_gen 2.334.0
    printf 'malformed-record-line\n' >> "$(gen_record_path 9000)"
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9001 acme-1               running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out qm 'guest exec 9001 -- /home/runner/actions-runner/bin/Runner.Listener --version' <<'EOF'
{
   "exitcode" : 0,
   "exited" : 1,
   "out-data" : "2.336.0\n"
}
EOF

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=clean$' <<< "$output"
    grep -q '^fleet=2.336.0$' <<< "$output"
    assert_called qm 'guest exec 9001 -- /home/runner/actions-runner/bin/Runner.Listener --version'
}

@test "does not probe TEMPLATE_ID or an unmanaged VM" {
    stub_latest v2.336.0 2026-08-20T00:00:00Z
    make_template_gen unknown
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template running   8192              30.00 1
      9002 other                running    8192              30.00 1235
EOF
    stub_out qm 'config 9000' <<'EOF'
name: ubuntu-cloud-template
template: 1
EOF
    stub_out qm 'config 9002' <<'EOF'
name: other
EOF

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=unknown$' <<< "$output"
    grep -q '^reason=fleet-version$' <<< "$output"
    grep -q '^upstream=2.336.0$' <<< "$output"
    refute_called qm 'guest exec *'
    [ "$(notify_count)" -eq 0 ]
}

@test "unknown fleet version does not report clean" {
    stub_latest v2.336.0 2026-08-20T00:00:00Z
    gen_store_init
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
EOF

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=unknown$' <<< "$output"
    ! grep -q '^status=clean$' <<< "$output"
    [ "$(notify_count)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GitHub API failure
# ---------------------------------------------------------------------------

@test "first GitHub API failure logs and does not notify or report clean" {
    stub_status curl '*' 22
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=unknown$' <<< "$output"
    grep -q '^reason=api-failed$' <<< "$output"
    grep -q '^fleet=2.334.0$' <<< "$output"
    ! grep -q '^status=clean$' <<< "$output"
    [[ "$stderr" == *"fail"* || "$stderr" == *"latest"* || "$stderr" == *"API"* || "$stderr" == *"release"* ]]
    [ "$(notify_count)" -eq 0 ]
    [ -f "$DRIFT_FAIL_FILE" ]
    grep -q '^first_fail=' "$DRIFT_FAIL_FILE"
    ! grep -q '^warned=' "$DRIFT_FAIL_FILE"
}

@test "successful fetch clears DRIFT_FAIL_FILE" {
    ensure_state_dir "$(dirname "$DRIFT_FAIL_FILE")"
    printf 'first_fail=2026-08-20T00:00:00Z\n' > "$DRIFT_FAIL_FILE"
    stub_latest v2.336.0 2026-08-20T00:00:00Z
    make_template_gen 2.336.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=clean$' <<< "$output"
    [ ! -f "$DRIFT_FAIL_FILE" ]
}

@test "consecutive API failure past DETECT_FAIL_WARN_HOURS notifies warn once" {
    stub_status curl '*' 22
    ensure_state_dir "$(dirname "$DRIFT_FAIL_FILE")"
    printf 'first_fail=2026-08-24T00:00:00Z\n' > "$DRIFT_FAIL_FILE"
    DETECT_FAIL_WARN_HOURS=24
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=unknown$' <<< "$output"
    ! grep -q '^status=clean$' <<< "$output"
    [ "$(notify_count)" -eq 1 ]
    grep -q '^warn ' "$STUB_DIR/notify.log"
    grep -q '^warned=' "$DRIFT_FAIL_FILE"
    grep -q '^first_fail=2026-08-24T00:00:00Z$' "$DRIFT_FAIL_FILE"

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    [ "$(notify_count)" -eq 1 ]
}

@test "empty GitHub payload is not a clean report" {
    stub_out curl '*' <<'EOF'
{}
EOF
    make_template_gen 2.336.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=unknown$' <<< "$output"
    grep -q '^reason=api-failed$' <<< "$output"
    ! grep -q '^status=clean$' <<< "$output"
    [ "$(notify_count)" -eq 0 ]
}

@test "malformed GitHub release timestamp counts as an API failure" {
    stub_latest v2.336.0 yesterday
    make_template_gen 2.336.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=unknown$' <<< "$output"
    grep -q '^reason=api-failed$' <<< "$output"
    ! grep -q '^status=clean$' <<< "$output"
    [ -f "$DRIFT_FAIL_FILE" ]
    grep -q '^first_fail=' "$DRIFT_FAIL_FILE"
    [ "$(notify_count)" -eq 0 ]
}

@test "malformed GitHub release version counts as an API failure" {
    stub_latest not-a-version 2026-08-20T00:00:00Z
    make_template_gen 2.336.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=unknown$' <<< "$output"
    grep -q '^reason=api-failed$' <<< "$output"
    [ -f "$DRIFT_FAIL_FILE" ]
    [ "$(notify_count)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------

@test "a failing notify does not fail drift_main" {
    NOTIFY_RC=1
    stub_latest v2.336.0 2026-07-20T00:00:00Z
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    grep -q '^status=error$' <<< "$output"
    grep -q 'drift.critical' "$STUB_DIR/notify.log"
}

@test "drift never destroys TEMPLATE_ID or any VM" {
    stub_latest v2.336.0 2026-07-20T00:00:00Z
    make_template_gen 2.334.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    refute_called qm 'destroy *'
    refute_called qm 'stop *'
    refute_called qm 'clone *'
    refute_called qm 'set *'
}

@test "drift fetches actions/runner releases/latest" {
    stub_latest v2.336.0 2026-08-20T00:00:00Z
    make_template_gen 2.336.0

    run --separate-stderr drift_main
    [ "$status" -eq 0 ]
    assert_called curl '*actions/runner/releases/latest*'
}
