#!/usr/bin/env bats
# Template digest and failed-digest memo (lib/bake.sh).
#
# write_infra_config still defaults MIN_VMID=500, which overlaps the
# generation band, so tests set 9001.

load test_helper

setup() {
    load_lib bake.sh
    write_infra_config
    MIN_VMID=9001
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
}

@test "compute_template_digest changes when DOCKER_MIRROR_URL changes" {
    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0"}
EOF
    stub_out wget '*' <<'EOF'
abc123  *noble-server-cloudimg-amd64.img
EOF
    d1=$(compute_template_digest)
    DOCKER_MIRROR_URL="http://other"
    d2=$(compute_template_digest)
    [ -n "$d1" ]
    [ "$d1" != "$d2" ]
}

@test "compute_template_digest is stable for the same inputs" {
    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0"}
EOF
    stub_out wget '*' <<'EOF'
abc123  *noble-server-cloudimg-amd64.img
EOF
    d1=$(compute_template_digest)
    d2=$(compute_template_digest)
    [ "$d1" = "$d2" ]
}

@test "memoed digest is detected and is unique on append" {
    memo_failed_digest abc
    memo_failed_digest abc
    digest_is_memoed abc
    [ "$?" -eq 0 ]
    n=$(grep -c '^abc$' "$FAILED_DIGESTS_FILE")
    [ "$n" -eq 1 ]
}

@test "unknown is never equal to a computed digest" {
    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0"}
EOF
    stub_out wget '*' <<'EOF'
abc123  *noble-server-cloudimg-amd64.img
EOF
    d=$(compute_template_digest)
    [ "$d" != "unknown" ]
}

@test "fetch_latest_runner_version strips the v prefix" {
    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0"}
EOF
    run fetch_latest_runner_version
    [ "$status" -eq 0 ]
    [ "$output" = "2.336.0" ]
}

@test "fetch_latest_runner_version fails closed on curl failure" {
    stub_status curl '*' 22
    run fetch_latest_runner_version
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "fetch_latest_runner_version fails closed on empty tag" {
    stub_out curl '*' <<'EOF'
{"tag_name":""}
EOF
    run fetch_latest_runner_version
    [ "$status" -eq 1 ]
}

@test "fetch_latest_runner_version fails closed on null tag" {
    stub_out curl '*' <<'EOF'
{"tag_name":null}
EOF
    run fetch_latest_runner_version
    [ "$status" -eq 1 ]
}

@test "fetch_image_checksum_entry fails closed when wget fails" {
    stub_status wget '*' 4
    run fetch_image_checksum_entry
    [ "$status" -eq 1 ]
    [[ "$output" == *"SHA256SUMS"* || "$output" == *"cannot verify"* || "$output" == *"Could not fetch"* ]]
}

@test "fetch_image_checksum_entry fails closed when the image has no SUMS line" {
    stub_out wget '*' <<'EOF'
0000000000000000000000000000000000000000000000000000000000000000 *noble-server-cloudimg-arm64.img
EOF
    run fetch_image_checksum_entry
    [ "$status" -eq 1 ]
    [[ "$output" == *"No entry for $CLOUD_IMG"* ]]
}

@test "memo_failed_digest creates the file at mode 600 via ensure_state_dir" {
    memo_failed_digest abcdef
    [ -f "$FAILED_DIGESTS_FILE" ]
    local mode
    mode=$(stat -c '%a' "$FAILED_DIGESTS_FILE" 2>/dev/null || stat -f '%OLp' "$FAILED_DIGESTS_FILE")
    [ "$mode" = "600" ]
    [ -d "$RUNNER_STATE_DIR" ]
}

@test "unmemo_failed_digest is success when the file is missing" {
    [ ! -f "$FAILED_DIGESTS_FILE" ]
    unmemo_failed_digest abc
}

@test "unmemo_failed_digest removes only that digest and keeps mode 600" {
    memo_failed_digest abc
    memo_failed_digest def
    unmemo_failed_digest abc
    run digest_is_memoed abc
    [ "$status" -eq 1 ]
    digest_is_memoed def
    local mode
    mode=$(stat -c '%a' "$FAILED_DIGESTS_FILE" 2>/dev/null || stat -f '%OLp' "$FAILED_DIGESTS_FILE")
    [ "$mode" = "600" ]
}

@test "render_template_setup substitutes DOCKER_MIRROR_URL" {
    run render_template_setup
    [ "$status" -eq 0 ]
    [ "$output" = "mirror: http://mirror.example:8080" ]
}

@test "compute_template_digest fails closed when the SUMS fetch fails" {
    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0"}
EOF
    stub_status wget '*' 4
    run compute_template_digest
    [ "$status" -eq 1 ]
    [ "$output" != "unknown" ]
}
