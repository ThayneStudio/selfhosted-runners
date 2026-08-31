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

@test "dry-run names blockers and changes no generation state" {
    make_gen 8900 1 superseded
    make_gen 8901 2 superseded
    make_gen 8903 3 active
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
    stub_out qm 'status 8900' < /dev/null
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

@test "supersedes older candidates and fails an expired newest candidate" {
    make_gen 8900 1 candidate 2026-08-26T00:00:00Z
    make_gen 8901 2 candidate 2026-08-26T00:00:00Z
    make_gen 8903 3 active

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    [ "$(gen_state_of 8900)" = superseded ]
    [ "$(gen_state_of 8901)" = failed ]
    grep -q 'warn candidate.failed' "$STUB_DIR/notify.log"
    refute_called qm 'destroy *'
}

@test "rejected generations are never selected as rollback retention" {
    make_gen 8900 1 superseded
    make_gen 8901 2 rejected
    make_gen 8903 3 active
    gen_update 8901 GEN_SUPERSEDED_AT=2026-08-01T00:00:00Z
    stub_out qm 'status 8901' < /dev/null
    stub_out qm 'destroy 8901 --purge' < /dev/null

    run --separate-stderr gc_main false
    [ "$status" -eq 0 ]
    gen_exists 8900
    ! gen_exists 8901
    assert_called qm 'destroy 8901 --purge'
}

@test "gc command is wired into runner help and rejects unknown options" {
    grep -q 'gc).*lib/gc.sh' "$REPO_ROOT/runner"
    grep -q 'cleanup_template_orphan_volumes "\$generation_vmid"' "$REPO_ROOT/lib/stop.sh"
    run gc_cli --wat
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage: runner gc"* ]]
}
