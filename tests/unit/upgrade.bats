#!/usr/bin/env bats
# Operator-invoked bake-then-promote. Not a timer. Success is the post-state.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib upgrade.sh
    MIN_VMID=9001
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    REBAKE_ENABLED=true
    CANARY_ENABLED=false
    CANARY_REPO=""
    BALLOON="${BALLOON:-0}"
    VLAN_TAG="${VLAN_TAG:-}"
    DNS_SERVERS="${DNS_SERVERS:-}"
    DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-http://mirror.example:8080}"

    INSTALL_DIR="$STUB_DIR/install"
    mkdir -p "$INSTALL_DIR/templates" "$IMG_CACHE_DIR" "$SNIPPETS_DIR" "$BAKE_LOG_DIR"
    printf 'mirror: {{DOCKER_MIRROR_URL}}\n' > "$INSTALL_DIR/templates/template-setup.yaml"

    jq_stub() {
        local json tag=""
        json=$(cat)
        if [[ "$*" == *tag_name* ]]; then
            if [[ "$json" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                tag="${BASH_REMATCH[1]}"
            fi
            printf '%s\n' "$tag"
            return 0
        fi
        printf 'jq stub: unhandled args: %s\n' "$*" >&2
        return 1
    }
    export -f jq_stub

    notify() { printf '%s\n' "$*" >> "$STUB_DIR/notify.log"; }

    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0"}
EOF
    stub_out wget '*' <<'EOF'
abc123  *noble-server-cloudimg-amd64.img
EOF
    stub_out pvesm status <<'EOF'
Name             Type     Status           Total            Used       Available        %
local-zfs        zfspool  active    500000000000      10000000000     209715200   10.00%
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid Format
EOF
    stub_out qm 'config *' <<'EOF'
name: ubuntu-cloud-template
template: 1
EOF
    stub_out qm 'status *' <<'EOF'
status: stopped
template: 1
EOF
}

stub_digest_ok() { :; }

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

@test "lib/upgrade.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/upgrade.sh"
}

@test "runner dispatches the upgrade verb" {
    grep -Eq '^[[:space:]]*upgrade\)' "$REPO_ROOT/runner"
    grep -q 'upgrade' "$REPO_ROOT/runner"
}

@test "upgrade unit is a oneshot with --foreground and no timer install" {
    local unit="$REPO_ROOT/templates/github-runner-upgrade.service"
    grep -q 'Type=oneshot' "$unit"
    grep -q 'ExecStart=/usr/local/bin/runner upgrade --foreground' "$unit"
    grep -q 'TimeoutStartSec=14400' "$unit"
    grep -q 'SyslogIdentifier=github-runner-upgrade' "$unit"
    grep -q 'After=.*pvedaemon.service' "$unit"
    ! grep -q 'WantedBy=' "$unit"
    ! grep -q '^\[Install\]' "$unit"
    [ ! -f "$REPO_ROOT/templates/github-runner-upgrade.timer" ]
}

@test "install.sh copies the upgrade unit, prints the two commands, and does not start it" {
    grep -q 'github-runner-upgrade.service' "$REPO_ROOT/install.sh"
    grep -q 'runner upgrade --dry-run' "$REPO_ROOT/install.sh"
    grep -q 'runner upgrade' "$REPO_ROOT/install.sh"
    ! grep -E 'systemctl (start|enable).*github-runner-upgrade' "$REPO_ROOT/install.sh"
    ! grep -q 'bake_main' "$REPO_ROOT/install.sh"
}

@test "install.sh still adopts without baking" {
    grep -q 'adopt_deployed_template' "$REPO_ROOT/install.sh"
    ! grep -q 'bake_main' "$REPO_ROOT/install.sh"
    ! grep -q 'upgrade_foreground' "$REPO_ROOT/install.sh"
}

@test "setup.sh copies the upgrade unit and does not start it" {
    grep -q 'github-runner-upgrade.service' "$REPO_ROOT/lib/setup.sh"
    ! grep -E 'systemctl (start|enable).*github-runner-upgrade' "$REPO_ROOT/lib/setup.sh"
}

@test "upgrade holds BAKE_LOCK_FILE on fd 210 and calls bake_locked not bake_main" {
    grep -q 'exec 210>' "$REPO_ROOT/lib/upgrade.sh"
    grep -q 'flock -w' "$REPO_ROOT/lib/upgrade.sh"
    grep -q 'bake_locked' "$REPO_ROOT/lib/upgrade.sh"
    ! grep -q 'bake_main' "$REPO_ROOT/lib/upgrade.sh"
}

@test "upgrade wrap starts the unit --no-block and skips wrap under INVOCATION_ID" {
    grep -q 'start --no-block github-runner-upgrade.service' "$REPO_ROOT/lib/upgrade.sh"
    grep -q 'INVOCATION_ID' "$REPO_ROOT/lib/upgrade.sh"
    grep -q -- '--foreground' "$REPO_ROOT/lib/upgrade.sh"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

@test "CANARY_ENABLED=true refuses upgrade" {
    CANARY_ENABLED=true
    run --separate-stderr upgrade_main --foreground
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"CANARY_ENABLED"* ]]
    refute_called qm 'create *'
}

@test "non-template TEMPLATE_ID is a bootstrap, not an upgrade" {
    stub_out qm 'config 9000' <<'EOF'
name: leftover-vm
ostype: l26
EOF
    run --separate-stderr upgrade_main --foreground
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"setup"* ]]
    refute_called qm 'create *'
}

@test "REBAKE_ENABLED=false exits non-zero" {
    REBAKE_ENABLED=false
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    run --separate-stderr upgrade_main --foreground
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"REBAKE_ENABLED"* || "$stderr" == *"rebake-disabled"* ]]
}

@test "memoed digest exits non-zero and names bake --force" {
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=unknown \
        GEN_IMAGE_SHA256=unknown \
        GEN_RUNNER_VERSION=unknown
    memo_failed_digest "$digest"
    run --separate-stderr upgrade_main --foreground
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"memoed"* ]]
    [[ "$stderr" == *"bake --force"* ]]
    refute_called qm 'create *'
}

# ---------------------------------------------------------------------------
# Dry-run
# ---------------------------------------------------------------------------

@test "--dry-run does not adopt, lock, bake, or promote" {
    run --separate-stderr upgrade_main --dry-run
    [ "$status" -eq 0 ]
    [ "$(gen_list)" = "" ]
    refute_called qm 'set * --tags *'
    refute_called qm 'create *'
    refute_called qm 'clone *'
    [[ "$output" == *"unknown-digest"* || "$stderr" == *"unknown-digest"* || "$output" == *"detect="* ]]
    [[ "$output" == *"bake_plan=bake"* ]]
    [[ "$output" == *"promote_plan=after bake"* ]]
}

# ---------------------------------------------------------------------------
# Idempotent success / promote-only
# ---------------------------------------------------------------------------

@test "already-active matching digest exits 0 without baking" {
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    run --separate-stderr upgrade_main --foreground
    [ "$status" -eq 0 ]
    refute_called qm 'create *'
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    [[ "$output" == *"TEMPLATE_ID=9000"* ]]
    [[ "$output" == *"drain_bound_hours="* ]]
}

@test "existing candidate for this digest is promoted without a second bake" {
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=unknown \
        GEN_IMAGE_SHA256=unknown \
        GEN_RUNNER_VERSION=unknown
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    occupy_band_vmid() { :; }

    bake_locked() {
        printf 'called\n' >> "$STUB_DIR/bake_locked.log"
        return 0
    }

    run --separate-stderr upgrade_main --foreground
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/bake_locked.log" ]
    grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
    [[ "$output" == *"previous_vmid=9000"* ]]
}

@test "already-active matching digest with stale pointer is promoted without baking" {
    # Crash after gen_transition active, before rewrite_template_id.
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=old \
        GEN_RUNNER_VERSION=2.335.0
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    bake_locked() {
        printf 'called\n' >> "$STUB_DIR/bake_locked.log"
        return 0
    }

    run --separate-stderr upgrade_main --foreground
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/bake_locked.log" ]
    grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
}

@test "weekly-floor with matching pointer still bakes" {
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    TEMPLATE_ID=8900
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=8900
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    gen_create 8900 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_CREATED_AT=2026-08-15T00:00:00Z
    bake_locked() {
        printf 'called\n' >> "$STUB_DIR/bake_locked.log"
        # New candidate VMID is higher than the matching active so
        # bake_matching_generation would pick 8900 if resolve were swapped.
        gen_create 8901 \
            GEN_ID=2 \
            GEN_STATE=candidate \
            GEN_TEMPLATE_DIGEST="$digest" \
            GEN_IMAGE_SHA256=abc \
            GEN_RUNNER_VERSION=2.336.0
        _BAKE_DIGEST="$digest"
        return 0
    }

    run --separate-stderr upgrade_main --foreground
    [ "$status" -eq 0 ]
    [ -f "$STUB_DIR/bake_locked.log" ]
    grep -q 'TEMPLATE_ID="8901"' "$CONFIG_FILE"
    gen_read 8900
    [ "$GEN_STATE" = "superseded" ]
    gen_read 8901
    [ "$GEN_STATE" = "active" ]
}

@test "without --foreground and without INVOCATION_ID, upgrade starts the unit --no-block" {
    stub_out systemctl 'daemon-reload' < /dev/null
    stub_out systemctl 'start --no-block github-runner-upgrade.service' < /dev/null
    stub_out systemctl 'show *' <<'EOF'
InvocationID=deadbeef
ActiveState=inactive
Result=success
EOF
    unset INVOCATION_ID || true
    upgrade_wait_unit() { return 0; }
    run --separate-stderr upgrade_main
    [ "$status" -eq 0 ]
    assert_called systemctl 'start --no-block github-runner-upgrade.service'
    refute_called qm 'create *'
}

@test "INVOCATION_ID skips the unit wrap even without --foreground" {
    INVOCATION_ID=from-systemd
    CANARY_ENABLED=true
    run --separate-stderr upgrade_main
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"CANARY_ENABLED"* ]]
    refute_called systemctl 'start *'
}

@test "runner upgrade --force writes the force flag the oneshot consumes" {
    stub_out systemctl 'daemon-reload' < /dev/null
    stub_out systemctl 'start --no-block github-runner-upgrade.service' < /dev/null
    stub_out systemctl 'show *' <<'EOF'
InvocationID=deadbeef
ActiveState=inactive
Result=success
EOF
    unset INVOCATION_ID || true
    upgrade_wait_unit() { return 0; }
    run --separate-stderr upgrade_main --force
    [ "$status" -eq 0 ]
    [ -f "$RUNNER_STATE_DIR/upgrade.force" ]
    grep -qx '1' "$RUNNER_STATE_DIR/upgrade.force"
}

@test "--foreground --force calls bake_locked 1" {
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    bake_locked() {
        printf '%s\n' "${1:-}" >> "$STUB_DIR/bake_locked.log"
        return 0
    }
    run --separate-stderr upgrade_main --foreground --force
    [ "$status" -eq 0 ]
    grep -qx '1' "$STUB_DIR/bake_locked.log"
}

@test "upgrade_foreground consumes the force flag without --force on argv" {
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    ensure_state_dir "$RUNNER_STATE_DIR"
    printf '1\n' > "$RUNNER_STATE_DIR/upgrade.force"
    bake_locked() {
        printf '%s\n' "${1:-}" >> "$STUB_DIR/bake_locked.log"
        return 0
    }
    INVOCATION_ID=from-systemd
    run --separate-stderr upgrade_main
    [ "$status" -eq 0 ]
    grep -qx '1' "$STUB_DIR/bake_locked.log"
    [ ! -f "$RUNNER_STATE_DIR/upgrade.force" ]
}

@test "reconcile after promote keeps the on-disk pointer, not in-shell TEMPLATE_ID" {
    gen_store_init
    local digest
    digest=$(compute_template_digest)
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=old \
        GEN_RUNNER_VERSION=2.335.0
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    bake_locked() { return 0; }
    promote_generation() {
        local n=0
        [[ -f "$STUB_DIR/promote_n" ]] && n=$(cat "$STUB_DIR/promote_n")
        n=$((n + 1))
        printf '%s\n' "$n" > "$STUB_DIR/promote_n"
        if [[ "$n" -eq 1 ]]; then
            gen_transition 8900 active
            rewrite_template_id 8900
            return 1
        fi
        return 0
    }
    TEMPLATE_ID=9000
    run --separate-stderr upgrade_main --foreground
    [ "$status" -eq 0 ]
    grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
}

@test "upgrade_wait_unit rejects leftover Result=success without a new InvocationID" {
    stub_out systemctl 'show *' <<'EOF'
InvocationID=oldid
ActiveState=inactive
Result=success
EOF
    stub_out systemctl 'is-active *' <<'EOF'
inactive
EOF
    UPGRADE_WAIT_POLLS=1
    UPGRADE_WAIT_SLEEP=0
    run --separate-stderr upgrade_wait_unit oldid
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"InvocationID"* ]]
}
