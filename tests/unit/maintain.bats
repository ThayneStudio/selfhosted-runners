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

bake_main_called() {
    [[ -f "$STUB_DIR/bake_main.log" ]]
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
    ! bake_main_called
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
    ! bake_main_called
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
    ! grep -q -- '--force' "$STUB_DIR/bake_main.log"
    [ ! -f "$STUB_DIR/promote.log" ]
}

@test "REBAKE_ENABLED=false never starts a bake" {
    stub_digest_ok
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z
    MAINTAIN_NOW_HHMM=03:00
    REBAKE_ENABLED=false

    run maintain_main
    [ "$status" -eq 0 ]
    ! bake_main_called
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
    ! bake_main_called
    notify_log | grep -q 'warn canary.unconfigured'
    [[ "$output" == *"unknown-digest"* || "$(notify_log)" == *"canary.unconfigured"* ]]
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
    ! bake_main_called
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
    ! bake_main_called
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

@test "stale promotion pause is cleared when the pool lock is free" {
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")"
    : > "$PROMOTION_PAUSE_FILE"
    run maintain_clear_stale_promotion_pause
    [ "$status" -eq 0 ]
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
    [[ "$output" == *"stale promotion pause"* ]]
}

@test "promotion pause is left when the exclusive pool lock is held" {
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")" "$(dirname "$POOL_ACTIVITY_LOCK_FILE")"
    : > "$PROMOTION_PAUSE_FILE"
    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -n -x 202
    run maintain_clear_stale_promotion_pause
    [ "$status" -eq 0 ]
    [ -e "$PROMOTION_PAUSE_FILE" ]
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
        GEN_ID=5 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=a \
        GEN_IMAGE_SHA256=abc \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z
    gen_create 8901 \
        GEN_ID=9 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=b \
        GEN_IMAGE_SHA256=def \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z

    run maintain_reconcile_two_actives
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    gen_read 8901
    [ "$GEN_STATE" = "superseded" ]
    notify_log | grep -q 'warn'
}
