#!/usr/bin/env bats
# Non-interactive runner bake: lock, space, create, poll, candidate.
#
# write_infra_config still defaults MIN_VMID=500, which overlaps the
# generation band, so tests set 9001. Destructive qm/pvesm verbs need
# explicit stub rules (or a qm_stub that implements them).

load test_helper

setup() {
    load_lib bake.sh
    MIN_VMID=9001
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    BALLOON="${BALLOON:-0}"
    VLAN_TAG="${VLAN_TAG:-}"
    DNS_SERVERS="${DNS_SERVERS:-}"
    DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-http://mirror.example:8080}"
    BAKE_INTERVAL=0
    BAKE_TIMEOUT=30
    MIN_CLOUD_IMG_BYTES=64

    INSTALL_DIR="$STUB_DIR/install"
    mkdir -p "$INSTALL_DIR/templates" "$IMG_CACHE_DIR" "$SNIPPETS_DIR" "$BAKE_LOG_DIR"
    printf 'mirror: {{DOCKER_MIRROR_URL}}\n' > "$INSTALL_DIR/templates/template-setup.yaml"

    jq_stub() {
        local json=""
        json=$(cat)
        case "$*" in
            *tag_name*)
                local tag=""
                if [[ "$json" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                    tag="${BASH_REMATCH[1]}"
                fi
                printf '%s\n' "$tag"
                ;;
            *exitcode*)
                if [[ "$json" =~ \"exitcode\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                    printf '%s\n' "${BASH_REMATCH[1]}"
                else
                    printf '1\n'
                fi
                ;;
            *out-data*)
                if [[ "$json" =~ \"out-data\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                    printf '%s\n' "${BASH_REMATCH[1]//\\n/}"
                fi
                ;;
            *)
                printf 'jq stub: unhandled args: %s\n' "$*" >&2
                return 1
                ;;
        esac
        return 0
    }
    export -f jq_stub

    stub_out curl '*' <<'EOF'
{"tag_name":"v2.336.0"}
EOF

    make_cached_image
    stub_sums_for_cache
    stub_pvesm_space 200000000000

    qm_stub() {
        bake_qm_stub "$@"
    }
    export -f bake_qm_stub
    export -f qm_stub
    export STUB_DIR VM_STORAGE TEMPLATE_ID
}

make_cached_image() {
    local path="$CLOUD_IMG_PATH" size=$((MIN_CLOUD_IMG_BYTES + 32))
    mkdir -p "$(dirname "$path")"
    # Sparse file then qcow2 magic at offset 0 (same order as setup-cloud-image.bats).
    dd if=/dev/zero of="$path" bs=1 count=0 seek="$size" 2>/dev/null
    printf 'QFI\xfb\x00\x00\x00\x03cached' | dd of="$path" bs=1 seek=0 conv=notrunc 2>/dev/null
}

stub_sums_for_cache() {
    local hash
    hash=$(sha256sum "$CLOUD_IMG_PATH" | awk '{print $1}')
    stub_out wget '*' <<EOF
${hash}  *${CLOUD_IMG}
EOF
}

stub_pvesm_space() {
    local avail="$1"
    stub_out pvesm status <<EOF
Name             Type     Status           Total            Used       Available        %
${VM_STORAGE}        zfspool  active    500000000000      10000000000     ${avail}   10.00%
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid Format
EOF
}

# Default hypervisor fake: template VMID is absent (adopt no-ops), new VMIDs
# become running on start and stopped on shutdown. Marker is present.
bake_qm_stub() {
    local cmd="$1"
    shift || true
    case "$cmd" in
        create)
            local vmid="$1"
            mkdir -p "$STUB_DIR"
            : > "$STUB_DIR/qm-created-$vmid"
            return 0
            ;;
        importdisk)
            local vmid="$1"
            printf "Successfully imported disk as 'unused0:%s:vm-%s-disk-0'\n" "$VM_STORAGE" "$vmid"
            return 0
            ;;
        set|resize)
            return 0
            ;;
        start)
            local vmid="$1"
            if [[ -f "$STUB_DIR/qm-start-fail" ]]; then
                return 1
            fi
            : > "$STUB_DIR/qm-running-$vmid"
            return 0
            ;;
        status)
            local vmid="$1"
            if [[ "$vmid" == "$TEMPLATE_ID" && ! -f "$STUB_DIR/template-present" ]]; then
                return 2
            fi
            if [[ -f "$STUB_DIR/qm-running-$vmid" ]]; then
                echo "status: running"
                return 0
            fi
            if [[ -f "$STUB_DIR/qm-created-$vmid" ]]; then
                echo "status: stopped"
                return 0
            fi
            return 2
            ;;
        guest)
            # guest exec <vmid> -- <argv...>
            local sub="$1" vmid
            shift || true
            [[ "$sub" == exec ]] || return 1
            vmid="$1"
            shift || true
            [[ "${1:-}" == -- ]] && shift
            if [[ -f "$STUB_DIR/qm-marker-absent" ]] && [[ "$*" == *template-setup-complete* ]]; then
                echo '{"exitcode":1,"exited":1}'
                return 0
            fi
            if [[ "${1:-}" == test && "$*" == *template-setup-complete* ]]; then
                echo '{"exitcode":0,"exited":1}'
                return 0
            fi
            if [[ "${1:-}" == cat && "$*" == *runner-version* ]]; then
                echo '{"exitcode":0,"exited":1,"out-data":"2.336.0\n"}'
                return 0
            fi
            if [[ "${1:-}" == tail ]]; then
                echo '{"exitcode":0,"exited":1,"out-data":"guest setup still running\n"}'
                return 0
            fi
            if [[ -f "$STUB_DIR/qm-stamp-write-fail" ]] && [[ "$*" == *github-runner/generation* ]]; then
                # Agent call succeeds; guest command fails. qm's process status is 0.
                echo '{"exitcode":1,"exited":1}'
                return 0
            fi
            echo '{"exitcode":0,"exited":1}'
            return 0
            ;;
        shutdown)
            local vmid="$1"
            rm -f "$STUB_DIR/qm-running-$vmid"
            : > "$STUB_DIR/qm-created-$vmid"
            return 0
            ;;
        stop)
            local vmid="$1"
            rm -f "$STUB_DIR/qm-running-$vmid"
            : > "$STUB_DIR/qm-created-$vmid"
            return 0
            ;;
        template)
            return 0
            ;;
        list)
            echo "      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
            return 0
            ;;
        destroy)
            local vmid="$1"
            # Proxmox refuses to delete a running VM. bake_fail must stop first.
            if [[ -f "$STUB_DIR/qm-running-$vmid" ]]; then
                printf "VM %s is running - not destroying\n" "$vmid" >&2
                return 1
            fi
            rm -f "$STUB_DIR/qm-created-$vmid" "$STUB_DIR/qm-running-$vmid"
            return 0
            ;;
        *)
            printf 'qm_stub: unhandled: %s %s\n' "$cmd" "$*" >&2
            return 97
            ;;
    esac
}

@test "lib/bake.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/bake.sh"
}

@test "runner dispatches the bake verb" {
    grep -Eq '^[[:space:]]*bake\)' "$REPO_ROOT/runner"
}

@test "runner bake --force on a matching digest still bakes" {
    local digest
    digest=$(compute_template_digest)
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0

    run bake_main --force
    [ "$status" -eq 0 ]
    assert_called qm 'create 8900 *'
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    [ "$GEN_TEMPLATE_DIGEST" = "$digest" ]
}

@test "second concurrent bake exits 0 without qm create" {
    mkdir -p "$(dirname "$BAKE_LOCK_FILE")"
    exec 207>"$BAKE_LOCK_FILE"
    flock -n 207

    run bake_main --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"already"* ]]
    refute_called qm 'create *'
}

@test "insufficient free space fails before qm create" {
    stub_pvesm_space 1000
    run bake_main --force
    [ "$status" -eq 1 ]
    refute_called qm 'create *'
}

@test "failed bake does not qm destroy the active TEMPLATE_ID" {
    : > "$STUB_DIR/qm-start-fail"
    run bake_main --force
    [ "$status" -ne 0 ]
    assert_called qm 'destroy 8900*'
    refute_called qm "destroy ${TEMPLATE_ID}*"
}

@test "successful bake leaves GEN_STATE=candidate and does not rewrite TEMPLATE_ID" {
    run bake_main --force
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    [ "$GEN_VMID" = "8900" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    assert_called qm 'create 8900 --name github-runner-gen-*'
    refute_called qm 'create *ubuntu-cloud-template*'
}

@test "publish gate refuses qm template when the completion marker is absent" {
    : > "$STUB_DIR/qm-marker-absent"
    BAKE_TIMEOUT=0
    run bake_main --force
    [ "$status" -ne 0 ]
    assert_called qm 'create *'
    refute_called qm 'template *'
}

@test "failed bake after start stops then destroys the new VMID, never TEMPLATE_ID" {
    : > "$STUB_DIR/qm-marker-absent"
    BAKE_TIMEOUT=0
    run bake_main --force
    [ "$status" -ne 0 ]
    assert_called qm 'start 8900'
    assert_called qm 'stop 8900*'
    assert_called qm 'destroy 8900*'
    local calls stop_at destroy_at
    calls=$(stub_calls qm)
    stop_at=$(printf '%s\n' "$calls" | grep -n '^stop 8900' | head -1 | cut -d: -f1)
    destroy_at=$(printf '%s\n' "$calls" | grep -n '^destroy 8900' | head -1 | cut -d: -f1)
    [ -n "$stop_at" ]
    [ -n "$destroy_at" ]
    [ "$stop_at" -lt "$destroy_at" ]
    [ ! -f "$STUB_DIR/qm-running-8900" ]
    [ ! -f "$STUB_DIR/qm-created-8900" ]
    refute_called qm "destroy ${TEMPLATE_ID}*"
    refute_called qm "stop ${TEMPLATE_ID}*"
}

@test "stamp write with non-zero guest exitcode fails the bake" {
    : > "$STUB_DIR/qm-stamp-write-fail"
    run bake_main --force
    [ "$status" -ne 0 ]
    refute_called qm 'template *'
    refute_called qm 'shutdown *'
    assert_called qm 'start 8900'
}

@test "matching digest without --force exits 0 and does not create" {
    local digest
    digest=$(compute_template_digest)
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0

    run bake_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* || "$output" == *"digest"* ]]
    refute_called qm 'create *'
}

@test "memoed digest without --force exits 0 and does not create" {
    local digest
    digest=$(compute_template_digest)
    memo_failed_digest "$digest"
    run bake_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"memo"* || "$output" == *"nothing to do"* ]]
    refute_called qm 'create *'
}

@test "--dry-run prints plan and does not lock or create" {
    run bake_main --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"8900"* ]]
    [[ "$output" == *"digest"* || "$output" == *"sha"* || "$output" =~ [a-f0-9]{64} ]]
    refute_called qm 'create *'

    # Holding the bake lock must not change dry-run: it never takes the lock.
    exec 207>"$BAKE_LOCK_FILE"
    flock -n 207
    run bake_main --dry-run
    [ "$status" -eq 0 ]
    refute_called qm 'create *'
}

@test "successful bake fails other candidates and destroys them" {
    gen_store_init
    gen_create 8901 \
        GEN_ID=1 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.0.0
    : > "$STUB_DIR/qm-created-8901"

    run bake_main --force
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    gen_read 8901
    [ "$GEN_STATE" = "failed" ]
    [[ "$GEN_FAILED_REASON" == *"superseded by newer candidate"* ]]
    assert_called qm 'destroy 8901*'
    refute_called qm "destroy ${TEMPLATE_ID}*"
}
