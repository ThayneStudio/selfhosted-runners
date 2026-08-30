#!/usr/bin/env bats
# Thin rollback: point TEMPLATE_ID at the retained previous generation,
# reject the generation being rolled away from. Spec 7.3 / 15 / issue #19.
#
# write_infra_config still defaults MIN_VMID=500, which overlaps the
# generation band, so tests set 9001.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib rollback.sh
    MIN_VMID=9001
    TEMPLATE_ID=9000
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    notify() {
        printf '%s\n' "$*" >> "$STUB_DIR/notify.log"
    }
    stub_out qm 'config *' <<'EOF'
template: 1
EOF
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"
}

# Active gen 2 at 8900, retained previous gen 1 at 9000 (superseded).
seed_active_and_previous() {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z \
        GEN_SUPERSEDED_AT=2026-08-20T00:00:00Z
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=newdigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z
    TEMPLATE_ID=8900
    write_infra_config
    TEMPLATE_ID=8900
}

@test "lib/rollback.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/rollback.sh"
}

@test "runner dispatches the rollback verb" {
    grep -Eq '^[[:space:]]*rollback\)' "$REPO_ROOT/runner"
}

@test "runner help mentions rollback" {
    grep -q 'rollback' "$REPO_ROOT/runner"
}

@test "rollback without --yes on a non-tty fails" {
    seed_active_and_previous

    run --separate-stderr rollback_generation </dev/null
    [ "$status" -ne 0 ]

    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
    grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
}

@test "rollback without --yes refuses a piped y on a non-tty" {
    seed_active_and_previous

    run --separate-stderr rollback_generation <<<'y'
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
}

@test "rollback --yes with nothing retained refuses" {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-01T00:00:00Z

    run --separate-stderr rollback_generation --yes
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"retained"* || "$output" == *"retained"* ]]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
}

@test "rollback --yes refuses when the only other generation is rejected" {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-25T00:00:00Z
    gen_create 8900 \
        GEN_ID=99 \
        GEN_STATE=rejected \
        GEN_TEMPLATE_DIGEST=baddigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z \
        GEN_FAILED_REASON='already rolled away from'

    run --separate-stderr rollback_generation --yes
    [ "$status" -ne 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "rejected" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    refute_called qm 'destroy *'
}

@test "rollback --yes restores the previous generation and rejects the current with a reason" {
    seed_active_and_previous

    run --separate-stderr rollback_generation --yes --reason 'jobs failing on 2.336.0'
    [ "$status" -eq 0 ]

    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    [ -n "$GEN_PROMOTED_AT" ]
    gen_read 8900
    [ "$GEN_STATE" = "rejected" ]
    [ "$GEN_FAILED_REASON" = "jobs failing on 2.336.0" ]
    [ -n "$GEN_SUPERSEDED_AT" ]
    [ ! -e "$PROMOTION_PAUSE_FILE" ]

    grep -q 'generation.rolled_back' "$STUB_DIR/notify.log"
    refute_called qm 'destroy *'
}

@test "rollback does not leave TEMPLATE_ID pointing at the rejected generation" {
    seed_active_and_previous
    printf 'DOCKER_MIRROR_URL="http://mirror.example:8080"\n' >> "$CONFIG_FILE"

    run --separate-stderr rollback_generation --yes --reason 'bad image'
    [ "$status" -eq 0 ]

    grep -qE '^TEMPLATE_ID=["'\'']?9000["'\'']?$' "$CONFIG_FILE"
    ! grep -qE '^TEMPLATE_ID=["'\'']?8900["'\'']?$' "$CONFIG_FILE"
    grep -q 'DOCKER_MIRROR_URL="http://mirror.example:8080"' "$CONFIG_FILE"
    [ "$(file_mode "$CONFIG_FILE")" = "600" ]

    run --separate-stderr reload_active_template_id
    [ "$status" -eq 0 ]
    [ "$output" = "9000" ]
}

@test "rollback --yes without --reason still records a reason" {
    seed_active_and_previous

    run --separate-stderr rollback_generation --yes
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "rejected" ]
    [ -n "$GEN_FAILED_REASON" ]
}

@test "rollback lock timeout notifies warn and does not rewrite TEMPLATE_ID" {
    seed_active_and_previous
    ROLLBACK_LOCK_WAIT_SECONDS=0
    mkdir -p "$(dirname "$POOL_ACTIVITY_LOCK_FILE")"
    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -n -x 202

    run --separate-stderr rollback_generation --yes --reason 'timeout test'
    [ "$status" -ne 0 ]
    grep -q 'warn rollback.timeout' "$STUB_DIR/notify.log"
    grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
}

@test "rollback lock wait defaults to 120 seconds" {
    grep -q 'ROLLBACK_LOCK_WAIT_SECONDS:-120' "$REPO_ROOT/lib/rollback.sh"
}

@test "rollback lock-timeout notify runs after pause is released" {
    awk '
        /Timed out waiting for the pool activity lock/ { t = NR }
        t && /_rollback_release/ && !r { r = NR }
        t && /notify warn rollback.timeout/ { n = NR }
        END {
            if (!t || !r || !n) exit 1
            if (!(r < n)) exit 1
        }
    ' "$REPO_ROOT/lib/rollback.sh"
}

@test "rollback_generation traps EXIT to clear PROMOTION_PAUSE_FILE before flock waits" {
    awk '
        /exec 211>"\$PROMOTION_PAUSE_FILE"/ { pause = NR }
        /trap '\''_rollback_release'\'' EXIT[[:space:]]*$/ { trapline = NR }
        /flock -w .* -x 202/ { flock = NR }
        END {
            if (!pause || !trapline || !flock) exit 1
            if (!(pause < trapline && trapline < flock)) exit 1
        }
    ' "$REPO_ROOT/lib/rollback.sh"
}

@test "_rollback_release clears the EXIT trap" {
    grep -A8 '^_rollback_release()' "$REPO_ROOT/lib/rollback.sh" \
        | grep -qE "^[[:space:]]*trap - EXIT[[:space:]]*$"
}

@test "rollback refuses a target that is not a Proxmox template" {
    seed_active_and_previous
    stub_out qm 'config *' <<'EOF'
name: leftover-bake
ostype: l26
EOF

    run --separate-stderr rollback_generation --yes --reason 'not a template'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a template"* ]]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'generation.rolled_back' "$STUB_DIR/notify.log"
    refute_called qm 'destroy *'
}

@test "rollback never destroys TEMPLATE_ID or 9000" {
    seed_active_and_previous
    stub_status qm 'destroy *' 0

    run --separate-stderr rollback_generation --yes --reason 'never destroy'
    [ "$status" -eq 0 ]
    refute_called qm 'destroy *'
    refute_called qm 'destroy 9000'
    refute_called qm 'destroy 8900'
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
}

@test "rollback target is newest SUPERSEDED_AT, never the highest GEN_ID" {
    gen_store_init
    # Orphaned higher-id candidate, superseded earlier than the real previous.
    gen_create 8901 \
        GEN_ID=9 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=orphan \
        GEN_IMAGE_SHA256=aaa \
        GEN_RUNNER_VERSION=2.334.0 \
        GEN_PROMOTED_AT=2026-07-01T00:00:00Z \
        GEN_SUPERSEDED_AT=2026-08-01T00:00:00Z
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-10T00:00:00Z \
        GEN_SUPERSEDED_AT=2026-08-20T00:00:00Z
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=newdigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z
    TEMPLATE_ID=8900
    write_infra_config
    TEMPLATE_ID=8900

    run --separate-stderr rollback_generation --yes --reason 'pick previous not highest id'
    [ "$status" -eq 0 ]

    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "rejected" ]
    gen_read 8901
    [ "$GEN_STATE" = "superseded" ]
    grep -qE '^TEMPLATE_ID=["'\'']?9000["'\'']?$' "$CONFIG_FILE"
}

@test "rollback refuses two active generations rather than guessing" {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-25T00:00:00Z
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=newdigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z
    TEMPLATE_ID=9000
    write_infra_config

    run --separate-stderr rollback_generation --yes --reason 'split brain'
    [ "$status" -ne 0 ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
}

@test "incomplete rollback leftover with higher GEN_ID is rejected, not re-activated" {
    # Reconcile after a crash between rewrite and reject left the escaped
    # generation superseded. Highest GEN_ID is the wrong rollback target.
    gen_store_init
    gen_create 8899 \
        GEN_ID=1 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=older \
        GEN_IMAGE_SHA256=aaa \
        GEN_RUNNER_VERSION=2.334.0 \
        GEN_PROMOTED_AT=2026-07-01T00:00:00Z \
        GEN_SUPERSEDED_AT=2026-08-01T00:00:00Z
    gen_create 9000 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=good \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0 \
        GEN_PROMOTED_AT=2026-08-25T00:00:00Z
    gen_create 8900 \
        GEN_ID=99 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=bad \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_PROMOTED_AT=2026-08-20T00:00:00Z \
        GEN_SUPERSEDED_AT=2026-08-25T00:00:00Z
    TEMPLATE_ID=9000
    write_infra_config
    TEMPLATE_ID=9000

    run --separate-stderr rollback_generation --yes --reason 'complete the reject'
    [ "$status" -eq 0 ]

    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "rejected" ]
    [ "$GEN_FAILED_REASON" = "complete the reject" ]
    gen_read 8899
    [ "$GEN_STATE" = "superseded" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    grep -q 'generation.rolled_back' "$STUB_DIR/notify.log"
}

@test "rollback fails closed when gen_list superseded cannot be read" {
    seed_active_and_previous
    printf 'garbage\n' >> "$GENERATIONS_DIR/9000.conf"

    run --separate-stderr rollback_generation --yes --reason 'unreadable'
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
}
