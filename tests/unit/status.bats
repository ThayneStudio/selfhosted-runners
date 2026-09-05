#!/usr/bin/env bats
# runner status and runner generations — read-only fleet overview.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib status.sh
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    notify() {
        printf '%s\n' "$*" >> "$STUB_DIR/notify.log"
    }
    gen_now() { printf '%s\n' '2026-08-25T00:00:00Z'; }

    # status.sh now sources drift.sh for the upstream fetch, which shells out
    # to jq (same stub as tests/unit/drift.bats -- kept in sync with it).
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
}

host_fingerprint() {
    find "$HOST_SANDBOX" -type f -exec md5sum {} \; | sort
}

write_org_pool() {
    local org="$1" count="${2:-2}" prefix="${3:-runner}"
    write_org_config "$org"
    printf 'RUNNER_PREFIX="%s"\nRUNNER_COUNT="%s"\n' "$prefix" "$count" \
        >> "$ORG_CONFIG_DIR/${org}.conf"
}

make_active() {
    local version="${1:-2.334.0}"
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_RUNNER_VERSION="$version" \
        GEN_TEMPLATE_DIGEST=abc \
        GEN_IMAGE_SHA256=abc \
        GEN_CREATED_AT=2026-08-22T00:00:00Z
}

stub_upstream() {
    local tag="${1:-v2.336.0}" published="${2:-2026-08-01T00:00:00Z}"
    stub_out curl '*' <<EOF
{"tag_name":"$tag","published_at":"$published"}
EOF
}

# generation_refcount (spec 5, #17) traces ZFS/nested origin for every live
# generation record's own base volid, not just the disk-usage lookup this
# helper is named for -- so `pvesm path` needs a rule too, or the untagged-
# origin scan in generation_ref_vmids fails closed with "Cannot resolve
# storage path". A plain non-zvol path is enough: it makes the ZFS-clone
# branch in list_template_linked_clone_volids a no-op, same as
# stub_empty_origin in tests/unit/generation_refcount.bats.
stub_disk() {
    stub_out pvesm 'list local-zfs' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-9000-disk-0                     raw     images     32212254720 9000
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF
}

# Two acme clones tagged gen-1 plus the adopted template.
stub_adopted_fleet() {
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1234
      9002 runner-2             running    8192              30.00 1235
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF
    stub_out qm 'config 9002' <<'EOF'
name: runner-2
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF
}

@test "lib/status.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/status.sh"
}

@test "runner dispatches the status and generations verbs" {
    grep -Eq '^[[:space:]]*status\)' "$REPO_ROOT/runner"
    grep -Eq '^[[:space:]]*generations\)' "$REPO_ROOT/runner"
}

@test "runner help lists status and generations" {
    run "$REPO_ROOT/runner" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"status"* ]]
    [[ "$output" == *"generations"* ]]
}

@test "generations_main degrades with no records" {
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
EOF

    run --separate-stderr generations_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"(no generations)"* ]]
    refute_called curl '*'
    refute_called qm 'set *'
    refute_called qm 'clone *'
    refute_called qm 'destroy *'
    refute_called pvesm 'free *'
    refute_called zfs 'destroy *'
}

@test "generations_main prints id VMID state runner age clones disk" {
    make_active
    stub_adopted_fleet
    stub_disk

    run --separate-stderr generations_main
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'ID'
    echo "$output" | grep -q 'VMID'
    echo "$output" | grep -q 'STATE'
    echo "$output" | grep -q 'RUNNER'
    echo "$output" | grep -q 'AGE'
    echo "$output" | grep -q 'CLONES'
    echo "$output" | grep -q 'DISK'
    echo "$output" | grep -E '^1[[:space:]]+9000[[:space:]]+active' | grep -q '2.334.0'
    echo "$output" | grep -E '^1[[:space:]]+9000' | grep -q '3d'
    echo "$output" | grep -E '^1[[:space:]]+9000' | grep -q '2'
    echo "$output" | grep -E '^1[[:space:]]+9000' | grep -q '30G'
    refute_called curl '*'
}

@test "status_main degrades with no generation records" {
    write_org_pool acme 2
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9001 runner-1             running    8192              30.00 1234
      9002 runner-2             running    8192              30.00 1235
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out qm 'config 9002' <<'EOF'
name: runner-2
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr status_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"(no generations)"* ]]
    [[ "$output" == *"no generation records"* ]]
    [[ "$output" == *"Last bake: none"* ]]
    [[ "$output" == *"acme"* ]]
    [[ "$output" == *"Status: OK"* ]]
    [ ! -f "$STUB_DIR/notify.log" ]
}

@test "status_main flags 2.334.0 drift versus upstream and exits non-zero" {
    make_active 2.334.0
    write_org_pool acme 2
    stub_adopted_fleet
    stub_disk
    stub_upstream v2.336.0 2026-08-01T00:00:00Z

    run --separate-stderr status_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"2.334.0"* ]]
    [[ "$output" == *"2.336.0"* ]]
    [[ "$output" == *"[drift]"* ]]
    [[ "$output" == *"Status: ATTENTION"* ]]
    [ ! -f "$STUB_DIR/notify.log" ]
}

@test "status_main is OK when on latest, pools are full, and drain is inactive" {
    make_active 2.336.0
    write_org_pool acme 2
    stub_adopted_fleet
    stub_disk
    stub_upstream v2.336.0 2026-08-01T00:00:00Z

    run --separate-stderr status_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"on latest"* ]]
    [[ "$output" == *"Drain: inactive"* ]]
    [[ "$output" == *"Status: OK"* ]]
}

@test "status_main normalizes a v-prefixed active version against upstream" {
    make_active v2.336.0
    write_org_pool acme 2
    stub_adopted_fleet
    stub_disk
    stub_upstream 2.336.0 2026-08-01T00:00:00Z

    run --separate-stderr status_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"active:    2.336.0"* ]]
    [[ "$output" == *"upstream:  2.336.0"* ]]
    [[ "$output" == *"on latest"* ]]
    [[ "$output" != *"[drift]"* ]]
    [[ "$output" == *"Status: OK"* ]]
}

@test "status_main reports per-org pool fill and flags an underfilled org" {
    make_active 2.336.0
    write_org_pool acme 2
    write_org_pool beta 2
    write_org_pool gamma 2
    stub_upstream v2.336.0 2026-08-01T00:00:00Z
    stub_disk
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1
      9002 runner-2             running    8192              30.00 2
      9003 runner-3             running    8192              30.00 3
      9004 runner-4             running    8192              30.00 4
      9005 runner-5             running    8192              30.00 5
EOF
    stub_out qm 'config 9001' <<'EOF'
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF
    stub_out qm 'config 9002' <<'EOF'
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF
    stub_out qm 'config 9003' <<'EOF'
cicustom: user=local:snippets/runner-user-data-beta.yaml
tags: runner;gen-1
EOF
    stub_out qm 'config 9004' <<'EOF'
cicustom: user=local:snippets/runner-user-data-beta.yaml
tags: runner;gen-1
EOF
    stub_out qm 'config 9005' <<'EOF'
cicustom: user=local:snippets/runner-user-data-gamma.yaml
tags: runner;gen-1
EOF

    run --separate-stderr status_main
    [ "$status" -ne 0 ]
    echo "$output" | grep acme | grep -q '2'
    echo "$output" | grep beta | grep -q '2'
    echo "$output" | grep gamma | grep -q '\[under\]'
}

@test "status_main flags drain as attention" {
    make_active 2.336.0
    write_org_pool acme 2
    stub_adopted_fleet
    stub_disk
    stub_upstream v2.336.0 2026-08-01T00:00:00Z
    enable_pool_drain

    run --separate-stderr status_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"Drain: active"* ]]
}

@test "status_main shows last bake from the newest generation record" {
    make_active 2.336.0
    gen_create 8901 \
        GEN_ID=2 \
        GEN_STATE=failed \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_TEMPLATE_DIGEST=def \
        GEN_IMAGE_SHA256=def \
        GEN_CREATED_AT=2026-08-24T00:00:00Z \
        GEN_FAILED_REASON='checksum mismatch'
    write_org_pool acme 2
    stub_adopted_fleet
    stub_disk
    stub_upstream v2.336.0 2026-08-01T00:00:00Z
    stub_out qm 'config 8901' <<'EOF'
name: github-runner-gen-2
template: 1
EOF

    run --separate-stderr status_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"Last bake: generation 2 failed at 2026-08-24T00:00:00Z"* ]]
    [[ "$output" == *"checksum mismatch"* ]]
}

@test "status_main shows last notification when the file exists" {
    make_active 2.336.0
    write_org_pool acme 2
    stub_adopted_fleet
    stub_disk
    stub_upstream v2.336.0 2026-08-01T00:00:00Z
    printf '2026-08-22T04:11:07Z warn drift.warning behind upstream\n' \
        > "$LAST_NOTIFY_FILE"

    run --separate-stderr status_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"Last notification: 2026-08-22T04:11:07Z warn drift.warning behind upstream"* ]]
}

@test "status_main shows last notification none when the file is absent" {
    make_active 2.336.0
    write_org_pool acme 2
    stub_adopted_fleet
    stub_disk
    stub_upstream v2.336.0 2026-08-01T00:00:00Z

    run --separate-stderr status_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"Last notification: none"* ]]
}

@test "status_main does not write config VMs or generation records" {
    make_active 2.334.0
    write_org_pool acme 2
    stub_adopted_fleet
    stub_disk
    stub_upstream v2.336.0 2026-08-01T00:00:00Z
    local before after
    before=$(host_fingerprint)

    run --separate-stderr status_main
    [ "$status" -ne 0 ]

    after=$(host_fingerprint)
    [ "$before" = "$after" ]
    refute_called qm 'set *'
    refute_called qm 'clone *'
    refute_called qm 'destroy *'
    refute_called qm 'start *'
    refute_called qm 'stop *'
    refute_called pvesm 'free *'
    refute_called zfs 'destroy *'
    [ ! -f "$STUB_DIR/notify.log" ]
}

@test "generations_main does not write config VMs or generation records" {
    make_active
    stub_adopted_fleet
    stub_disk
    local before after
    before=$(host_fingerprint)

    run --separate-stderr generations_main
    [ "$status" -eq 0 ]

    after=$(host_fingerprint)
    [ "$before" = "$after" ]
    refute_called qm 'set *'
    refute_called qm 'clone *'
    refute_called qm 'destroy *'
    refute_called pvesm 'free *'
    refute_called zfs 'destroy *'
    refute_called curl '*'
}

@test "status_main with no records does not create generation files" {
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
EOF
    local before after
    before=$(host_fingerprint)

    run --separate-stderr status_main
    [ "$status" -eq 0 ]

    after=$(host_fingerprint)
    [ "$before" = "$after" ]
    [[ -z "$(gen_list)" ]]
    [ ! -f "$GENERATION_COUNTER_FILE" ]
}
