#!/usr/bin/env bats
# Unattended maintain cycle: rebake window, dead-bake reconcile, two-actives.
#
# write_infra_config still defaults MIN_VMID=500, which overlaps the
# generation band, so tests set 9001. MAINTAIN_NOW_HHMM is a test-only
# clock; production reads date +%H:%M.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib maintain.sh
    # Keep the real implementations reachable before anything below shadows
    # them: a stub replaces a function, it does not stack on it. The tests that
    # drive the real gate, the real promote and the real drift check delegate
    # back through these names.
    copy_function drift_main real_drift_main
    copy_function canary_main real_canary_main
    copy_function promote_generation real_promote_generation
    MIN_VMID=9001
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    REBAKE_WINDOW="${REBAKE_WINDOW:-02:00-06:00}"
    REBAKE_ENABLED="${REBAKE_ENABLED:-true}"
    CANARY_ENABLED=false
    CANARY_REPO=""

    INSTALL_DIR="$STUB_DIR/install"
    mkdir -p "$INSTALL_DIR/templates"
    printf 'mirror: {{DOCKER_MIRROR_URL}}\n' > "$INSTALL_DIR/templates/template-setup.yaml"
    DOCKER_MIRROR_URL="http://mirror.example:8080"
    VLAN_TAG="20"
    DNS_SERVERS="1.1.1.1"
    BALLOON="0"

    jq_stub() {
        local json tag=""
        json=$(cat)
        if [[ "$*" != *tag_name* ]]; then
            printf 'jq stub: unhandled args: %s\n' "$*" >&2
            return 1
        fi
        if [[ "$json" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
            tag="${BASH_REMATCH[1]}"
        fi
        printf '%s\n' "$tag"
        return 0
    }
    export -f jq_stub

    notify() {
        printf '%s\n' "$*" >> "$STUB_DIR/notify.log"
    }

    bake_main() {
        {
            printf 'called\n'
            printf 'argc=%s\n' "$#"
            printf 'argv=%s\n' "$*"
        } >> "$STUB_DIR/bake_main.log"
        return 0
    }

    promote_generation() {
        printf 'called %s\n' "$*" >> "$STUB_DIR/promote.log"
        return 0
    }

    # The drift check is a cycle stage (spec 11.1). Stubbed for most tests for
    # the same reason bake_main is: they are about ordering and gating, not
    # about re-testing lib/drift.sh, which tests/unit/drift.bats owns. It
    # records the in-shell TEMPLATE_ID because that is the pointer the real
    # drift_fleet_version reads.
    drift_main() {
        printf 'called template_id=%s\n' "${TEMPLATE_ID:-}" >> "$STUB_DIR/drift.log"
        printf 'status=clean\n'
        return 0
    }

    # The canary gate's exit status is API (see the contract in lib/canary.sh).
    # The stub replays whichever branch a test asks for with set_canary_rc.
    #
    # A pass performs exactly what the real gate performs and nothing more: the
    # transitions, plus rewrite_template_id, which is how promote_generation
    # publishes the new pointer. It deliberately does NOT assign this shell's
    # TEMPLATE_ID -- the real gate never does, and a stub that did would
    # synthesise a reload production does not perform, hiding the bug the
    # cycle's own reload exists to prevent.
    canary_main() {
        printf '%s\n' "$*" >> "$STUB_DIR/canary.log"
        local rc=0 vmid
        [[ -f "$STUB_DIR/canary_rc" ]] && rc=$(cat "$STUB_DIR/canary_rc")
        if [[ "$rc" -eq 0 ]] && vmid=$(gen_vmid_for_id "$1" 2>/dev/null); then
            gen_transition "$vmid" active >/dev/null 2>&1 || true
            [[ "$vmid" == "${TEMPLATE_ID:-}" ]] ||
                gen_transition "${TEMPLATE_ID:-}" superseded >/dev/null 2>&1 || true
            rewrite_template_id "$vmid" >/dev/null 2>&1 || true
        elif [[ "$rc" -eq 4 ]] && vmid=$(gen_vmid_for_id "$1" 2>/dev/null); then
            gen_transition "$vmid" failed "canary rejected" >/dev/null 2>&1 || true
        fi
        return "$rc"
    }
}

# Keep a copy of a function under another name, so a stub can delegate the
# calls it does not care about back to the real implementation. Same helper
# tests/unit/canary.bats uses.
copy_function() {
    local from="$1" to="$2"
    eval "$(declare -f "$from" | sed "1s/^$from/$to/")"
}

set_canary_rc() {
    printf '%s' "$1" > "$STUB_DIR/canary_rc"
}

canary_log() {
    [[ -f "$STUB_DIR/canary.log" ]] && cat "$STUB_DIR/canary.log"
    return 0
}

canary_called() {
    [[ -f "$STUB_DIR/canary.log" ]]
}

drift_called() {
    [[ -f "$STUB_DIR/drift.log" ]]
}

# How many generation records are in <state>. `gen_list | grep -c` cannot be
# used: grep exits 1 on zero matches, which would read as a failed assertion
# rather than a count of nothing.
count_state() {
    local state="$1" vmid n=0
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        n=$((n + 1))
    done < <(gen_list "$state")
    printf '%s\n' "$n"
}

stub_digest_ok() {
    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0"}
EOF
    stub_out wget '*' <<'EOF'
abc123  *noble-server-cloudimg-amd64.img
EOF
}

make_active() {
    local digest="$1"
    shift || true
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z \
        "$@"
}

make_candidate() {
    local vmid="$1" gen_id="$2" digest="${3:-newdigest}"
    shift 3 2>/dev/null || shift $#
    gen_store_init
    gen_create "$vmid" \
        GEN_ID="$gen_id" \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        "$@"
}

bake_main_called() {
    [[ -f "$STUB_DIR/bake_main.log" ]]
}

# `! some_helper` is exempt from errexit unless it is the very last command in
# the test body (bash: "the shell does not exit ... if the command's return
# value is being inverted with !"), so a mid-body `! bake_main_called` asserts
# nothing at all. These return 1 uninverted, which does fail the test wherever
# it appears, and say what they saw.
refute_bake_main_called() {
    [[ -f "$STUB_DIR/bake_main.log" ]] || return 0
    printf 'expected no bake; bake_main was called:\n%s\n' \
        "$(cat "$STUB_DIR/bake_main.log")" >&2
    return 1
}

refute_canary_called() {
    [[ -f "$STUB_DIR/canary.log" ]] || return 0
    printf 'expected the canary gate not to run; it was called with:\n%s\n' \
        "$(cat "$STUB_DIR/canary.log")" >&2
    return 1
}

refute_drift_called() {
    [[ -f "$STUB_DIR/drift.log" ]] || return 0
    printf 'expected no drift check; it ran:\n%s\n' \
        "$(cat "$STUB_DIR/drift.log")" >&2
    return 1
}

# The gate must NOT have been invoked for this generation id.
refute_canary_gated() {
    local gen_id="$1"
    canary_log | grep -qx "$gen_id" || return 0
    printf 'expected generation %s not to be gated; canary log:\n%s\n' \
        "$gen_id" "$(canary_log)" >&2
    return 1
}

notify_log() {
    [[ -f "$STUB_DIR/notify.log" ]] && cat "$STUB_DIR/notify.log"
    return 0
}

# ---------------------------------------------------------------------------
# Syntax / wiring
# ---------------------------------------------------------------------------

@test "lib/maintain.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/maintain.sh"
}

@test "runner dispatches the maintain verb" {
    grep -Eq '^[[:space:]]*maintain\)' "$REPO_ROOT/runner"
    grep -q 'maintain' "$REPO_ROOT/runner"
}

@test "the maintain service allows a bake and both canary runs in one cycle" {
    # One cycle can gate a candidate left by a previous run AND gate the image
    # it bakes, so the unit has to survive BAKE_TIMEOUT plus TWO canary
    # budgets. Recomputed from the defaults rather than hard-coded, so a raised
    # budget fails here instead of getting a healthy run SIGTERMed.
    local unit="$REPO_ROOT/templates/github-runner-maintain.service"
    local timeout worst
    timeout=$(sed -n 's/^TimeoutStartSec=\([0-9]*\)$/\1/p' "$unit")
    [ -n "$timeout" ]
    apply_generation_defaults
    worst=$(( BAKE_TIMEOUT + 2 * (CANARY_REGISTER_TIMEOUT + CANARY_TIMEOUT) ))
    if (( timeout <= worst )); then
        printf 'TimeoutStartSec=%s does not cover bake+canary worst case %s\n' \
            "$timeout" "$worst" >&2
        return 1
    fi
}

@test "runner help documents the maintain cycle and its skip flags" {
    grep -q -- '--skip-canary' "$REPO_ROOT/runner"
    grep -q -- '--skip-bake' "$REPO_ROOT/runner"
    grep -q -- '--skip-drift' "$REPO_ROOT/runner"
    grep -q -- '--skip-gc' "$REPO_ROOT/runner"
}

@test "README documents the maintain cycle and the timer" {
    grep -q 'runner maintain' "$REPO_ROOT/README.md"
    grep -q 'github-runner-maintain.timer' "$REPO_ROOT/README.md"
    grep -q '02:30' "$REPO_ROOT/README.md"
}

@test "maintain timer fires daily at 02:30 with Persistent=true" {
    local timer="$REPO_ROOT/templates/github-runner-maintain.timer"
    grep -qF 'OnCalendar=*-*-* 02:30:00' "$timer"
    grep -q 'Persistent=true' "$timer"
    grep -q 'WantedBy=timers.target' "$timer"
}

@test "maintain service runs runner maintain as oneshot" {
    local unit="$REPO_ROOT/templates/github-runner-maintain.service"
    grep -q 'Type=oneshot' "$unit"
    grep -q 'ExecStart=/usr/local/bin/runner maintain' "$unit"
    grep -q 'SyslogIdentifier=github-runner-maintain' "$unit"
}

@test "setup.sh preserves NOTIFY_* keys in the config writer" {
    grep -q 'existing_conf_value NOTIFY_WEBHOOK_URL' "$REPO_ROOT/lib/setup.sh"
    grep -q 'existing_conf_value NOTIFY_MIN_SEVERITY' "$REPO_ROOT/lib/setup.sh"
    grep -q 'existing_conf_value NOTIFY_FORMAT' "$REPO_ROOT/lib/setup.sh"
    grep -q 'printf.*NOTIFY_WEBHOOK_URL' "$REPO_ROOT/lib/setup.sh"
    grep -q 'printf.*NOTIFY_MIN_SEVERITY' "$REPO_ROOT/lib/setup.sh"
    grep -q 'printf.*NOTIFY_FORMAT' "$REPO_ROOT/lib/setup.sh"
}

@test "setup.sh installs maintain units, enables the timer, and documents disable" {
    grep -q 'github-runner-maintain.service' "$REPO_ROOT/lib/setup.sh"
    grep -q 'github-runner-maintain.timer' "$REPO_ROOT/lib/setup.sh"
    grep -q 'enable --now github-runner-maintain.timer' "$REPO_ROOT/lib/setup.sh"
    grep -q 'systemctl disable --now github-runner-maintain.timer' "$REPO_ROOT/lib/setup.sh"
}

@test "install.sh refreshes maintain units and adopts without baking" {
    grep -q 'github-runner-maintain.service' "$REPO_ROOT/install.sh"
    grep -q 'github-runner-maintain.timer' "$REPO_ROOT/install.sh"
    grep -q 'enable --now github-runner-maintain.timer' "$REPO_ROOT/install.sh"
    grep -q 'adopt_deployed_template' "$REPO_ROOT/install.sh"
    ! grep -q 'bake_main' "$REPO_ROOT/install.sh"
}

@test "install.sh adopts before enabling maintain.timer" {
    awk '
        /adopt_deployed_template/ { a = NR }
        /enable --now github-runner-maintain.timer/ { e = NR }
        END {
            if (!a || !e) exit 1
            if (!(a < e)) exit 1
        }
    ' "$REPO_ROOT/install.sh"
}

# ---------------------------------------------------------------------------
# Window helper (MAINTAIN_NOW_HHMM is test-only)
# ---------------------------------------------------------------------------

@test "in_rebake_window is true at 03:00 inside 02:00-06:00" {
    REBAKE_WINDOW=02:00-06:00
    MAINTAIN_NOW_HHMM=03:00
    run in_rebake_window
    [ "$status" -eq 0 ]
}

@test "in_rebake_window is true at the 02:00 start and 06:00 end" {
    REBAKE_WINDOW=02:00-06:00
    MAINTAIN_NOW_HHMM=02:00
    run in_rebake_window
    [ "$status" -eq 0 ]
    MAINTAIN_NOW_HHMM=06:00
    run in_rebake_window
    [ "$status" -eq 0 ]
}

@test "in_rebake_window is false outside 02:00-06:00" {
    REBAKE_WINDOW=02:00-06:00
    MAINTAIN_NOW_HHMM=01:59
    run in_rebake_window
    [ "$status" -ne 0 ]
    MAINTAIN_NOW_HHMM=06:01
    run in_rebake_window
    [ "$status" -ne 0 ]
    MAINTAIN_NOW_HHMM=07:00
    run in_rebake_window
    [ "$status" -ne 0 ]
}

@test "invalid REBAKE_WINDOW logs an error and is treated as outside" {
    REBAKE_WINDOW=not-a-window
    MAINTAIN_NOW_HHMM=03:00
    run in_rebake_window
    [ "$status" -ne 0 ]
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"REBAKE_WINDOW"* ]]
}

@test "wrap-past-midnight REBAKE_WINDOW is invalid and outside" {
    REBAKE_WINDOW=22:00-02:00
    MAINTAIN_NOW_HHMM=23:00
    run in_rebake_window
    [ "$status" -ne 0 ]
    [[ "$output" == *"[ERROR]"* ]]
}

# ---------------------------------------------------------------------------
# maintain_main cycle
# ---------------------------------------------------------------------------

@test "maintain on a current generation does nothing and says so" {
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active "$digest" GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
    [[ "$output" == *"up-to-date"* ]]
    refute_bake_main_called
    [ ! -f "$STUB_DIR/promote.log" ]
}

@test "maintain outside REBAKE_WINDOW does not call bake_main" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=07:00
    REBAKE_WINDOW=02:00-06:00

    run maintain_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"deferring bake until REBAKE_WINDOW"* ]]
    refute_bake_main_called
}

@test "maintain inside the window with unknown digest calls bake_main" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    REBAKE_WINDOW=02:00-06:00

    run maintain_main
    [ "$status" -eq 0 ]
    bake_main_called
    grep -qx 'called' "$STUB_DIR/bake_main.log"
    grep -qx 'argc=0' "$STUB_DIR/bake_main.log"
    # `! grep` here is not the last command in the body, so errexit exempts it
    # and it would assert nothing; grep -c is counted instead.
    [ "$(grep -c -- '--force' "$STUB_DIR/bake_main.log" || true)" = "0" ]
    [ ! -f "$STUB_DIR/promote.log" ]
}

@test "REBAKE_ENABLED=false never starts a bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    REBAKE_ENABLED=false

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    [[ "$output" == *"rebake-disabled"* || "$output" == *"nothing to do"* ]]
}

@test "CANARY_ENABLED=true with empty CANARY_REPO refuses to bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    CANARY_ENABLED=true
    CANARY_REPO=""

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    notify_log | grep -q 'warn canary.unconfigured'
    [[ "$output" == *"unknown-digest"* || "$(notify_log)" == *"canary.unconfigured"* ]]
}

@test "CANARY_ENABLED=true with a whitespace-only CANARY_REPO refuses to bake" {
    # The gate (lib/canary.sh) and maintain share canary_repo_configured, so a
    # value that looks set but is not must stop both of them, not just one.
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    CANARY_ENABLED=true
    CANARY_REPO="   "

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    notify_log | grep -q 'warn canary.unconfigured'
}

@test "CANARY_ENABLED=true with empty CANARY_REPO notifies even outside REBAKE_WINDOW" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=07:00
    REBAKE_WINDOW=02:00-06:00
    CANARY_ENABLED=true
    CANARY_REPO=""

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    notify_log | grep -q 'warn canary.unconfigured'
    [[ "$output" != *"deferring bake until REBAKE_WINDOW"* ]]
}

@test "invalid REBAKE_WINDOW does not claim a later in-window bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    REBAKE_WINDOW=not-a-window
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"REBAKE_WINDOW"* ]]
    [[ "$output" != *"deferring bake until REBAKE_WINDOW"* ]]
}

# ---------------------------------------------------------------------------
# Dead baking / lock
# ---------------------------------------------------------------------------

@test "dead baking record with free bake lock is failed and the VM destroyed" {
    gen_store_init
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=unknown
    stub_out qm 'status 8900' <<'EOF'
status: running
EOF
    stub_out qm 'config 8900' <<'EOF'
name: github-runner-gen-2
EOF
    stub_out qm 'stop 8900*' < /dev/null
    stub_out qm 'destroy 8900*' < /dev/null
    stub_out pvesm 'list *' <<'EOF'
Volid Format
EOF

    run maintain_reconcile_baking
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "failed" ]
    [[ "$GEN_FAILED_REASON" == *"host reboot or interrupted bake"* ]]
    assert_called qm 'stop 8900*'
    assert_called qm 'destroy 8900*'
    local calls stop_at destroy_at
    calls=$(stub_calls qm)
    stop_at=$(printf '%s\n' "$calls" | grep -n '^stop 8900' | head -1 | cut -d: -f1)
    destroy_at=$(printf '%s\n' "$calls" | grep -n '^destroy 8900' | head -1 | cut -d: -f1)
    [ -n "$stop_at" ]
    [ -n "$destroy_at" ]
    [ "$stop_at" -lt "$destroy_at" ]
    refute_called qm "destroy ${TEMPLATE_ID}*"
    refute_called qm "stop ${TEMPLATE_ID}*"
    digest_is_memoed deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    notify_log | grep -q 'bake.failed'
}

@test "baking record is left alone when the bake lock is held" {
    gen_store_init
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        GEN_IMAGE_SHA256=abc
    mkdir -p "$(dirname "$BAKE_LOCK_FILE")"
    exec 207>"$BAKE_LOCK_FILE"
    flock -n 207

    run maintain_reconcile_baking
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "baking" ]
    refute_called qm 'destroy *'
    refute_called qm 'stop *'
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'bake.failed' "$STUB_DIR/notify.log"
}

@test "dead baking at TEMPLATE_ID is failed but the VM is not destroyed" {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe \
        GEN_IMAGE_SHA256=abc
    stub_out qm 'status 9000' <<'EOF'
status: running
EOF

    run maintain_reconcile_baking
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "failed" ]
    [[ "$GEN_FAILED_REASON" == *"host reboot or interrupted bake"* ]]
    refute_called qm 'destroy *'
    refute_called qm 'stop *'
    digest_is_memoed cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe
    notify_log | grep -q 'bake.failed'
}

@test "dead baking with no VM still frees leftover volumes" {
    gen_store_init
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        GEN_IMAGE_SHA256=abc
    stub_status qm 'status 8900' 1
    stub_status qm 'config 8900' 1
    stub_out pvesm 'list *' <<EOF
Volid Format
${VM_STORAGE}:vm-8900-disk-0 raw
${VM_STORAGE}:vm-8900-cloudinit raw
EOF
    stub_out pvesm "free ${VM_STORAGE}:vm-8900-disk-0" < /dev/null
    stub_out pvesm "free ${VM_STORAGE}:vm-8900-cloudinit" < /dev/null

    run maintain_reconcile_baking
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "failed" ]
    [[ "$GEN_FAILED_REASON" == *"host reboot or interrupted bake"* ]]
    refute_called qm 'stop *'
    refute_called qm 'destroy *'
    assert_called pvesm "list ${VM_STORAGE}"
    assert_called pvesm "free ${VM_STORAGE}:vm-8900-disk-0"
    assert_called pvesm "free ${VM_STORAGE}:vm-8900-cloudinit"
    notify_log | grep -q 'bake.failed'
}

@test "dead baking with a foreign name is failed but the VM is not destroyed" {
    gen_store_init
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        GEN_IMAGE_SHA256=abc
    stub_out qm 'status 8900' <<'EOF'
status: running
EOF
    stub_out qm 'config 8900' <<'EOF'
name: foreign-vm
EOF

    run maintain_reconcile_baking
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "failed" ]
    refute_called qm 'destroy *'
    refute_called qm 'stop *'
    refute_called pvesm 'free *'
}

# ---------------------------------------------------------------------------
# Two actives
# ---------------------------------------------------------------------------

@test "two actives: TEMPLATE_ID wins, not the higher GEN_ID" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z
    gen_create 8900 \
        GEN_ID=99 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "superseded" ]
    notify_log | grep -q 'warn'
}

@test "zero actives with TEMPLATE_ID pointing at a superseded record → it becomes active" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z \
        GEN_SUPERSEDED_AT=2026-08-20T00:00:00Z

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    notify_log | grep -q 'warn'
    notify_log | grep -q 'generation.reconciled'
}

@test "zero actives with TEMPLATE_ID pointing at a failed record stays failed" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=failed \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_FAILED_REASON="bake failed"

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "failed" ]
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'generation.reconciled' "$STUB_DIR/notify.log"
    [[ "$output" == *"not forcing"* ]]
}

@test "zero actives with TEMPLATE_ID pointing at a candidate record → it becomes active" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    notify_log | grep -q 'generation.reconciled'
}

@test "zero actives with TEMPLATE_ID pointing at a rejected record stays rejected" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=rejected \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "rejected" ]
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'generation.reconciled' "$STUB_DIR/notify.log"
    [[ "$output" == *"not forcing"* ]]
}

@test "zero actives with TEMPLATE_ID pointing at a baking record stays baking" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "baking" ]
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'generation.reconciled' "$STUB_DIR/notify.log"
    [[ "$output" == *"not forcing"* ]]
}

@test "dead-bake reconcile does not memo a generation that is no longer baking" {
    gen_store_init
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        GEN_IMAGE_SHA256=abc
    stub_out qm 'config 8900' <<'EOF'
name: github-runner-gen-2
template: 1
EOF

    run maintain_fail_dead_bake 8900
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    run digest_is_memoed deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    [ "$status" -eq 1 ]
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'bake.failed' "$STUB_DIR/notify.log"
    refute_called qm 'destroy *'
}

@test "stale promotion pause is cleared when the pool lock is free" {
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")"
    : > "$PROMOTION_PAUSE_FILE"
    run maintain_clear_stale_promotion_pause
    [ "$status" -eq 0 ]
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
    [[ "$output" == *"stale promotion pause"* ]]
}

@test "promotion pause is left when the pause file is flocked" {
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")"
    exec 211>"$PROMOTION_PAUSE_FILE"
    flock -n 211
    run maintain_clear_stale_promotion_pause
    [ "$status" -eq 0 ]
    [ -e "$PROMOTION_PAUSE_FILE" ]
    exec 211>&- 2>/dev/null || true
}

@test "stale promotion pause is cleared even when the pool lock is held" {
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")" "$(dirname "$POOL_ACTIVITY_LOCK_FILE")"
    : > "$PROMOTION_PAUSE_FILE"
    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -n -x 202
    run maintain_clear_stale_promotion_pause
    [ "$status" -eq 0 ]
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
    exec 202>&- 2>/dev/null || true
}

@test "two-actives skipped while the exclusive pool lock is held" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z
    mkdir -p "$(dirname "$POOL_ACTIVITY_LOCK_FILE")"
    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -n -x 202
    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    exec 202>&- 2>/dev/null || true
}

@test "two-actives skipped while pause file exists" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")"
    : > "$PROMOTION_PAUSE_FILE"

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'generation.reconciled' "$STUB_DIR/notify.log"
}

@test "unreadable gen_list fails maintain" {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=abc \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        GEN_IMAGE_SHA256=abc
    printf 'garbage\n' >> "$GENERATIONS_DIR/8900.conf"

    run maintain_main
    [ "$status" -ne 0 ]
    refute_called qm 'destroy *'
    refute_called qm 'stop *'
}

@test "two actives without a TEMPLATE_ID match keep newest GEN_PROMOTED_AT not highest GEN_ID" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 8900 \
        GEN_ID=9 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=a \
        GEN_IMAGE_SHA256=abc \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z
    gen_create 8901 \
        GEN_ID=5 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=b \
        GEN_IMAGE_SHA256=def \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 8901
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "superseded" ]
    notify_log | grep -q 'warn'
}

@test "post-rollback two actives keep TEMPLATE_ID, never the highest GEN_ID" {
    # Crash after rollback rewrote the pointer and re-activated gen 1, before
    # the escaped generation was rejected. Highest GEN_ID is the image the
    # operator just left.
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-25T00:00:00Z
    gen_create 8900 \
        GEN_ID=99 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "superseded" ]
    notify_log | grep -q 'warn'
}

@test "reconcile never re-activates a rejected generation after rollback" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-25T00:00:00Z
    gen_create 8900 \
        GEN_ID=99 \
        GEN_STATE=rejected \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z \
        GEN_FAILED_REASON='jobs failing on 2.336.0'

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "rejected" ]
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'generation.reconciled' "$STUB_DIR/notify.log"
}

@test "zero actives after rollback restores TEMPLATE_ID, not the rejected higher GEN_ID" {
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z \
        GEN_SUPERSEDED_AT=2026-08-20T00:00:00Z
    gen_create 8900 \
        GEN_ID=99 \
        GEN_STATE=rejected \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z \
        GEN_FAILED_REASON='rolled back'

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "rejected" ]
    notify_log | grep -q 'generation.reconciled'
}

# ---------------------------------------------------------------------------
# Canary gate inside the cycle (issue #24 item 1; spec 7.5, 11.1)
#
# canary_main's exit status is the contract documented at the top of
# lib/canary.sh: 0 promoted, 1 gate error, 2 not attempted, 3 attempt failed
# with attempts remaining, 4 budget spent. The cycle branches on all five.
# ---------------------------------------------------------------------------

@test "a candidate is gated through the canary by generation id" {
    stub_digest_ok
    make_active olddigest GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 0
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    canary_log | grep -qx '2'
}

@test "a canary pass promotes the candidate and the cycle continues" {
    stub_digest_ok
    make_active olddigest GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 0
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"canary passed"* ]]
    [ "$(count_state candidate)" = "0" ]
    [ "$(count_state active)" = "1" ]
    drift_called
}

@test "canary rc=2 (not attempted) does not bake a second candidate" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 2
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    canary_called
    refute_bake_main_called
    [[ "$output" == *"waiting on the canary gate"* ]]
    [ "$(count_state candidate)" = "1" ]
}

@test "canary rc=3 (attempt failed, attempts remain) retries next cycle without baking" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 3
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"retry"* ]]
    refute_bake_main_called
    [ "$(count_state candidate)" = "1" ]
}

@test "canary rc=4 (budget spent) leaves no candidate and lets a different digest bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 4
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    [ "$(count_state candidate)" = "0" ]
    bake_main_called
}

@test "canary rc=4 does not rebake the memoed digest" {
    # Spec 6.3/7.5: the digest the gate rejected is memoed, and detect refuses
    # it. bake_main's own memo check is what has to hold here.
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    make_active "$digest" GEN_CREATED_AT=2026-08-01T00:00:00Z
    make_candidate 8901 2 "$digest"
    memo_failed_digest "$digest"
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 4
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    [[ "$output" == *"memoed"* ]]
}

@test "canary rc=1 (gate error) fails the cycle and starts no bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 1
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -ne 0 ]
    refute_bake_main_called
    notify_log | grep -q 'error maintain.canary_error'
}

@test "a gate error still runs the drift check before failing" {
    # Spec 11.4: drift is independent of the bake pipeline, so it still fires
    # when the pipeline is broken.
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 1
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -ne 0 ]
    drift_called
}

@test "no candidate means the canary gate is not invoked" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    refute_canary_called
}

@test "a freshly baked candidate is gated in the same cycle" {
    # Acceptance: with a stale generation a full cycle runs bake, canary,
    # promote unattended -- not bake now and canary tomorrow.
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 0
    MAINTAIN_NOW_HHMM=03:00
    bake_main() {
        printf 'called\n' >> "$STUB_DIR/bake_main.log"
        make_candidate 8901 2
    }

    run maintain_main
    [ "$status" -eq 0 ]
    bake_main_called
    canary_log | grep -qx '2'
    [ "$(count_state candidate)" = "0" ]
}

@test "CANARY_ENABLED=false leaves a candidate for the operator and does not bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=false
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    refute_canary_called
    refute_bake_main_called
    [[ "$output" == *"runner upgrade"* ]]
    notify_log | grep -q 'warn maintain.candidate_pending'
}

@test "the candidate-pending notice is not repeated every cycle" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=false
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    run maintain_main
    [ "$status" -eq 0 ]
    run maintain_main
    [ "$status" -eq 0 ]
    [ "$(grep -c 'maintain.candidate_pending' "$STUB_DIR/notify.log")" = "1" ]
}

@test "a different candidate notices again" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=false
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    gen_transition 8901 failed "operator rejected"
    make_candidate 8902 3

    run maintain_main
    [ "$status" -eq 0 ]
    [ "$(grep -c 'maintain.candidate_pending' "$STUB_DIR/notify.log")" = "2" ]
}

# ---------------------------------------------------------------------------
# Drift inside the cycle (issue #24 item 3; spec 11.1 lists the drift check as
# a cycle stage, 11.4 makes it independent of the bake pipeline)
# ---------------------------------------------------------------------------

@test "maintain runs the drift check every cycle" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    drift_called
}

@test "the drift check runs on a healthy fleet with nothing else to do" {
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active "$digest" GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
    drift_called
}

@test "the drift check runs outside the rebake window" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=07:00

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    drift_called
}

@test "REBAKE_ENABLED=false leaves garbage collection and the drift check running" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    REBAKE_ENABLED=false
    gc_main() { printf 'called %s\n' "$*" >> "$STUB_DIR/gc.log"; return 0; }

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    [ -f "$STUB_DIR/gc.log" ]
    drift_called
}

@test "a failing garbage collection does not silence the rest of the cycle" {
    # A manual bake or upgrade holding the bake lock is enough to time GC out.
    # Spec 11.4 wants the drift alarm firing precisely then, so the failure
    # goes into the exit status and the cycle carries on.
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    gc_main() { log_error "gc exploded"; return 1; }

    run maintain_main
    [ "$status" -ne 0 ]
    bake_main_called
    drift_called
}

@test "the rebake window gates only maintain, never runner bake --force" {
    # Issue #24 item 4. The window helper lives in maintain.sh and lib/bake.sh
    # never consults it, so --force cannot be blocked by the clock. Scoped to
    # code lines: a comment naming the window is not a gate.
    grep -q 'in_rebake_window' "$REPO_ROOT/lib/maintain.sh"
    run grep -nE '^[[:space:]]*[^#[:space:]].*(in_rebake_window|REBAKE_WINDOW)' \
        "$REPO_ROOT/lib/bake.sh"
    [ "$status" -ne 0 ]
}

@test "the drift timer stays installed alongside the maintain timer" {
    # Spec 11.4: the alarm is independent of the bake pipeline, so it keeps its
    # own 6-hourly timer as well as running inside the cycle.
    grep -q 'github-runner-drift.timer' "$REPO_ROOT/lib/setup.sh"
    grep -q 'enable --now github-runner-drift.timer' "$REPO_ROOT/lib/setup.sh"
    grep -q 'github-runner-drift.timer' "$REPO_ROOT/install.sh"
    grep -q 'enable --now github-runner-drift.timer' "$REPO_ROOT/install.sh"
}

# ---------------------------------------------------------------------------
# Stage skipping (issue #24 item 1)
# ---------------------------------------------------------------------------

@test "maintain --help lists every skip flag and exits 0" {
    run maintain_main --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--skip-adopt"* ]]
    [[ "$output" == *"--skip-reconcile"* ]]
    [[ "$output" == *"--skip-gc"* ]]
    [[ "$output" == *"--skip-canary"* ]]
    [[ "$output" == *"--skip-bake"* ]]
    [[ "$output" == *"--skip-drift"* ]]
}

@test "maintain rejects an unknown option with usage" {
    run maintain_main --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: runner maintain"* ]]
}

@test "--skip-gc skips garbage collection" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    gc_main() { printf 'called\n' >> "$STUB_DIR/gc.log"; return 0; }

    run maintain_main --skip-gc
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/gc.log" ]
    drift_called
}

@test "--skip-canary skips the gate but still refuses to bake over the candidate" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 0
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main --skip-canary
    [ "$status" -eq 0 ]
    refute_canary_called
    refute_bake_main_called
}

@test "--skip-bake runs every other stage and starts no bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main --skip-bake
    [ "$status" -eq 0 ]
    refute_bake_main_called
    drift_called
}

@test "--skip-drift skips the drift check" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main --skip-drift
    [ "$status" -eq 0 ]
    refute_drift_called
}

@test "--skip-reconcile leaves a dead baking record alone" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=deadbeef \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=unknown
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main --skip-reconcile --skip-gc
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "baking" ]
    refute_called qm 'destroy*'
}

@test "--skip-adopt does not adopt" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    adopt_deployed_template() { printf 'called\n' >> "$STUB_DIR/adopt.log"; return 0; }

    run maintain_main --skip-adopt
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/adopt.log" ]
}

# ---------------------------------------------------------------------------
# Interrupt and re-run (acceptance: no duplicate generations)
# ---------------------------------------------------------------------------

@test "a bake interrupted after the record was written leaves exactly one candidate" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    # What a SIGKILL mid-bake leaves behind: a baking record, no bake lock.
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=deadbeef \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=unknown
    stub_out qm 'status 8900' <<'EOF'
status: stopped
EOF
    stub_out qm 'config 8900' < /dev/null
    stub_out qm 'destroy 8900*' < /dev/null
    stub_out pvesm '*' < /dev/null
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 2
    MAINTAIN_NOW_HHMM=03:00
    bake_main() {
        printf 'called\n' >> "$STUB_DIR/bake_main.log"
        gen_exists 8902 || make_candidate 8902 3
    }

    run maintain_main
    [ "$status" -eq 0 ]
    run maintain_main
    [ "$status" -eq 0 ]

    [ "$(count_state candidate)" = "1" ]
    [ "$(count_state baking)" = "0" ]
}

@test "a canary interrupted mid-attempt is re-gated with no duplicate candidate" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2 newdigest GEN_CANARY_ATTEMPTS=1
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 3
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    [ "$(count_state candidate)" = "1" ]

    set_canary_rc 0
    run maintain_main
    [ "$status" -eq 0 ]
    [ "$(count_state candidate)" = "0" ]
    [ "$(count_state active)" = "1" ]
}

@test "a promotion interrupted between promote and demote leaves exactly one active" {
    stub_digest_ok
    # The demoted generation becomes GC's retained rollback target, so GC
    # refcounts it -- an inventory it cannot read is a GC failure, not the
    # reconcile behavior under test.
    stub_out qm 'list*' <<'EOF'
      VMID NAME                 STATUS
EOF
    stub_out pvesm 'list *' < /dev/null
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z
    gen_create 8901 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-25T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    run maintain_main
    [ "$status" -eq 0 ]

    [ "$(count_state active)" = "1" ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
}

# ---------------------------------------------------------------------------
# Concurrency (acceptance: a concurrent manual maintain does not kill a bake)
# ---------------------------------------------------------------------------

# Hold BAKE_LOCK_FILE exclusively from another process, the way a live bake
# does. flock is deliberately real -- the harness does not stub it -- and the
# lock lives on the open file description, so the subshell holds it.
hold_bake_lock() {
    local ready="$STUB_DIR/bake-holder-ready"
    rm -f "$ready"
    mkdir -p "$(dirname "$BAKE_LOCK_FILE")"
    (
        exec 220>"$BAKE_LOCK_FILE"
        flock -x 220 || exit 1
        : > "$ready"
        sleep 60
    ) &
    BAKE_HOLDER_PID=$!
    local waited=0
    while [[ ! -e "$ready" && "$waited" -lt 200 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    [ -e "$ready" ]
}

teardown() {
    [[ -z "${BAKE_HOLDER_PID:-}" ]] || kill "$BAKE_HOLDER_PID" 2>/dev/null || true
}

@test "a concurrent maintain does not kill an in-flight bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=baking \
        GEN_TEMPLATE_DIGEST=deadbeef \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=unknown
    MAINTAIN_NOW_HHMM=03:00
    hold_bake_lock
    # GC waits on the same bake lock for 30s; the stage under test is the
    # reconcile, so skip it rather than sleep out the timeout.
    run maintain_main --skip-gc
    [ "$status" -eq 0 ]

    gen_read 8900
    [ "$GEN_STATE" = "baking" ]
    refute_called qm 'destroy*'
    [[ "$output" == *"Bake lock is held"* ]]
}

# ---------------------------------------------------------------------------
# The active pointer after an in-cycle promotion (review round 1, C1)
#
# promote_generation rewrites TEMPLATE_ID in CONFIG_FILE and never assigns the
# calling shell's copy -- lib/upgrade.sh compensates the same way after its own
# promote. detect_should_bake and drift_fleet_version both read the in-shell
# copy, so the cycle has to reload it or it acts on the generation it just
# superseded.
# ---------------------------------------------------------------------------

@test "an in-cycle promotion of the current digest is not followed by a bake" {
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-26T00:00:00Z'; }
    make_active olddigest GEN_CREATED_AT=2026-08-20T00:00:00Z
    make_candidate 8901 2 "$digest" GEN_CREATED_AT=2026-08-25T00:00:00Z
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 0
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"canary passed"* ]]
    [[ "$output" == *"up-to-date"* ]]
    refute_bake_main_called
    [ "$(count_state candidate)" = "0" ]
    [ "$(count_state active)" = "1" ]
}

@test "the cycle re-reads the active pointer after a promotion" {
    stub_digest_ok
    make_active olddigest GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 0
    MAINTAIN_NOW_HHMM=03:00
    printf '%s\n' "$(reload_active_template_id)" > "$STUB_DIR/pointer-before"

    run maintain_main
    [ "$status" -eq 0 ]
    grep -qx '9000' "$STUB_DIR/pointer-before"
    [ "$(reload_active_template_id)" = "8901" ]
}

@test "the drift check runs against the newly promoted generation" {
    stub_digest_ok
    make_active olddigest GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8901 2
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 0
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    grep -q 'template_id=8901' "$STUB_DIR/drift.log"
    if grep -q 'template_id=9000' "$STUB_DIR/drift.log"; then
        printf 'drift ran against the superseded pointer:\n%s\n' \
            "$(cat "$STUB_DIR/drift.log")" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Newest candidate is GEN_ID, not VMID (review round 1, I1)
#
# allocate_generation_vmid hands out the LOWEST free band VMID, so after GC
# frees a lower slot the newer generation sits below the older one. GC picks by
# GEN_ID; the gate has to agree or the two act on different records.
# ---------------------------------------------------------------------------

@test "the newer candidate is gated even when its VMID is lower" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8905 2       # older generation, higher VMID
    make_candidate 8901 7       # newer generation, lower VMID
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 2
    MAINTAIN_NOW_HHMM=03:00
    # gc_reconcile_candidates would supersede the older candidate before the
    # gate ever saw it. The selector is what is under test, so leave both
    # standing.
    gc_main() { return 0; }

    run maintain_main
    [ "$status" -eq 0 ]
    canary_log | grep -qx '7'
    refute_canary_gated 2
}

@test "maintain and gc agree on which candidate is newest" {
    # Same selector, so a change to one cannot silently diverge from the other.
    grep -q 'gen_newest_candidate' "$REPO_ROOT/lib/gc.sh"
    grep -q 'gen_newest_candidate' "$REPO_ROOT/lib/maintain.sh"
    grep -q '^gen_newest_candidate' "$REPO_ROOT/lib/generations.sh"
}

@test "more than one candidate is reported once per cycle, not once per read" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    make_candidate 8905 2
    make_candidate 8901 7
    CANARY_ENABLED=true
    CANARY_REPO=acme/canary
    set_canary_rc 2
    MAINTAIN_NOW_HHMM=03:00
    gc_main() { return 0; }

    run maintain_main
    [ "$status" -eq 0 ]
    # The cycle reads the store three times (gate, pre-bake, post-bake).
    [ "$(grep -c 'candidate generations exist' <<< "$output")" = "1" ]
}

# ---------------------------------------------------------------------------
# The drift check runs on every exit path (review round 1, I2)
# ---------------------------------------------------------------------------

@test "a failed adoption still runs the drift check" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    adopt_deployed_template() { log_error "adoption exploded"; return 1; }

    run maintain_main
    [ "$status" -ne 0 ]
    refute_bake_main_called
    drift_called
}

@test "a failed reconcile still runs the drift check" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    maintain_reconcile_two_actives() { log_error "reconcile exploded"; return 1; }

    run maintain_main
    [ "$status" -ne 0 ]
    refute_bake_main_called
    drift_called
}

@test "a halted cycle does not garbage-collect or bake on an untrusted store" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    gc_main() { printf 'called\n' >> "$STUB_DIR/gc.log"; return 0; }
    maintain_reconcile_baking() { log_error "reconcile exploded"; return 1; }

    run maintain_main
    [ "$status" -ne 0 ]
    [ ! -f "$STUB_DIR/gc.log" ]
    refute_bake_main_called
    drift_called
}

# ---------------------------------------------------------------------------
# The real gate and the real drift check, driven through maintain_main
# (review round 1, C2)
#
# Everywhere else in this file canary_main and drift_main are stubs, which
# proves the cycle's branching but not that the cycle composes with the real
# implementations. These two do: GitHub is faked at curl, Proxmox at qm, and
# only the clone/lookup/deregister seams tests/unit/canary.bats also replaces
# are stubbed. The promotion here is a real promote_generation, so the pointer
# really is rewritten on disk and never in this shell -- which is what makes
# the cycle's reload load-bearing rather than decorative.
# ---------------------------------------------------------------------------

# Ported from tests/unit/canary.bats: every call answers "configured,
# reachable, and the run passed".
stub_canary_api_ok() {
    stub_out curl '*-D -*api.github.com/' <<'EOF'
HTTP/2 200
x-github-api-version-selected: 2022-11-28
x-oauth-scopes: admin:org, repo

200
EOF
    stub_out curl '*/repos/acme-org/canary-repo' <<'EOF'
{"default_branch": "main", "private": true, "full_name": "acme-org/canary-repo"}
200
EOF
    stub_out curl '*/actions/workflows/runner-canary.yml' <<'EOF'
{"id": 4242, "state": "active", "path": ".github/workflows/runner-canary.yml"}
200
EOF
    stub_out curl '*/actions/workflows/runner-canary.yml/dispatches' <<'EOF'
HTTP/2 204
date: Sun, 06 Sep 2026 07:00:00 GMT

204
EOF
    stub_out curl '*per_page=1' <<'EOF'
{"workflow_runs": [{"id": 9000, "created_at": "2026-09-06T06:00:00Z"}]}
200
EOF
    stub_out curl '*per_page=30' <<'EOF'
{"workflow_runs": [{"id": 9911, "display_title": "Runner canary gen-2", "created_at": "2026-09-06T07:00:05Z", "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}]}
200
EOF
    stub_out curl '*/actions/runs/9911' <<'EOF'
{"id": 9911, "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme-org/canary-repo/actions/runs/9911"}
200
EOF
}

@test "the real canary gate promotes through the cycle and no twin is baked" {
    canary_main() { real_canary_main "$@"; }
    promote_generation() { real_promote_generation "$@"; }
    jq() { /usr/bin/jq "$@"; }

    CANARY_ENABLED=true
    CANARY_ORG=acme
    CANARY_REPO=acme-org/canary-repo
    CANARY_WORKFLOW=runner-canary.yml
    CANARY_PAT=""
    CANARY_POLL_SECONDS=0
    CANARY_REGISTER_POLL_SECONDS=0
    write_org_config acme ghp_test acme-org

    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-09-06T00:00:00Z'; }
    make_active olddigest GEN_CREATED_AT=2026-09-05T00:00:00Z
    make_candidate 8901 2 "$digest" GEN_CREATED_AT=2026-09-06T00:00:00Z

    # The seams canary.bats replaces too: a clone, the GitHub runner lookup,
    # and the deregister. Everything between them is the real gate.
    clone_canary_runner() { printf '9501\n'; }
    github_runner_lookup_details() { printf '77\tfalse\tonline\n'; }
    deregister_runner() { :; }
    stub_out qm 'destroy *' < /dev/null
    stub_out qm 'set *' < /dev/null
    stub_out qm 'config *' <<'EOF'
template: 1
EOF
    stub_out qm 'status *' <<'EOF'
status: stopped
EOF
    stub_out qm 'list*' <<'EOF'
      VMID NAME                 STATUS
EOF
    stub_out pvesm 'list *' < /dev/null
    stub_canary_api_ok
    MAINTAIN_NOW_HHMM=03:00

    # --separate-stderr, as every test in tests/unit/canary.bats does: the gate
    # closes its lock fd with `exec 218>&-`, which collides with the fd bats
    # `run` captures merged output on and silently swallows everything logged
    # after the gate returns.
    run --separate-stderr maintain_main
    [ "$status" -eq 0 ]
    gen_read 8901
    [ "$GEN_STATE" = "active" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
    # The real promote wrote the pointer on disk; the cycle re-read it.
    [ "$(reload_active_template_id)" = "8901" ]
    # No twin: without the pointer reload, detect would still read generation
    # 1's olddigest, call it digest-changed and bake the image just promoted.
    refute_bake_main_called
    # The gate closes fd 218 on the way out, which also closes the fd bats
    # captures on, so only what it logged before that survives. It is enough
    # to show the real gate ran end to end; the store assertions above carry
    # the rest.
    # shellcheck disable=SC2154  # $stderr is set by bats run --separate-stderr
    [[ "$stderr" == *"generation 2 passed"* ]]
}

@test "the drift stage runs the real drift check against the active generation" {
    drift_main() { real_drift_main "$@"; }
    jq() { /usr/bin/jq "$@"; }

    stub_digest_ok
    # One rule serves both callers: lib/bake.sh's digest input and
    # lib/drift.sh's window check make the identical releases/latest request.
    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0","published_at":"2026-08-15T00:00:00Z"}
EOF
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-09-06T00:00:00Z'; }
    make_active "$digest" GEN_CREATED_AT=2026-09-05T00:00:00Z GEN_RUNNER_VERSION=2.300.0
    MAINTAIN_NOW_HHMM=03:00

    run maintain_main
    [ "$status" -eq 0 ]
    refute_bake_main_called
    [[ "$output" == *"status=warn"* ]]
    [[ "$output" == *"days_remaining=8"* ]]
    notify_log | grep -q 'warn drift.warning'
}
