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
    cat > "$INSTALL_DIR/templates/template-setup.yaml" <<'EOF'
mirror: {{DOCKER_MIRROR_URL}}
      RUNNER_VERSION=$(curl -sf --retry 3 https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/v//')
EOF

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
    # pvesm status Avail is KiB. 200 GiB = 200 * 1024 * 1024 KiB.
    stub_pvesm_space $((200 * 1024 * 1024))

    qm_stub() {
        bake_qm_stub "$@"
    }
    export -f bake_qm_stub
    export -f qm_stub
    export STUB_DIR VM_STORAGE TEMPLATE_ID GENERATIONS_DIR

    notify() {
        printf 'NOTIFY_GENERATION=%s %s\n' "${NOTIFY_GENERATION:-}" "$*" >> "$STUB_DIR/notify.log"
    }
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
            if [[ -f "$STUB_DIR/qm-create-fail" ]]; then
                return 1
            fi
            : > "$STUB_DIR/qm-created-$vmid"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)
                        printf '%s' "$2" > "$STUB_DIR/qm-name-$vmid"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            return 0
            ;;
        config)
            local vmid="$1" gid
            if [[ -f "$STUB_DIR/qm-foreign-$vmid" ]]; then
                echo "name: foreign-vm"
                return 0
            fi
            if [[ -f "$STUB_DIR/qm-name-$vmid" ]]; then
                echo "name: $(cat "$STUB_DIR/qm-name-$vmid")"
                return 0
            fi
            if [[ -f "$GENERATIONS_DIR/${vmid}.conf" ]]; then
                gid=$(awk -F= '/^GEN_ID=/{gsub(/"/, "", $2); print $2; exit}' "$GENERATIONS_DIR/${vmid}.conf")
                if [[ -n "$gid" ]]; then
                    echo "name: github-runner-gen-${gid}"
                    return 0
                fi
            fi
            return 2
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
            if [[ -f "$STUB_DIR/qm-foreign-$vmid" ]]; then
                echo "status: stopped"
                return 0
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
                # Marker-shaped tests drop running after the exitcode-1 probe so
                # the loop cannot fall through to the timeout branch.
                if [[ -f "$STUB_DIR/qm-marker-absent-stop" ]]; then
                    rm -f "$STUB_DIR/qm-running-$vmid"
                fi
                return 0
            fi
            if [[ -f "$STUB_DIR/qm-stamp-read-fail" ]] && [[ "$*" == *runner-version* ]]; then
                # Agent call succeeds; guest cat fails. out-data must not count.
                echo '{"exitcode":1,"exited":1,"out-data":"2.336.0\n"}'
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
    # 10 GiB in KiB is below BAKE_MIN_FREE_GB=60.
    stub_pvesm_space $((10 * 1024 * 1024))
    run bake_main --force
    [ "$status" -eq 1 ]
    refute_called qm 'create *'
    grep -q 'warn bake.failed' "$STUB_DIR/notify.log"
}

@test "storage_avail_gb treats pvesm Avail as KiB" {
    stub_pvesm_space $((200 * 1024 * 1024))
    run storage_avail_gb
    [ "$status" -eq 0 ]
    [ "$output" -eq 200 ]
    [ "$output" -ge "$BAKE_MIN_FREE_GB" ]

    stub_pvesm_space $((10 * 1024 * 1024))
    run storage_avail_gb
    [ "$status" -eq 0 ]
    [ "$output" -eq 10 ]
    [ "$output" -lt "$BAKE_MIN_FREE_GB" ]
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
    : > "$STUB_DIR/qm-marker-absent-stop"
    run bake_main --force
    [ "$status" -ne 0 ]
    assert_called qm 'create *'
    assert_called qm 'guest exec * test -f /opt/.template-setup-complete'
    refute_called qm 'template *'
    [[ "$output" == *"stopped before setup"* || "$output" == *"completion"* || "$output" == *"marker"* ]]
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

@test "stamp read with non-zero guest exitcode fails the bake even when out-data is set" {
    : > "$STUB_DIR/qm-stamp-read-fail"
    run bake_main --force
    [ "$status" -ne 0 ]
    refute_called qm 'template *'
    refute_called qm 'shutdown *'
    assert_called qm 'start 8900'
}

@test "matching digest past weekly floor without --force still bakes" {
    local digest
    digest=$(compute_template_digest)
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST="$digest" \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_CREATED_AT=2026-08-15T00:00:00Z

    run bake_main
    [ "$status" -eq 0 ]
    assert_called qm 'create 8900 *'
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
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

@test "successful --force bake un-memos a previously failed digest" {
    local digest
    digest=$(compute_template_digest)
    memo_failed_digest "$digest"
    digest_is_memoed "$digest"

    run bake_main --force
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]

    run digest_is_memoed "$digest"
    [ "$status" -eq 1 ]
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

@test "successful candidate transition disarms EXIT INT TERM before leftover-candidate destroy" {
    # INT/TERM staying armed through bake_fail_other_candidates lets a signal
    # during ruling-6 leftover destroy run bake_fail against the new candidate.
    awk '
        /^bake_locked\(\)/ { in_locked = 1 }
        in_locked && /gen_transition "\$vmid" candidate/ { trans = NR }
        in_locked && /trap - EXIT INT TERM/ { disarm = NR }
        in_locked && /bake_fail_other_candidates/ { leftover = NR }
        END {
            if (!trans || !disarm || !leftover) exit 1
            if (!(trans < disarm && disarm < leftover)) exit 1
        }
    ' "$REPO_ROOT/lib/bake.sh"
}

@test "leftover 8901 becomes on-disk pointer / active after gen_list snapshot → no qm destroy 8901" {
    gen_store_init
    gen_create 8901 \
        GEN_ID=1 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.0.0
    rewrite_template_id 8901
    gen_transition 8901 active
    : > "$STUB_DIR/qm-created-8901"

    gen_list() {
        if [[ "${1:-}" == "candidate" ]]; then
            printf '8901\n'
            return 0
        fi
        printf '8901\n'
    }

    run bake_fail_other_candidates 8900
    [ "$status" -eq 0 ]
    refute_called qm 'destroy 8901*'
    refute_called qm 'stop 8901*'
    refute_called pvesm 'free *'
    gen_read 8901
    [ "$GEN_STATE" = "active" ]
}

@test "foreign name occupying _BAKE_VMID when qm create fails → no destroy of that VMID" {
    : > "$STUB_DIR/qm-create-fail"
    : > "$STUB_DIR/qm-foreign-8900"

    run bake_main --force
    [ "$status" -ne 0 ]
    refute_called qm 'destroy 8900*'
    refute_called qm 'stop 8900*'
    refute_called pvesm 'free *'
    gen_read 8900
    [ "$GEN_STATE" = "failed" ]
}

@test "digest compute and download use the same stubbed SUMS and the guest snippet is pinned" {
    cat > "$INSTALL_DIR/templates/template-setup.yaml" <<'EOF'
mirror: {{DOCKER_MIRROR_URL}}
      RUNNER_VERSION=$(curl -sf --retry 3 https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/v//')
      RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
EOF

    run bake_main --force
    [ "$status" -eq 0 ]
    [ "$(call_count wget '*')" -eq 1 ]
    local snippet="$SNIPPETS_DIR/template-setup-8900.yaml"
    [ -f "$snippet" ]
    grep -q 'RUNNER_VERSION=2.336.0' "$snippet"
    ! grep -q 'releases/latest' "$snippet"
    grep -q 'releases/download' "$snippet"
    grep -q 'releases/latest' "$INSTALL_DIR/templates/template-setup.yaml"
    grep -q 'releases/latest' "$REPO_ROOT/templates/template-setup.yaml"
}

@test "bake_pin_snippet_runner_version fails closed when releases/latest is absent" {
    _BAKE_PINNED_RUNNER_VERSION=2.336.0
    printf 'RUNNER_VERSION=$(echo leftover)\n' > "$STUB_DIR/snip.yaml"
    run bake_pin_snippet_runner_version "$STUB_DIR/snip.yaml"
    [ "$status" -eq 1 ]
    grep -q 'RUNNER_VERSION=$(echo leftover)' "$STUB_DIR/snip.yaml"
}

@test "bake_pin_snippet_runner_version fails closed when the pin is empty" {
    _BAKE_PINNED_RUNNER_VERSION=""
    printf '      RUNNER_VERSION=$(curl -sf https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)\n' \
        > "$STUB_DIR/snip.yaml"
    run bake_pin_snippet_runner_version "$STUB_DIR/snip.yaml"
    [ "$status" -eq 1 ]
    grep -q 'releases/latest' "$STUB_DIR/snip.yaml"
}

@test "leftover 8901 becomes on-disk pointer while still candidate → no qm destroy 8901" {
    gen_store_init
    gen_create 8901 \
        GEN_ID=1 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.0.0
    rewrite_template_id 8901
    : > "$STUB_DIR/qm-created-8901"

    gen_list() {
        if [[ "${1:-}" == "candidate" ]]; then
            printf '8901\n'
            return 0
        fi
        printf '8901\n'
    }

    run bake_fail_other_candidates 8900
    [ "$status" -eq 0 ]
    refute_called qm 'destroy 8901*'
    refute_called qm 'stop 8901*'
    refute_called pvesm 'free *'
    gen_read 8901
    [ "$GEN_STATE" = "candidate" ]
}

@test "leftover destroy re-reads pointer immediately before qm stop" {
    gen_store_init
    gen_create 8901 \
        GEN_ID=1 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.0.0
    : > "$STUB_DIR/qm-created-8901"
    export CONFIG_FILE
    qm_stub() {
        if [[ "$1" == "status" && "$2" == "8901" ]]; then
            local tmp
            tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
            awk -v vmid=8901 '
                /^TEMPLATE_ID="/ { print "TEMPLATE_ID=\"" vmid "\""; next }
                /^TEMPLATE_ID=/ { print "TEMPLATE_ID=" vmid; next }
                { print }
            ' "$CONFIG_FILE" > "$tmp"
            mv "$tmp" "$CONFIG_FILE"
            echo "status: stopped"
            return 0
        fi
        bake_qm_stub "$@"
    }
    export -f qm_stub
    run bake_reap_vmid 8901 candidate "leftover"
    [ "$status" -eq 0 ]
    refute_called qm 'destroy 8901*'
    refute_called qm 'stop 8901*'
}

@test "unmemo failure after candidate does not destroy the new template" {
    gen_store_init
    gen_create 8901 \
        GEN_ID=1 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.0.0
    : > "$STUB_DIR/qm-created-8901"
    unmemo_failed_digest() { return 1; }

    run bake_main --force
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    refute_called qm 'destroy 8900*'
    gen_read 8901
    [ "$GEN_STATE" = "failed" ]
    assert_called qm 'destroy 8901*'
}

@test "failed bake notifies bake.failed with NOTIFY_GENERATION" {
    : > "$STUB_DIR/qm-start-fail"
    run bake_main --force
    [ "$status" -ne 0 ]
    grep -q 'NOTIFY_GENERATION=1 error bake.failed' "$STUB_DIR/notify.log"
}
