#!/usr/bin/env bats
# Rebake detection: digest compare, weekly floor, memo override, API failure.
#
# write_infra_config still defaults MIN_VMID=500, which overlaps the
# generation band, so tests set 9001.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib detect.sh
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    DOCKER_MIRROR_URL="http://mirror.example:8080"
    VLAN_TAG="20"
    DNS_SERVERS="1.1.1.1"
    BALLOON="0"
    INSTALL_DIR="$STUB_DIR/install"
    mkdir -p "$INSTALL_DIR/templates"
    printf 'mirror: {{DOCKER_MIRROR_URL}}\n' > "$INSTALL_DIR/templates/template-setup.yaml"

    # The harness jq is a stub. Parse the tiny GitHub releases JSON the digest
    # path actually sends; stub_out jq is ignored while this function is set.
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

    # Record notify invocations so tests can prove first-fail does not notify
    # and the warn-hours path notifies once.
    notify() {
        printf '%s\n' "$*" >> "$STUB_DIR/notify.log"
    }
}

notify_count() {
    [[ -f "$STUB_DIR/notify.log" ]] || { printf '0\n'; return 0; }
    wc -l < "$STUB_DIR/notify.log" | tr -d ' '
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
        "$@"
}

@test "lib/detect.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/detect.sh"
}

@test "detect_age_days is 10 for a stamp 10 days before gen_now" {
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    run detect_age_days '2026-08-15T00:00:00Z'
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

@test "unchanged digest and fresh generation → no up-to-date" {
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active "$digest" GEN_CREATED_AT=2026-08-24T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "no up-to-date" ]
}

@test "unknown active digest → yes unknown-digest" {
    stub_digest_ok
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active unknown GEN_CREATED_AT=2026-08-24T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "yes unknown-digest" ]
}

@test "changing rendered yaml → yes digest-changed" {
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active "$digest" GEN_CREATED_AT=2026-08-24T00:00:00Z

    printf 'mirror: {{DOCKER_MIRROR_URL}}\nchanged: 1\n' \
        > "$INSTALL_DIR/templates/template-setup.yaml"

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "yes digest-changed" ]
}

@test "age past REBAKE_MAX_AGE_DAYS with same digest → yes weekly-floor" {
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active "$digest" GEN_CREATED_AT=2026-08-15T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "yes weekly-floor" ]
}

@test "memoed digest does not trigger even past the floor" {
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    memo_failed_digest "$digest"
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active "$digest" GEN_CREATED_AT=2026-08-15T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "no memoed-digest" ]
}

@test "REBAKE_ENABLED=false → no rebake-disabled" {
    stub_digest_ok
    REBAKE_ENABLED=false
    make_active unknown

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "no rebake-disabled" ]
}

@test "first GitHub API failure logs and does not notify; floor still applies" {
    stub_status curl '*' 22
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active abcdef GEN_CREATED_AT=2026-08-15T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "yes weekly-floor" ]
    [[ "$stderr" == *"fail"* || "$stderr" == *"digest"* ]]
    [ "$(notify_count)" -eq 0 ]
    [ -f "$DETECT_FAIL_FILE" ]
    grep -q '^first_fail=' "$DETECT_FAIL_FILE"
    ! grep -q '^warned=' "$DETECT_FAIL_FILE"
}

@test "no active generation → yes unknown-digest" {
    stub_digest_ok
    gen_store_init

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "yes unknown-digest" ]
}

@test "successful digest compute clears DETECT_FAIL_FILE" {
    stub_digest_ok
    ensure_state_dir "$(dirname "$DETECT_FAIL_FILE")"
    printf 'first_fail=2026-08-20T00:00:00Z\n' > "$DETECT_FAIL_FILE"
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active "$digest" GEN_CREATED_AT=2026-08-24T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "no up-to-date" ]
    [ ! -f "$DETECT_FAIL_FILE" ]
}

@test "consecutive detect failure past DETECT_FAIL_WARN_HOURS notifies warn once" {
    stub_status curl '*' 22
    gen_now() { printf '%s\n' '2026-08-25T12:00:00Z'; }
    ensure_state_dir "$(dirname "$DETECT_FAIL_FILE")"
    printf 'first_fail=2026-08-24T11:00:00Z\n' > "$DETECT_FAIL_FILE"
    DETECT_FAIL_WARN_HOURS=24

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$(notify_count)" -eq 1 ]
    grep -q 'warn' "$STUB_DIR/notify.log"
    grep -q '^warned=' "$DETECT_FAIL_FILE"
    grep -q '^first_fail=2026-08-24T11:00:00Z$' "$DETECT_FAIL_FILE"

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$(notify_count)" -eq 1 ]
}

@test "API failure on a fresh generation is not digest-changed" {
    stub_status curl '*' 22
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    make_active abcdef GEN_CREATED_AT=2026-08-24T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "no up-to-date" ]
    [[ "$output" != *"digest-changed"* ]]
    [ "$(notify_count)" -eq 0 ]
    [ -f "$DETECT_FAIL_FILE" ]
}

@test "two actives: detect uses TEMPLATE_ID not the lowest active VMID" {
    # Promote-before-demote crash: 8900 (matching digest) and 9000 (unknown).
    # The fleet clones TEMPLATE_ID=9000, so this must be unknown-digest, not
    # up-to-date from gen_list active | head (lowest VMID 8900).
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 8900 \
        GEN_ID=99 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_CREATED_AT=2026-08-24T00:00:00Z
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=unknown \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_CREATED_AT=2026-08-24T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "yes unknown-digest" ]
}

@test "TEMPLATE_ID with no record is unknown-digest even if another generation is active" {
    stub_digest_ok
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    gen_store_init
    TEMPLATE_ID=9000
    gen_create 8900 \
        GEN_ID=99 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_CREATED_AT=2026-08-24T00:00:00Z

    run --separate-stderr detect_should_bake
    [ "$status" -eq 0 ]
    [ "$output" = "yes unknown-digest" ]
}
