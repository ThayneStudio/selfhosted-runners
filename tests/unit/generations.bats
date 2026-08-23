#!/usr/bin/env bats
# Unit tests for lib/generations.sh — the generation state store.
#
# Pure filesystem logic: no Proxmox, no network, no root. The store is pointed
# at a per-test temp directory via RUNNER_STATE_DIR.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GEN_TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gen.XXXXXX")"

    unset GENERATIONS_DIR
    export RUNNER_STATE_DIR="$GEN_TEST_DIR/state"

    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/generations.sh"
    gen_store_init
}

teardown() {
    rm -rf "$GEN_TEST_DIR"
}

file_mode() {
    # GNU stat on the Proxmox host, BSD stat when run on a macOS workstation.
    stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"
}

# Fully populated record, used by the round-trip tests.
create_full_record() {
    gen_create 8903 \
        GEN_ID=7 \
        GEN_STATE=active \
        GEN_RUNNER_VERSION=2.336.0 \
        GEN_IMAGE_SHA256=5fa5b05e1c9d1e2f3a4b5c6d7e8f90112233445566778899aabbccddeeff0011 \
        GEN_TEMPLATE_DIGEST=00112233445566778899aabbccddeeff5fa5b05e1c9d1e2f3a4b5c6d7e8f9011 \
        GEN_CREATED_AT=2026-08-22T01:14:03Z \
        GEN_PROMOTED_AT=2026-08-22T02:20:00Z \
        GEN_SUPERSEDED_AT=2026-08-29T02:20:00Z \
        GEN_FAILED_REASON='canary run 41 failed' \
        GEN_BAKE_LOG=/var/log/github-runners/bake-7.log \
        GEN_CANARY_RUN_URL=https://github.com/acme/ci/actions/runs/41 \
        GEN_CANARY_ATTEMPTS=2
}

# ---------------------------------------------------------------------------
# Store layout
# ---------------------------------------------------------------------------

@test "store init creates the generations directory root-only" {
    [ -d "$GENERATIONS_DIR" ]
    [ "$(file_mode "$GENERATIONS_DIR")" = "700" ]
    [ "$(file_mode "$RUNNER_STATE_DIR")" = "700" ]
}

@test "store init is idempotent" {
    gen_store_init
    gen_store_init
    [ -d "$GENERATIONS_DIR" ]
}

# ---------------------------------------------------------------------------
# Record round-tripping
# ---------------------------------------------------------------------------

@test "a record round-trips every field through write and read" {
    create_full_record

    gen_read 8903
    [ "$GEN_ID" = "7" ]
    [ "$GEN_VMID" = "8903" ]
    [ "$GEN_STATE" = "active" ]
    [ "$GEN_RUNNER_VERSION" = "2.336.0" ]
    [ "$GEN_IMAGE_SHA256" = "5fa5b05e1c9d1e2f3a4b5c6d7e8f90112233445566778899aabbccddeeff0011" ]
    [ "$GEN_TEMPLATE_DIGEST" = "00112233445566778899aabbccddeeff5fa5b05e1c9d1e2f3a4b5c6d7e8f9011" ]
    [ "$GEN_CREATED_AT" = "2026-08-22T01:14:03Z" ]
    [ "$GEN_PROMOTED_AT" = "2026-08-22T02:20:00Z" ]
    [ "$GEN_SUPERSEDED_AT" = "2026-08-29T02:20:00Z" ]
    [ "$GEN_FAILED_REASON" = "canary run 41 failed" ]
    [ "$GEN_BAKE_LOG" = "/var/log/github-runners/bake-7.log" ]
    [ "$GEN_CANARY_RUN_URL" = "https://github.com/acme/ci/actions/runs/41" ]
    [ "$GEN_CANARY_ATTEMPTS" = "2" ]
}

@test "a record round-trips shell metacharacters in a free-text field" {
    local reason='bake died: "qm clone" $HOME `id` 50% \ done'
    gen_create 8904 GEN_ID=8 GEN_STATE=failed GEN_FAILED_REASON="$reason"

    gen_read 8904
    [ "$GEN_FAILED_REASON" = "$reason" ]
}

@test "a record is shell-sourceable, as the conf idiom promises" {
    local reason='bake died: "qm clone" $HOME `id` 50% \ done'
    gen_create 8904 GEN_ID=8 GEN_STATE=failed GEN_FAILED_REASON="$reason"

    # Read it the way an operator or a future script would.
    run bash -c "set -u; source '$GENERATIONS_DIR/8904.conf'; printf '%s|%s|%s' \"\$GEN_ID\" \"\$GEN_STATE\" \"\$GEN_FAILED_REASON\""
    [ "$status" -eq 0 ]
    [ "$output" = "8|failed|$reason" ]
}

@test "a record is written root-only" {
    create_full_record
    [ "$(file_mode "$GENERATIONS_DIR/8903.conf")" = "600" ]
}

@test "empty fields round-trip as empty, not as the string from another record" {
    gen_create 8903 GEN_ID=1 GEN_STATE=active GEN_PROMOTED_AT=2026-08-22T02:20:00Z
    gen_create 8904 GEN_ID=2 GEN_STATE=baking

    gen_read 8903
    [ "$GEN_PROMOTED_AT" = "2026-08-22T02:20:00Z" ]
    gen_read 8904
    [ "$GEN_PROMOTED_AT" = "" ]
    [ "$GEN_SUPERSEDED_AT" = "" ]
    [ "$GEN_FAILED_REASON" = "" ]
}

@test "reading a missing record fails" {
    run gen_read 9999
    [ "$status" -eq 1 ]
    [[ "$output" == *"No generation record for VMID 9999"* ]]
}

@test "a malformed record is reported, not half-applied" {
    gen_create 8903 GEN_ID=1 GEN_STATE=baking
    printf 'this is not a key=value line\n' >> "$GENERATIONS_DIR/8903.conf"

    run gen_read 8903
    [ "$status" -eq 1 ]
    [[ "$output" == *"Malformed line"* ]]
}

@test "an unknown field in a record is ignored with a warning" {
    gen_create 8903 GEN_ID=1 GEN_STATE=baking
    printf 'GEN_FUTURE_FIELD="whatever"\n' >> "$GENERATIONS_DIR/8903.conf"

    run gen_read 8903
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ignoring unknown field GEN_FUTURE_FIELD"* ]]
}

@test "creating over an existing record is refused" {
    gen_create 8903 GEN_ID=1 GEN_STATE=baking
    run gen_create 8903 GEN_ID=2 GEN_STATE=baking
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists"* ]]

    gen_read 8903
    [ "$GEN_ID" = "1" ]
}

@test "creating with an unknown field is refused" {
    run gen_create 8903 GEN_NOT_A_FIELD=x
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown generation field"* ]]
    [ ! -e "$GENERATIONS_DIR/8903.conf" ]
}

@test "creating with a malformed argument is refused" {
    run gen_create 8903 "not-a-pair"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Expected KEY=VALUE"* ]]
}

@test "creating with a non-numeric vmid is refused" {
    run gen_create "../etc/passwd"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid generation VMID"* ]]
}

@test "creating with an invalid state is refused" {
    run gen_create 8903 GEN_STATE=zombie
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid generation state"* ]]
}

@test "creation defaults id, state and timestamp" {
    gen_create 8903

    gen_read 8903
    [ "$GEN_ID" = "1" ]
    [ "$GEN_STATE" = "baking" ]
    [[ "$GEN_CREATED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "update rewrites the given fields and preserves the rest" {
    create_full_record
    gen_update 8903 GEN_CANARY_ATTEMPTS=3 GEN_CANARY_RUN_URL=https://example.test/runs/99

    gen_read 8903
    [ "$GEN_CANARY_ATTEMPTS" = "3" ]
    [ "$GEN_CANARY_RUN_URL" = "https://example.test/runs/99" ]
    [ "$GEN_ID" = "7" ]
    [ "$GEN_STATE" = "active" ]
    [ "$GEN_RUNNER_VERSION" = "2.336.0" ]
    [ "$GEN_CREATED_AT" = "2026-08-22T01:14:03Z" ]
    [ "$GEN_FAILED_REASON" = "canary run 41 failed" ]
}

@test "update refuses to move the state machine behind its back" {
    gen_create 8903 GEN_ID=1 GEN_STATE=failed

    run gen_update 8903 GEN_STATE=active
    [ "$status" -eq 1 ]
    [[ "$output" == *"gen_transition"* ]]
    [ "$(gen_state_of 8903)" = "failed" ]
}

@test "update refuses to re-point a record at another vmid" {
    gen_create 8903 GEN_ID=1 GEN_STATE=baking
    run gen_update 8903 GEN_VMID=8904
    [ "$status" -eq 1 ]
}

@test "listing filters by state and sorts numerically" {
    gen_create 9010 GEN_ID=1 GEN_STATE=superseded
    gen_create 890 GEN_ID=2 GEN_STATE=active
    gen_create 8903 GEN_ID=3 GEN_STATE=superseded

    [ "$(gen_list)" = "$(printf '890\n8903\n9010')" ]
    [ "$(gen_list superseded)" = "$(printf '8903\n9010')" ]
    [ "$(gen_list active)" = "890" ]
    [ "$(gen_list candidate)" = "" ]
}

@test "listing ignores the counter, its lock and the archive log" {
    gen_create 8903 GEN_ID=1 GEN_STATE=active
    gen_next_id > /dev/null
    gen_archive_append 1 8903 destroyed

    [ "$(gen_list)" = "8903" ]
}

@test "listing rejects an unknown state filter" {
    run gen_list zombie
    [ "$status" -eq 1 ]
}

@test "a generation id resolves to its vmid" {
    gen_create 8903 GEN_ID=7 GEN_STATE=active
    gen_create 8904 GEN_ID=8 GEN_STATE=candidate

    [ "$(gen_vmid_for_id 8)" = "8904" ]
    [ "$(gen_vmid_for_id 7)" = "8903" ]
    run gen_vmid_for_id 9
    [ "$status" -eq 1 ]
}

@test "removing a record requires it to not be the active generation" {
    gen_create 8903 GEN_ID=1 GEN_STATE=active
    run gen_remove 8903
    [ "$status" -eq 1 ]
    [ -e "$GENERATIONS_DIR/8903.conf" ]

    gen_transition 8903 superseded
    gen_remove 8903
    [ ! -e "$GENERATIONS_DIR/8903.conf" ]
}

# ---------------------------------------------------------------------------
# Generation id counter
# ---------------------------------------------------------------------------

@test "the counter starts at one and increments" {
    [ "$(gen_next_id)" = "1" ]
    [ "$(gen_next_id)" = "2" ]
    [ "$(gen_next_id)" = "3" ]
    [ "$(cat "$GENERATION_COUNTER_FILE")" = "3" ]
}

@test "two concurrent increments produce two distinct ids" {
    local ids="$GEN_TEST_DIR/ids"
    mkdir -p "$ids"

    local i
    for ((i = 0; i < 20; i++)); do
        ( gen_next_id > "$ids/$i" ) &
    done
    wait

    local total distinct
    total=$(cat "$ids"/* | wc -l | tr -d ' ')
    distinct=$(cat "$ids"/* | sort -u | wc -l | tr -d ' ')
    [ "$total" = "20" ]
    [ "$distinct" = "20" ]
    [ "$(cat "$GENERATION_COUNTER_FILE")" = "20" ]
}

@test "an id is never reused after its generation is destroyed" {
    local first
    first=$(gen_next_id)
    gen_create 8903 "GEN_ID=$first" GEN_STATE=superseded
    gen_remove 8903

    [ "$(gen_next_id)" != "$first" ]
    [ "$(gen_next_id)" = "3" ]
}

@test "an id claimed directly by adoption is not handed out again" {
    # Adoption (spec 8) writes generation 1 for the already-deployed template
    # without going through the counter.
    gen_create 9000 GEN_ID=1 GEN_STATE=active

    [ "$(gen_next_id)" = "2" ]
}

@test "a lost counter is reseeded from the surviving records" {
    gen_create 8903 GEN_ID=6 GEN_STATE=superseded
    gen_create 8904 GEN_ID=7 GEN_STATE=active
    rm -f "$GENERATION_COUNTER_FILE"

    [ "$(gen_next_id)" = "8" ]
}

@test "a corrupt counter is reported rather than silently reset" {
    printf 'not-a-number\n' > "$GENERATION_COUNTER_FILE"

    run gen_next_id
    [ "$status" -eq 1 ]
    [[ "$output" == *"corrupt"* ]]
}

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

@test "every documented transition is accepted" {
    local pair from to
    for pair in \
        "baking candidate" \
        "baking failed" \
        "candidate active" \
        "candidate superseded" \
        "candidate failed" \
        "active superseded" \
        "active rejected" \
        "superseded active"; do
        from="${pair% *}"
        to="${pair#* }"

        rm -f "$GENERATIONS_DIR"/*.conf
        gen_create 8903 GEN_ID=1 "GEN_STATE=$from"
        run gen_transition 8903 "$to"
        [ "$status" -eq 0 ]
        [ "$(gen_state_of 8903)" = "$to" ]
    done
}

@test "every transition outside the documented set is rejected" {
    local from to
    for from in "${GENERATION_STATES[@]}"; do
        for to in "${GENERATION_STATES[@]}"; do
            case "$from:$to" in
                baking:candidate|baking:failed) continue ;;
                candidate:active|candidate:superseded|candidate:failed) continue ;;
                active:superseded|active:rejected) continue ;;
                superseded:active) continue ;;
            esac
            run gen_transition_allowed "$from" "$to"
            [ "$status" -eq 1 ]
        done
    done
}

@test "a failed generation cannot be promoted" {
    gen_create 8903 GEN_ID=1 GEN_STATE=failed GEN_FAILED_REASON='image checksum mismatch'

    run gen_transition 8903 active
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing invalid generation transition"* ]]
    [ "$(gen_state_of 8903)" = "failed" ]
}

@test "a rejected generation is terminal, so a rollback cannot be undone" {
    gen_create 8903 GEN_ID=9 GEN_STATE=active
    gen_transition 8903 rejected 'rolled back: jobs failing on 2.337.0'
    [ "$(gen_state_of 8903)" = "rejected" ]

    local to
    for to in baking candidate active superseded failed; do
        run gen_transition 8903 "$to"
        [ "$status" -eq 1 ]
        [ "$(gen_state_of 8903)" = "rejected" ]
    done
}

@test "an invalid transition writes nothing at all" {
    gen_create 8903 GEN_ID=1 GEN_STATE=failed
    local before
    before="$(cat "$GENERATIONS_DIR/8903.conf")"

    run gen_transition 8903 active
    [ "$status" -eq 1 ]
    [ "$(cat "$GENERATIONS_DIR/8903.conf")" = "$before" ]
}

@test "transitioning to the current state is a no-op, not a rewrite" {
    gen_create 8903 GEN_ID=1 GEN_STATE=candidate
    local before
    before="$(cat "$GENERATIONS_DIR/8903.conf")"

    run gen_transition 8903 candidate
    [ "$status" -eq 3 ]
    [ "$(cat "$GENERATIONS_DIR/8903.conf")" = "$before" ]
}

@test "transitioning to an unknown state is refused" {
    gen_create 8903 GEN_ID=1 GEN_STATE=candidate
    run gen_transition 8903 promoted
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid generation state"* ]]
    [ "$(gen_state_of 8903)" = "candidate" ]
}

@test "transitioning a record that does not exist fails" {
    run gen_transition 9999 active
    [ "$status" -eq 1 ]
}

@test "promotion stamps the promoted timestamp" {
    gen_create 8903 GEN_ID=1 GEN_STATE=candidate
    gen_transition 8903 active

    gen_read 8903
    [[ "$GEN_PROMOTED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
    [ "$GEN_SUPERSEDED_AT" = "" ]
}

@test "a rollback re-promotion refreshes the promoted timestamp" {
    gen_create 8903 GEN_ID=1 GEN_STATE=superseded GEN_PROMOTED_AT=2026-01-01T00:00:00Z
    gen_transition 8903 active

    gen_read 8903
    [ "$GEN_PROMOTED_AT" != "2026-01-01T00:00:00Z" ]
}

@test "supersession stamps the superseded timestamp" {
    gen_create 8903 GEN_ID=1 GEN_STATE=active
    gen_transition 8903 superseded

    gen_read 8903
    [[ "$GEN_SUPERSEDED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "a failure records its reason" {
    gen_create 8903 GEN_ID=1 GEN_STATE=baking
    gen_transition 8903 failed 'image checksum mismatch after retry'

    gen_read 8903
    [ "$GEN_STATE" = "failed" ]
    [ "$GEN_FAILED_REASON" = "image checksum mismatch after retry" ]
}

@test "a rejection records the operator reason and the time it left service" {
    gen_create 8903 GEN_ID=1 GEN_STATE=active
    gen_transition 8903 rejected 'rolled back by ops: playwright browsers missing'

    gen_read 8903
    [ "$GEN_STATE" = "rejected" ]
    [ "$GEN_FAILED_REASON" = "rolled back by ops: playwright browsers missing" ]
    [[ "$GEN_SUPERSEDED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# ---------------------------------------------------------------------------
# Atomicity
# ---------------------------------------------------------------------------

@test "a write killed part-way leaves the previous record intact" {
    gen_create 8903 GEN_ID=1 GEN_STATE=active GEN_RUNNER_VERSION=2.336.0
    local record="$GENERATIONS_DIR/8903.conf"
    local before
    before="$(cat "$record")"

    # Feed the writer through a fifo so the kill lands with the write started
    # and unfinished, deterministically rather than by timing.
    local fifo="$GEN_TEST_DIR/fifo"
    mkfifo "$fifo"
    gen_write_file_atomic "$record" < "$fifo" &
    local writer=$!
    exec 8>"$fifo"
    printf 'GEN_ID="99"\n' >&8

    # Wait until the write is under way: either it staged a temp file, or it has
    # already touched the record itself — which is the failure being tested for.
    local i
    for ((i = 0; i < 500; i++)); do
        compgen -G "$record".'*' > /dev/null && break
        [ "$(cat "$record")" != "$before" ] && break
        sleep 0.01
    done

    kill -9 "$writer" 2>/dev/null || true
    exec 8>&-
    wait "$writer" 2>/dev/null || true

    [ "$(cat "$record")" = "$before" ]
    gen_read 8903
    [ "$GEN_ID" = "1" ]
    [ "$GEN_RUNNER_VERSION" = "2.336.0" ]

    # The abandoned temp file is not a record: it can never be listed, read or
    # transitioned, and the next successful write replaces the real one.
    [ "$(gen_list)" = "8903" ]
}

@test "a partial record is never visible under the record name" {
    local record="$GENERATIONS_DIR/8903.conf"
    local fifo="$GEN_TEST_DIR/fifo"
    mkfifo "$fifo"
    gen_write_file_atomic "$record" < "$fifo" &
    local writer=$!
    exec 8>"$fifo"
    printf 'GEN_ID="99"\n' >&8

    local i
    for ((i = 0; i < 500; i++)); do
        compgen -G "$record".'*' > /dev/null && break
        sleep 0.01
    done

    [ ! -e "$record" ]

    kill -9 "$writer" 2>/dev/null || true
    exec 8>&-
    wait "$writer" 2>/dev/null || true

    [ ! -e "$record" ]
}

# ---------------------------------------------------------------------------
# Generation config defaults (lib/common.sh, applied by load_infra_config)
# ---------------------------------------------------------------------------

@test "generation config keys get their documented defaults" {
    apply_generation_defaults

    [ "$TEMPLATE_BAND_MIN" = "8900" ]
    [ "$TEMPLATE_BAND_MAX" = "8999" ]
    [ "$GENERATION_RETAIN" = "1" ]
    [ "$FAILED_GEN_RETAIN_DAYS" = "7" ]
    [ "$CANDIDATE_MAX_AGE_DAYS" = "3" ]
}

@test "a value already in the config file wins over the default" {
    TEMPLATE_BAND_MIN=8700
    FAILED_GEN_RETAIN_DAYS=14
    apply_generation_defaults

    [ "$TEMPLATE_BAND_MIN" = "8700" ]
    [ "$TEMPLATE_BAND_MAX" = "8999" ]
    [ "$FAILED_GEN_RETAIN_DAYS" = "14" ]
}

# ---------------------------------------------------------------------------
# Archive log
# ---------------------------------------------------------------------------

@test "an archive line has the documented shape" {
    gen_archive_append 6 8902 destroyed runner=2.335.0 age_days=34 reclaimed_gb=28

    run cat "$GENERATION_ARCHIVE_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ gen=6\ vmid=8902\ event=destroyed\ runner=2\.335\.0\ age_days=34\ reclaimed_gb=28$ ]]
}

@test "the archive log only ever grows" {
    gen_archive_append 6 8902 destroyed runner=2.335.0
    local first
    first="$(cat "$GENERATION_ARCHIVE_LOG")"
    gen_archive_append 7 8903 destroyed runner=2.336.0

    [ "$(wc -l < "$GENERATION_ARCHIVE_LOG" | tr -d ' ')" = "2" ]
    [ "$(head -n 1 "$GENERATION_ARCHIVE_LOG")" = "$first" ]
    [[ "$(tail -n 1 "$GENERATION_ARCHIVE_LOG")" == *"gen=7 vmid=8903"* ]]
}

@test "the archive log is created root-only" {
    gen_archive_append 6 8902 destroyed
    [ "$(file_mode "$GENERATION_ARCHIVE_LOG")" = "600" ]
}

@test "whitespace in an archive value cannot split a field" {
    gen_archive_append 6 8902 failed "reason=bake timed out
after 5400s"

    [ "$(wc -l < "$GENERATION_ARCHIVE_LOG" | tr -d ' ')" = "1" ]
    [[ "$(cat "$GENERATION_ARCHIVE_LOG")" == *"reason=bake_timed_out_after_5400s"* ]]
}

@test "the archive writer requires an event" {
    run gen_archive_append 6 8902
    [ "$status" -eq 1 ]
}
