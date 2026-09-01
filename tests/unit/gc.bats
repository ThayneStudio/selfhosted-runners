#!/usr/bin/env bats
# Garbage-collection policy and destructive record gating (spec 9).

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib gc.sh
    MIN_VMID=9001
    TEMPLATE_ID=8903
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=8903
    apply_generation_defaults
    GC_LOCK_FILE="$STUB_DIR/gc.lock"

    gen_now() { printf '2026-08-31T12:00:00Z\n'; }
    notify() { printf '%s\n' "$*" >> "$STUB_DIR/notify.log"; }
    generation_ref_vmids() {
        local file="$STUB_DIR/blockers-$1"
        [[ ! -f "$file" ]] || cat "$file"
    }
    list_template_linked_clone_volids() { :; }
    gc_storage_used_bytes() { printf '0\n'; }
    gc_storage_is_clean() { return 0; }
}

make_gen() {
    local vmid="$1" id="$2" state="$3" created="${4:-2026-08-01T00:00:00Z}"
    gen_create "$vmid" "GEN_ID=$id" "GEN_STATE=$state" \
        "GEN_CREATED_AT=$created" "GEN_RUNNER_VERSION=2.336.0"
}

stub_generation_template() {
    local vmid="$1" id="$2"
    stub_out qm "config $vmid" <<EOF
name: github-runner-gen-${id}
template: 1
EOF
}

@test "dry-run names blockers and changes no generation state" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    gen_update 8901 GEN_WAS_ACTIVE=1
    gen_update 8900 GEN_SUPERSEDED_AT=2026-08-01T00:00:00Z
    gen_update 8901 GEN_SUPERSEDED_AT=2026-08-20T00:00:00Z
    printf '9001\n9002\n' > "$STUB_DIR/blockers-1"

    run --separate-stderr gc_main true
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"blocked by VMIDs: 9001 9002"* ]]
    [ "$(gen_state_of 8900)" = superseded ]
    [ "$(gen_state_of 8901)" = superseded ]
    [ ! -f "$GENERATION_ARCHIVE_LOG" ]
    [ ! -f "$STUB_DIR/notify.log" ]
    refute_called qm 'destroy *'
    refute_called pvesm 'free *'
}

@test "destroys drained old superseded generation and retains exactly the newest" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    gen_update 8901 GEN_WAS_ACTIVE=1
    stub_out qm 'status 8900' < /dev/null
    stub_generation_template 8900 1
    stub_out qm 'destroy 8900 --purge' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    ! gen_exists 8900
    gen_exists 8901
    [ "$(gen_state_of 8901)" = superseded ]
    grep -q 'gen=1 vmid=8900 event=destroyed' "$GENERATION_ARCHIVE_LOG"
    grep -q 'info gc.destroyed' "$STUB_DIR/notify.log"
    [ "$(call_count qm 'destroy *')" -eq 1 ]
}

@test "destroy failure leaves the generation record and warns" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    stub_out qm 'status 8900' < /dev/null
    stub_generation_template 8900 1
    stub_status qm 'destroy 8900 --purge' 2

    run --separate-stderr gc_main false
    [ "$status" -eq 1 ]
    gen_exists 8900
    [ "$(gen_state_of 8900)" = superseded ]
    [ ! -f "$GENERATION_ARCHIVE_LOG" ]
    grep -q 'warn gc.failed' "$STUB_DIR/notify.log"
}

@test "child-volume cleanup failure leaves the destroyed generation record" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    list_template_linked_clone_volids() { printf 'local-zfs:base-8900-disk-0/vm-9001-disk-0\n'; }
    cleanup_template_orphan_volumes() { return 1; }
    stub_out qm 'status 8900' < /dev/null
    stub_generation_template 8900 1
    stub_out qm 'destroy 8900 --purge' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 1 ]
    gen_exists 8900
    [ "$(gen_state_of 8900)" = superseded ]
    [ ! -f "$GENERATION_ARCHIVE_LOG" ]
    grep -q 'warn gc.failed' "$STUB_DIR/notify.log"
}

@test "stuck superseded generation warns with blocking VMIDs" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    gen_update 8900 GEN_SUPERSEDED_AT=2026-08-01T00:00:00Z
    printf '9001\n9002\n' > "$STUB_DIR/blockers-1"

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    grep -q 'warn gc.blocked' "$STUB_DIR/notify.log"
    grep -q 'blocking_vmids=9001,9002' "$STUB_DIR/notify.log"
    refute_called qm 'destroy *'
}

@test "supersedes and collects older candidates, then fails an expired newest candidate" {
    make_gen 8903 1 active
    make_gen 8900 2 candidate 2026-08-26T00:00:00Z
    make_gen 8901 3 candidate 2026-08-26T00:00:00Z
    stub_out qm 'status 8900' < /dev/null
    stub_generation_template 8900 2
    stub_out qm 'destroy 8900 --purge' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    ! gen_exists 8900
    [ "$(gen_state_of 8901)" = failed ]
    grep -q 'warn candidate.failed' "$STUB_DIR/notify.log"
    [ "$(call_count qm 'destroy *')" -eq 1 ]
}

@test "rejected generations are never selected as rollback retention" {
    make_gen 8900 1 superseded
    make_gen 8901 2 rejected
    make_gen 8903 3 active
    gen_update 8900 GEN_WAS_ACTIVE=1
    gen_update 8901 GEN_SUPERSEDED_AT=2026-08-01T00:00:00Z
    stub_out qm 'status 8901' < /dev/null
    stub_generation_template 8901 2
    stub_out qm 'destroy 8901 --purge' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    gen_exists 8900
    ! gen_exists 8901
    assert_called qm 'destroy 8901 --purge'
}

@test "an orphan candidate cannot displace the prior-active rollback target" {
    make_gen 8900 1 superseded
    make_gen 8901 2 candidate
    make_gen 8903 3 active
    gen_update 8900 GEN_WAS_ACTIVE=1
    stub_out qm 'status 8901' < /dev/null
    stub_generation_template 8901 2
    stub_out qm 'destroy 8901 --purge' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    gen_exists 8900
    ! gen_exists 8901
    assert_called qm 'destroy 8901 --purge'
}

@test "dry-run prints same-run orphan candidate destruction without mutation" {
    make_gen 8900 1 superseded
    make_gen 8901 2 candidate
    make_gen 8903 3 active
    gen_update 8900 GEN_WAS_ACTIVE=1
    stub_out qm 'status 8901' < /dev/null
    stub_generation_template 8901 2

    run --separate-stderr gc_main true
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would supersede orphaned candidate generation 2"* ]]
    [[ "$output" == *"Would destroy generation 2"* ]]
    [ "$(gen_state_of 8901)" = candidate ]
    [ ! -f "$GENERATION_ARCHIVE_LOG" ]
}

@test "a missing GEN_WAS_ACTIVE needs positive promotion evidence for rollback" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    gen_update 8900 GEN_PROMOTED_AT=2026-08-20T00:00:00Z
    stub_out qm 'status 8901' < /dev/null
    stub_generation_template 8901 2
    stub_out qm 'destroy 8901 --purge' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    gen_exists 8900
    ! gen_exists 8901
}

@test "ownership accepts the fixed legacy adopted template name" {
    make_gen 8900 1 superseded
    gen_update 8900 GEN_IMAGE_SHA256=unknown GEN_TEMPLATE_DIGEST=unknown
    stub_out qm 'status 8900' < /dev/null
    stub_out qm 'config 8900' <<'EOF'
name: ubuntu-cloud-template
template: 1
EOF
    stub_out qm 'destroy 8900 --purge' < /dev/null

    run --separate-stderr gc_destroy_generation 8900 superseded false
    [ "$status" -eq 0 ]
    ! gen_exists 8900
    assert_called qm 'destroy 8900 --purge'
}

@test "dry-run executes ownership preflight and reports the real refusal" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    gen_update 8901 GEN_WAS_ACTIVE=1
    stub_out qm 'status 8900' < /dev/null
    stub_out qm 'config 8900' <<'EOF'
name: reused-vmid
template: 1
EOF

    run --separate-stderr gc_main true
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Ownership verification failed"* ]]
    [[ "$output" != *"Would destroy generation 1"* ]]
    gen_exists 8900
}

@test "dry-run executes storage inventory preflight before claiming destruction" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    gen_update 8901 GEN_WAS_ACTIVE=1
    list_template_linked_clone_volids() { return 1; }

    run --separate-stderr gc_main true
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Could not inventory child volumes"* ]]
    [[ "$output" != *"Would destroy generation 1"* ]]
}

@test "a sole candidate older than the active generation is orphaned" {
    make_gen 8900 1 superseded
    make_gen 8901 2 candidate 2026-08-31T11:00:00Z
    make_gen 8903 3 active
    gen_update 8900 GEN_WAS_ACTIVE=1
    stub_out qm 'status 8901' < /dev/null
    stub_generation_template 8901 2
    stub_out qm 'destroy 8901 --purge' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    ! gen_exists 8901
    gen_exists 8900
}

@test "destroy refuses a stale record when the VMID now names another VM" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    stub_out qm 'status 8900' < /dev/null
    stub_out qm 'config 8900' <<'EOF'
name: unrelated-production-vm
template: 1
EOF

    run --separate-stderr gc_main false
    [ "$status" -eq 1 ]
    gen_exists 8900
    refute_called qm 'destroy 8900 --purge'
    [[ "$stderr" == *"refusing destroy"* ]]
}

@test "destroy refuses a non-template Proxmox config" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    stub_out qm 'status 8900' < /dev/null
    stub_out qm 'config 8900' <<'EOF'
name: github-runner-gen-1
template: 0
EOF

    run --separate-stderr gc_main false
    [ "$status" -eq 1 ]
    gen_exists 8900
    refute_called qm 'destroy 8900 --purge'
    [[ "$stderr" == *"not a Proxmox template"* ]]
}

@test "destroy refuses an unreadable Proxmox config" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    stub_out qm 'status 8900' < /dev/null
    stub_status qm 'config 8900' 2

    run --separate-stderr gc_main false
    [ "$status" -eq 1 ]
    gen_exists 8900
    refute_called qm 'destroy 8900 --purge'
    [[ "$stderr" == *"Cannot read Proxmox config"* ]]
}

@test "destroy refuses a record whose GEN_VMID does not match its path" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
    sed -i.bak 's/^GEN_VMID=.*/GEN_VMID="8999"/' "$GENERATIONS_DIR/8900.conf"
    stub_out qm 'status 8900' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 1 ]
    gen_exists 8900
    refute_called qm 'destroy 8900 --purge'
    [[ "$stderr" == *"ownership changed"* ]]
}

@test "terminal retention starts when the generation enters failed" {
    make_gen 8900 1 failed 2026-01-01T00:00:00Z
    make_gen 8903 3 active
    gen_update 8900 GEN_TERMINAL_AT=2026-08-31T11:00:00Z

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    gen_exists 8900
    refute_called qm 'destroy *'
}

@test "archive and record removal retry does not duplicate destroyed events" {
    make_gen 8900 1 superseded
    stub_out qm 'status 8900' < /dev/null
    stub_generation_template 8900 1
    stub_out qm 'destroy 8900 --purge' < /dev/null
    gen_remove() {
        if [[ ! -e "$STUB_DIR/remove-failed" ]]; then
            touch "$STUB_DIR/remove-failed"
            return 1
        fi
        rm -f "$(gen_record_path "$1")"
    }

    run --separate-stderr gc_destroy_generation 8900 superseded false
    [ "$status" -eq 1 ]
    gen_exists 8900
    qm() { [[ "$1" == status ]] && return 1; command qm "$@"; }
    run --separate-stderr gc_destroy_generation 8900 superseded false
    [ "$status" -eq 0 ]
    ! gen_exists 8900
    [ "$(grep -c 'gen=1 vmid=8900 event=destroyed' "$GENERATION_ARCHIVE_LOG")" -eq 1 ]
}

@test "gc does not remove or wait behind a promotion-owned pause" {
    make_gen 8903 3 active
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")"
    exec 219>"$PROMOTION_PAUSE_FILE"
    flock -n 219

    run --separate-stderr gc_main false
    [ "$status" -eq 1 ]
    [ -e "$PROMOTION_PAUSE_FILE" ]
    [[ "$stderr" == *"Promotion pause is owned"* ]]
    exec 219>&-
}

@test "gc command is wired into runner help and rejects unknown options" {
    grep -q 'gc).*lib/gc.sh' "$REPO_ROOT/runner"
    grep -q 'cleanup_template_orphan_volumes "\$generation_vmid"' "$REPO_ROOT/lib/stop.sh"
    run gc_cli --wat
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage: runner gc"* ]]
}
