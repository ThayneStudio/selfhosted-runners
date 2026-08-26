#!/bin/bash
# Generation state store: one shell-sourceable record per baked template, the
# monotonic id counter that numbers them, the lifecycle state machine, and the
# append-only archive log.
#
# This is the data layer, plus adoption (spec 8). Record access, the state
# machine, the archive log, and generation VMID allocation never talk to the
# hypervisor. adopt_deployed_template is the exception: on an empty store it
# inventories the already-deployed TEMPLATE_ID fleet. It never destroys.
#
# Two rules hold everywhere below, because GEN_ID is the identity that clone
# attribution (spec 5), promotion, rollback and GC all key off:
#
#   * An id is issued once, ever. gen_next_id consults the counter, the live
#     records, and the archive log, so neither a destroyed generation nor a
#     restored-from-backup counter can hand a live id out a second time.
#   * A record that cannot be parsed is a hard error in every scan, never a
#     silently skipped entry. A skipped record is invisible to a maximum or a
#     uniqueness check, which is exactly how a duplicate id gets issued.
#
# GEN_* record fields are read back indirectly through ${!field}, and the
# mutating helpers below have deliberate subshell bodies, so shellcheck's
# unused-variable and lost-in-a-subshell heuristics do not apply here.
# shellcheck disable=SC2034,SC2030,SC2031
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

# Store-internal files, under the GENERATIONS_DIR that common.sh resolves.
GENERATION_COUNTER_FILE="$GENERATIONS_DIR/.counter"
GENERATION_COUNTER_LOCK_FILE="$GENERATIONS_DIR/.counter.lock"
GENERATION_ARCHIVE_LOG="$GENERATIONS_DIR/archive.log"

# Fields of a generation record, in the order they are written. The list is
# authoritative: a key outside it is rejected on write and ignored on read.
GENERATION_FIELDS=(
    GEN_ID
    GEN_VMID
    GEN_STATE
    GEN_RUNNER_VERSION
    GEN_IMAGE_SHA256
    GEN_TEMPLATE_DIGEST
    GEN_CREATED_AT
    GEN_PROMOTED_AT
    GEN_SUPERSEDED_AT
    GEN_FAILED_REASON
    GEN_BAKE_LOG
    GEN_CANARY_RUN_URL
    GEN_CANARY_ATTEMPTS
)

GENERATION_STATES=(baking candidate active superseded rejected failed)

# GEN_FAILED_REASON is the one free-text field, and spec 15 feeds it 40 lines of
# guest log on a bake timeout. Clip it: the record is an index, the bake log
# named in GEN_BAKE_LOG is the detail, and an unbounded value would slow every
# parse of the store while gen_next_id holds the counter lock.
GENERATION_REASON_MAX=512

# Abandoned staging files are reaped once they are older than this, which must
# stay comfortably above the longest legitimate write so a concurrent writer's
# temp file is never removed underneath it.
GENERATION_TEMP_REAP_MINUTES=60

# ---------------------------------------------------------------------------
# Predicates
# ---------------------------------------------------------------------------

# Bounded so a value stays inside the integer range arithmetic can compare.
gen_is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ && ${#1} -le 18 ]]
}

gen_is_state() {
    local state
    for state in "${GENERATION_STATES[@]}"; do
        [[ "${1:-}" == "$state" ]] && return 0
    done
    return 1
}

gen_is_field() {
    local field
    for field in "${GENERATION_FIELDS[@]}"; do
        [[ "${1:-}" == "$field" ]] && return 0
    done
    return 1
}

gen_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# Store layout
# ---------------------------------------------------------------------------

gen_store_init() {
    ensure_state_dir "$RUNNER_STATE_DIR" || return 1
    ensure_state_dir "$GENERATIONS_DIR" || return 1
    gen_reap_stale_temp_files
}

# A writer killed between mktemp and rename leaves its staging file behind.
# Those are invisible to the store (they do not match *.conf), but they are
# never claimed by anyone either, so sweep the old ones. Best-effort: failing to
# tidy up must never fail the write that triggered the sweep.
gen_reap_stale_temp_files() {
    find "$GENERATIONS_DIR" -maxdepth 1 -type f -name '*.conf.??????' \
        -mmin "+$GENERATION_TEMP_REAP_MINUTES" -delete 2>/dev/null || true
}

# Every path into the store goes through here, and it is the only place the
# VMID is turned into a filename. Validating here rather than in each caller is
# deliberate: gen_read, gen_update and gen_remove all take an operator-supplied
# identifier under spec 13, and an unvalidated one is a path traversal that
# reads, overwrites or deletes a file outside the store.
gen_record_path() {
    if ! gen_is_uint "${1:-}"; then
        log_error "Invalid generation VMID: ${1:-<empty>}"
        return 1
    fi
    printf '%s/%s.conf\n' "$GENERATIONS_DIR" "$1"
}

gen_exists() {
    local path
    path=$(gen_record_path "${1:-}") || return 1
    [[ -f "$path" ]]
}

# Replaces or creates a file in one step, with content from stdin.
#
# The temp file is created in the same directory so the rename cannot cross
# filesystems, and is chmod'd before it is published so the final path is never
# briefly readable by anyone but root. A writer killed part-way through leaves
# the temp file behind and the destination untouched.
#
# Mode `create` publishes with ln instead of mv: link fails with EEXIST rather
# than replacing, so two concurrent creators cannot both win, and — unlike an
# empty O_EXCL placeholder — what appears at the destination is already the
# complete record.
#
# Usage: gen_write_file_atomic <dest> [replace|create]
# Exit codes: 0 written, 1 write failed, 2 destination already exists (create).
gen_write_file_atomic() {
    local dest="$1" mode="${2:-replace}" tmp
    tmp=$(mktemp "${dest}.XXXXXX") || return 1

    if ! cat > "$tmp" || ! chmod 600 "$tmp"; then
        rm -f "$tmp"
        log_error "Failed to stage $dest"
        return 1
    fi
    # The rename is atomic for anything reading the file, but only an fsync
    # stops a host crash from exposing a zero-length record afterwards. Not
    # every sync(1) takes file arguments, so this is best-effort and is never
    # allowed to fail the write.
    sync "$tmp" 2>/dev/null || true

    if [[ "$mode" == "create" ]]; then
        if ! ln "$tmp" "$dest" 2>/dev/null; then
            rm -f "$tmp"
            return 2
        fi
        rm -f "$tmp"
    elif ! mv "$tmp" "$dest"; then
        rm -f "$tmp"
        log_error "Failed to write $dest"
        return 1
    fi

    sync "${dest%/*}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Record serialization
#
# Records are shell-sourceable KEY="value" files, matching the conf idiom used
# by /etc/github-runners.conf. They are *written* to be sourceable but are
# *read* with a strict line parser rather than `source`: parsing keeps a
# corrupt or hand-edited record from executing inside privileged code, and lets
# a bad record be reported instead of silently half-applied.
# ---------------------------------------------------------------------------

# Escapes a value for a double-quoted shell string. Newlines are folded to
# spaces because the reader is line-oriented; a value carrying one would
# otherwise write a record that no longer parses.
gen_escape_value() {
    local value="${1:-}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '"%s"' "$value"
}

# Inverse of gen_escape_value. Fails on a value that opens with a quote and
# never closes it, or whose closing quote is not the end of the value — a
# truncated or hand-mangled line, which must be reported rather than guessed at.
#
# Unquoted values are accepted verbatim: spec 4.3 writes its example record
# without quotes, and an adopted or hand-edited record may well look like that.
gen_unescape_value() {
    local raw="${1:-}" out='' chunk closed=0

    if [[ "${raw:0:1}" != '"' ]]; then
        printf '%s' "$raw"
        return 0
    fi
    raw="${raw:1}"

    # Copied in runs between escapes rather than character by character: a
    # clipped-but-still-long reason would otherwise cost quadratic time on
    # every parse of the store.
    while [[ -n "$raw" ]]; do
        # shellcheck disable=SC1003  # the '\' branch below matches a literal
        # backslash, which is exactly what an unescaper does — not a
        # mis-escaped single quote.
        case "$raw" in
            '\'*)
                [[ ${#raw} -ge 2 ]] || return 1
                out+="${raw:1:1}"
                raw="${raw:2}"
                ;;
            '"'*)
                [[ ${#raw} -eq 1 ]] || return 1
                closed=1
                raw=''
                ;;
            *)
                chunk="${raw%%[\\\"]*}"
                out+="$chunk"
                raw="${raw#"$chunk"}"
                ;;
        esac
    done

    [[ "$closed" -eq 1 ]] || return 1
    printf '%s' "$out"
}

gen_clear_fields() {
    local field
    for field in "${GENERATION_FIELDS[@]}"; do
        printf -v "$field" '%s' ''
    done
}

# Prints the numeric id of the record currently loaded into scope, or fails.
# Records are read leniently — values are not re-validated on the way in, so a
# hand-edited store can still be inspected — but anything that computes with an
# id has to insist on one, since a record whose id cannot be compared is a
# record that can silently drop out of a maximum or a uniqueness check.
gen_require_numeric_id() {
    local vmid="$1"
    if [[ -z "$GEN_ID" ]] || ! gen_is_uint "$GEN_ID"; then
        log_error "Generation record for VMID $vmid has an invalid GEN_ID: '${GEN_ID:-<empty>}'"
        return 1
    fi
    # 10# so a hand-written 08 is decimal eight rather than a base error.
    printf '%s\n' "$((10#$GEN_ID))"
}

gen_clip_reason() {
    local reason="${1:-}"
    if [[ ${#reason} -gt $GENERATION_REASON_MAX ]]; then
        printf '%s... (truncated)' "${reason:0:$GENERATION_REASON_MAX}"
    else
        printf '%s' "$reason"
    fi
}

# Per-field format rules, applied on the way in so garbage cannot reach the
# store at all. They also catch the caller that forgot to quote an argument:
# `gen_update 8903 "GEN_ID=1 GEN_STATE=active"` parses as one pair whose value
# contains whitespace, and every structured field here refuses that.
gen_validate_field() {
    local key="$1" value="$2"

    case "$key" in
        GEN_ID|GEN_VMID)
            if ! gen_is_uint "$value"; then
                log_error "$key must be a plain number, got: '$value'"
                return 1
            fi
            ;;
        GEN_CANARY_ATTEMPTS)
            if [[ -n "$value" ]] && ! gen_is_uint "$value"; then
                log_error "$key must be a plain number, got: '$value'"
                return 1
            fi
            ;;
        GEN_STATE)
            if ! gen_is_state "$value"; then
                log_error "Invalid generation state: '$value'"
                return 1
            fi
            ;;
        GEN_CREATED_AT|GEN_PROMOTED_AT|GEN_SUPERSEDED_AT)
            if [[ -n "$value" && ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
                log_error "$key must be UTC ISO 8601 (YYYY-MM-DDTHH:MM:SSZ), got: '$value'"
                return 1
            fi
            ;;
        GEN_RUNNER_VERSION|GEN_IMAGE_SHA256|GEN_TEMPLATE_DIGEST|GEN_BAKE_LOG|GEN_CANARY_RUN_URL)
            if [[ "$value" =~ [[:space:]] ]]; then
                log_error "$key is a single token and must not contain whitespace: '$value'"
                return 1
            fi
            ;;
        GEN_FAILED_REASON)
            # Free text by design; clipped on assignment, not rejected.
            ;;
    esac
}

# Writes the GEN_* variables currently in scope to the record for <vmid>.
# Usage: gen_serialize_record <vmid> [replace|create]
gen_serialize_record() {
    local vmid="$1" mode="${2:-replace}" path field
    path=$(gen_record_path "$vmid") || return 1
    gen_store_init || return 1
    {
        printf '# Generation record for VMID %s — managed by the runner platform.\n' "$vmid"
        for field in "${GENERATION_FIELDS[@]}"; do
            printf '%s=%s\n' "$field" "$(gen_escape_value "${!field:-}")"
        done
    } | gen_write_file_atomic "$path" "$mode"
}

# Applies KEY=VALUE arguments onto the GEN_* variables in scope.
gen_apply_pairs() {
    local pair key value
    for pair in "$@"; do
        if [[ ! "$pair" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            log_error "Expected KEY=VALUE, got: $pair"
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if ! gen_is_field "$key"; then
            log_error "Unknown generation field: $key"
            return 1
        fi
        gen_validate_field "$key" "$value" || return 1
        if [[ "$key" == "GEN_FAILED_REASON" ]]; then
            value=$(gen_clip_reason "$value")
        fi
        printf -v "$key" '%s' "$value"
    done
}

# ---------------------------------------------------------------------------
# Record access
#
# The mutating helpers have subshell bodies — `name() ( ... )` — so the GEN_*
# variables they set up internally cannot leak into the caller's scope. Only
# gen_read publishes into the caller, which is the whole point of it.
# ---------------------------------------------------------------------------

# Loads a record into GEN_* variables in the caller's scope, as sourcing it
# would. Every field is cleared first — including when the read then fails — so
# a caller can never end up holding fields from a record it read earlier.
gen_read() {
    local vmid="${1:-}" path line key value

    gen_clear_fields
    path=$(gen_record_path "$vmid") || return 1
    if [[ ! -f "$path" ]]; then
        log_error "No generation record for VMID $vmid"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ -z "${line//[[:space:]]/}" || "${line:0:1}" == '#' ]]; then
            continue
        fi
        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            log_error "Malformed line in $path: $line"
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        if ! gen_is_field "$key"; then
            log_warn "Ignoring unknown field $key in $path"
            continue
        fi
        if ! value=$(gen_unescape_value "${BASH_REMATCH[2]}"); then
            log_error "Malformed value for $key in $path: ${BASH_REMATCH[2]}"
            return 1
        fi
        printf -v "$key" '%s' "$value"
    done < "$path"
}

# Whether a generation id has ever been issued: to a live record, or to one that
# has since been destroyed and archived. Spec 4.3 forbids reuse in both cases.
#
# Exit codes: 0 issued (owning VMID on stdout, or "archived"), 1 free,
# 2 the store could not be read — in which case uniqueness is unknown, and the
# caller must treat that as a refusal rather than as "free".
gen_id_already_issued() (
    local target="${1:-}" vmid id

    # Also keeps the archive-log grep below a fixed pattern rather than
    # whatever a caller passed in.
    if ! gen_is_uint "$target"; then
        log_error "Invalid generation id: ${target:-<empty>}"
        return 2
    fi

    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || return 2
        id=$(gen_require_numeric_id "$vmid") || return 2
        if [[ "$id" -eq "$((10#$target))" ]]; then
            printf '%s\n' "$vmid"
            return 0
        fi
    done < <(gen_list)

    if [[ -f "$GENERATION_ARCHIVE_LOG" ]] &&
        grep -qE "(^| )gen=0*${target}( |$)" "$GENERATION_ARCHIVE_LOG"; then
        printf 'archived\n'
        return 0
    fi
    return 1
)

# Creates the record for a newly allocated generation.
# Usage: gen_create <vmid> [KEY=VALUE ...]
#
# GEN_ID defaults to the next counter value, GEN_STATE to baking, and
# GEN_CREATED_AT to now. Any state is accepted here because this is an initial
# state, not a transition — adoption (spec 8) creates its record directly in
# `active`. Every later state change goes through gen_transition.
#
# Exit codes: 0 created, 1 refused (bad input, VMID or id already taken),
# 4 the record could not be written.
gen_create() (
    local vmid="${1:-}" owner rc=0
    shift || true

    gen_is_uint "$vmid" || { log_error "Invalid generation VMID: ${vmid:-<empty>}"; return 1; }
    # A VMID is only free once its record has been archived and removed, so a
    # collision here means the allocator handed back a VMID still in service.
    # This is the early, legible refusal; the exclusive create below is what
    # actually makes it race-free.
    if gen_exists "$vmid"; then
        log_error "Generation record for VMID $vmid already exists"
        return 1
    fi

    gen_clear_fields
    gen_apply_pairs "$@" || return 1

    if [[ -n "$GEN_ID" ]]; then
        # An explicitly supplied id — adoption, or a repair — must still be one
        # that has never been issued, or two records claim one identity and
        # every consumer that resolves an id to a VMID picks arbitrarily.
        owner=$(gen_id_already_issued "$GEN_ID") || rc=$?
        case "$rc" in
            0)
                log_error "Generation id $GEN_ID is already issued (to $owner)"
                return 1
                ;;
            2)
                log_error "Cannot verify generation id $GEN_ID is unused — refusing to create"
                return 1
                ;;
        esac
    else
        GEN_ID=$(gen_next_id) || return 1
    fi

    [[ -n "$GEN_STATE" ]] || GEN_STATE=baking
    [[ -n "$GEN_CREATED_AT" ]] || GEN_CREATED_AT=$(gen_now)
    GEN_VMID="$vmid"

    rc=0
    gen_serialize_record "$vmid" create || rc=$?
    case "$rc" in
        0) return 0 ;;
        2)
            log_error "Generation record for VMID $vmid already exists"
            return 1
            ;;
        *) return 4 ;;
    esac
)

# Updates provenance fields on an existing record.
# Usage: gen_update <vmid> [KEY=VALUE ...]
#
# GEN_STATE, GEN_ID and GEN_VMID are all refused here. The first because
# routing every state change through gen_transition is what makes the state
# machine enforceable; the other two because they are the record's identity,
# and a store where identity is mutable cannot answer "which generation is this
# clone from" reliably.
#
# Exit codes: 0 updated, 1 refused, 4 the record could not be written.
gen_update() (
    local vmid="${1:-}" pair rc=0
    shift || true

    for pair in "$@"; do
        case "$pair" in
            GEN_STATE=*)
                log_error "GEN_STATE is not settable via gen_update — use gen_transition"
                return 1
                ;;
            GEN_ID=*|GEN_VMID=*)
                log_error "${pair%%=*} is the record's identity and is fixed at creation"
                return 1
                ;;
        esac
    done

    gen_read "$vmid" || return 1
    gen_apply_pairs "$@" || return 1

    gen_serialize_record "$vmid" || rc=$?
    [[ "$rc" -eq 0 ]] || return 4
)

gen_state_of() (
    gen_read "${1:-}" || return 1
    printf '%s\n' "$GEN_STATE"
)

# Removes a record. The caller is responsible for having destroyed the template
# and appended to the archive log first (spec 9): a record removed while its
# storage is still around orphans that storage outside the generation model,
# where nothing will ever reclaim it.
gen_remove() (
    local vmid="${1:-}" path
    gen_read "$vmid" || return 1
    if [[ "$GEN_STATE" == "active" ]]; then
        log_error "Refusing to remove the active generation record (VMID $vmid)"
        return 1
    fi
    path=$(gen_record_path "$vmid") || return 1
    rm -f "$path"
)

# Lists generation VMIDs, one per line, numerically sorted.
# Usage: gen_list [state]
#
# Filtering has to read every record, and an unreadable one is fatal rather than
# skipped: a caller asking for `superseded` is about to decide what to destroy,
# and a silently short list is the dangerous answer, not the safe one.
gen_list() (
    local state_filter="${1:-}" path vmid

    if [[ -n "$state_filter" ]] && ! gen_is_state "$state_filter"; then
        log_error "Invalid generation state: $state_filter"
        return 1
    fi
    [[ -d "$GENERATIONS_DIR" ]] || return 0

    for path in "$GENERATIONS_DIR"/*.conf; do
        [[ -f "$path" ]] || continue
        vmid=$(basename "$path" .conf)
        gen_is_uint "$vmid" || continue
        if [[ -n "$state_filter" ]]; then
            gen_read "$vmid" || return 1
            [[ "$GEN_STATE" == "$state_filter" ]] || continue
        fi
        printf '%s\n' "$vmid"
    done | sort -n
)

# Resolves a generation id to its VMID. Clone attribution (spec 5) works the
# other way round — record first, id second — but the CLI takes ids, so the
# lookup is needed in both directions.
gen_vmid_for_id() (
    local target="${1:-}" vmid id

    if ! gen_is_uint "$target"; then
        log_error "Invalid generation id: ${target:-<empty>}"
        return 1
    fi
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || return 1
        id=$(gen_require_numeric_id "$vmid") || return 1
        if [[ "$id" -eq "$((10#$target))" ]]; then
            printf '%s\n' "$vmid"
            return 0
        fi
    done < <(gen_list)

    log_error "No generation with id $target"
    return 1
)

# ---------------------------------------------------------------------------
# Generation id counter
# ---------------------------------------------------------------------------

# Highest id any surviving record carries, or 0.
#
# An unreadable record fails the whole computation. Skipping it would drop its
# id out of the maximum, and the next allocation would hand that live id to a
# new generation.
gen_max_recorded_id() (
    local vmid id max=0
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || return 1
        id=$(gen_require_numeric_id "$vmid") || return 1
        [[ "$id" -gt "$max" ]] && max="$id"
    done < <(gen_list)
    printf '%s\n' "$max"
)

# Highest id in the archive log, or 0. Destroyed generations leave no record
# behind, so this is the only surviving evidence that their ids were issued.
gen_max_archived_id() {
    local max
    [[ -f "$GENERATION_ARCHIVE_LOG" ]] || { printf '0\n'; return 0; }
    max=$(sed -n 's/.*[[:space:]]gen=\([0-9][0-9]*\).*/\1/p' "$GENERATION_ARCHIVE_LOG" |
        sort -n | tail -n 1)
    gen_is_uint "${max:-}" || max=0
    printf '%s\n' "$((10#$max))"
}

# Current counter value: the highest id ever issued.
#
# The counter is the source of ids, but it is not the only evidence of them. If
# it is lost, or restored from an older copy, the ids already issued are still
# visible in the live records and — for generations that have since been
# destroyed — in the archive log. The maximum of all three is taken, because an
# id issued twice corrupts clone attribution (spec 5) and can point a promotion
# or a rollback at the wrong VMID.
gen_counter_value() {
    local value recorded archived
    if [[ -f "$GENERATION_COUNTER_FILE" ]]; then
        value=$(< "$GENERATION_COUNTER_FILE")
        value="${value//[[:space:]]/}"
        if ! gen_is_uint "$value"; then
            log_error "Generation counter $GENERATION_COUNTER_FILE is corrupt: '$value'"
            return 1
        fi
        value=$((10#$value))
    else
        value=0
    fi

    recorded=$(gen_max_recorded_id) || return 1
    archived=$(gen_max_archived_id) || return 1
    [[ "$recorded" -gt "$value" ]] && value="$recorded"
    [[ "$archived" -gt "$value" ]] && value="$archived"
    printf '%s\n' "$value"
}

# Allocates the next generation id.
#
# flock serializes the read-modify-write so two bakes racing here cannot be
# handed the same id. The lock lives on its own file rather than on .counter,
# because the counter itself is replaced by rename and a lock held on the old
# inode would stop serializing anything.
gen_next_id() (
    local current next
    gen_store_init || return 1

    umask 077
    exec 205>"$GENERATION_COUNTER_LOCK_FILE"
    if ! flock -w 30 205; then
        log_error "Timed out acquiring the generation counter lock"
        return 1
    fi

    current=$(gen_counter_value) || return 1
    next=$((current + 1))
    printf '%s\n' "$next" | gen_write_file_atomic "$GENERATION_COUNTER_FILE" || return 1
    printf '%s\n' "$next"
)

# ---------------------------------------------------------------------------
# State machine (spec 4.1)
#
#   baking ──▶ candidate ──▶ active ──▶ superseded ──▶ (destroyed, archived)
#      │           │            │            │
#      │           │            │            └──▶ active     (rollback)
#      └──▶ failed ┘            └──▶ rejected
#
# `failed` and `rejected` have no outgoing edges, and that is load-bearing for
# `rejected` in particular: it is where an operator rollback leaves the image it
# rolled away from. Reconciliation resolves a split-brain "two actives" by
# promotion time rather than by highest id precisely so a rollback is not undone
# (spec 7.3, 15), and a terminal `rejected` closes the same hole in the store —
# nothing can walk a rejected generation back to active, whatever heuristic it
# applies. Retention likewise never keeps one as a rollback target.
# ---------------------------------------------------------------------------

gen_transition_allowed() {
    local from="${1:-}" to="${2:-}"

    gen_is_state "$from" || return 1
    gen_is_state "$to" || return 1

    case "$from:$to" in
        # Bake finished, or died trying.
        baking:candidate|baking:failed) return 0 ;;
        # Promotion, GC of an orphaned candidate, or a canary that ran out of
        # attempts.
        candidate:active|candidate:superseded|candidate:failed) return 0 ;;
        # A newer generation took over, or an operator rolled away from this one.
        active:superseded|active:rejected) return 0 ;;
        # Rollback: the retained previous generation becomes the clone target
        # again.
        superseded:active) return 0 ;;
        *) return 1 ;;
    esac
}

# Moves a generation to a new state, refusing anything the machine does not
# allow. Timestamps are stamped here so no caller can forget them.
#
# Usage: gen_transition <vmid> <state> [reason]
# Exit codes: 0 the generation is now in that state, 1 refused (invalid edge,
# bad input, missing record), 4 the record could not be written.
#
# A generation already in the requested state is a success, not a distinct
# code: every consumer of this library runs under `set -e`, so any non-zero
# return from the ordinary idempotent-retry path — `maintain` re-running a
# stage it already completed — would abort the caller outright. Callers that
# need to know whether anything moved read gen_state_of first. The separate
# code 4 exists so a promotion can tell a policy refusal from a failed write
# before it rewrites TEMPLATE_ID (spec 7.3).
gen_transition() (
    local vmid="${1:-}" to="${2:-}" reason="${3:-}" now rc=0

    if ! gen_is_state "$to"; then
        log_error "Invalid generation state: ${to:-<empty>}"
        return 1
    fi
    gen_read "$vmid" || return 1

    if [[ "$GEN_STATE" == "$to" ]]; then
        log_info "Generation VMID $vmid is already $to — nothing to do"
        return 0
    fi
    if ! gen_transition_allowed "$GEN_STATE" "$to"; then
        log_error "Refusing invalid generation transition for VMID $vmid: $GEN_STATE -> $to"
        return 1
    fi

    now=$(gen_now)
    case "$to" in
        active)
            # Overwritten on a re-promotion, so reconciliation's "newest
            # GEN_PROMOTED_AT wins" tiebreak reflects the latest promotion.
            GEN_PROMOTED_AT="$now"
            ;;
        superseded)
            GEN_SUPERSEDED_AT="$now"
            ;;
        rejected)
            # A rejected generation left active service, so it carries the same
            # timestamp a demotion would, and the operator's reason reuses
            # GEN_FAILED_REASON rather than adding a field (spec 4.3).
            GEN_SUPERSEDED_AT="$now"
            [[ -z "$reason" ]] || GEN_FAILED_REASON=$(gen_clip_reason "$reason")
            ;;
        failed)
            # Only when given: a bare retry must not erase a detail an earlier
            # gen_update recorded.
            [[ -z "$reason" ]] || GEN_FAILED_REASON=$(gen_clip_reason "$reason")
            ;;
    esac
    GEN_STATE="$to"

    gen_serialize_record "$vmid" || rc=$?
    [[ "$rc" -eq 0 ]] || return 4
)

# ---------------------------------------------------------------------------
# Archive log (spec 4.4)
# ---------------------------------------------------------------------------

# Fields are whitespace-separated key=value, so a value containing whitespace
# would silently become two fields. Fold it instead of dropping the line.
gen_archive_token() {
    local token="${1:-}"
    token="${token//[[:space:]]/_}"
    printf '%s' "$token"
}

# Appends one terminal-event line, for post-hoc questions like "what did we run
# in July" — and, since a destroyed generation leaves no record behind, as the
# only lasting evidence that its id was ever issued (see gen_counter_value).
#
# Usage: gen_archive_append <gen_id> <vmid> <event> [key=value ...]
# Example line:
#   2026-08-22T04:11:07Z gen=6 vmid=8902 event=destroyed runner=2.335.0 age_days=34
#
# No lock: the log is opened O_APPEND and each line is a single write well under
# PIPE_BUF, so concurrent appenders interleave whole lines rather than corrupt
# them. Spec 4.4 keeps new shared state and its locking off this path.
gen_archive_append() {
    local gen_id="${1:-}" vmid="${2:-}" event="${3:-}" line extra
    shift 3 2>/dev/null || {
        log_error "gen_archive_append requires <gen_id> <vmid> <event>"
        return 1
    }
    if ! gen_is_uint "$gen_id"; then
        log_error "Invalid generation id for the archive log: '${gen_id:-<empty>}'"
        return 1
    fi

    gen_store_init || return 1
    line=$(printf '%s gen=%s vmid=%s event=%s' \
        "$(gen_now)" \
        "$gen_id" \
        "$(gen_archive_token "$vmid")" \
        "$(gen_archive_token "$event")")
    for extra in "$@"; do
        line+=" $(gen_archive_token "$extra")"
    done

    # umask so the log is created root-only without a chmod race on every append.
    ( umask 077; printf '%s\n' "$line" >> "$GENERATION_ARCHIVE_LOG" )
}

# ---------------------------------------------------------------------------
# Generation VMID allocation (spec 4.2)
#
# Newly baked generations take the lowest free VMID in TEMPLATE_BAND_MIN..MAX.
# This is a different pool from reserve_vmid / VMID_LOCK_FILE; taking that lock
# would serialize template allocation against clone allocation. Proven by
# "allocate_generation_vmid returns the lowest free band VMID".
#
# A config in the band that is not a generation record is a hard error, not a
# hole to skip — otherwise a leftover VM is silently stranded next to templates
# and the next bake still proceeds. Proven by "foreign config inside the band
# is a hard error before allocation".
#
# flock -n on GENERATION_VMID_LOCK_FILE fd 206 serializes the scan. The
# function is not a subshell so the caller can keep the lock held while it
# gen_create's the record; command substitution still works because exclusive
# create is the race-free backstop. Proven by "allocate_generation_vmid is busy
# when the generation VMID lock is held".
# ---------------------------------------------------------------------------

# Walks the band and refuses any VMID whose qemu-server config exists without a
# matching generation record. Not called from load_infra_config: config load
# must stay qm-free (and this probe is the file equivalent of that inventory).
validate_band_inventory() {
    local vmid
    for vmid in $(seq "$TEMPLATE_BAND_MIN" "$TEMPLATE_BAND_MAX"); do
        if vmid_in_use "$vmid" && ! gen_exists "$vmid"; then
            log_error "VMID $vmid has a config in the generation band ${TEMPLATE_BAND_MIN}-${TEMPLATE_BAND_MAX} but is not a known generation"
            return 1
        fi
    done
    return 0
}

# Lowest free band VMID on stdout. Exit 1 if the band is exhausted, invalid, or
# contains a foreign config, or if another allocator holds the lock.
allocate_generation_vmid() {
    local vmid

    validate_generation_band || return 1
    validate_band_inventory || return 1

    exec 206>"$GENERATION_VMID_LOCK_FILE"
    if ! flock -n 206; then
        log_error "generation VMID allocator is busy"
        return 1
    fi

    for vmid in $(seq "$TEMPLATE_BAND_MIN" "$TEMPLATE_BAND_MAX"); do
        if ! vmid_in_use "$vmid" && ! gen_exists "$vmid"; then
            printf '%s\n' "$vmid"
            return 0
        fi
    done
    log_error "generation VMID band ${TEMPLATE_BAND_MIN}-${TEMPLATE_BAND_MAX} is exhausted"
    return 1
}

# ---------------------------------------------------------------------------
# Adoption (spec 8)
#
# Empty store + existing TEMPLATE_ID → generation 1, active, unknown digest
# and image sha. Idempotent: any live record and a missing template are both
# success. Never destroys. Tags untagged runner clones gen-1.
#
# Inventory is `qm list` plus per-VM `qm config`, matching lib/guard.sh and
# lib/list.sh — not `qm list --full`.
# ---------------------------------------------------------------------------

# True when any tag already attributes the VM to a generation.
adopt_tags_have_gen() {
    local current="${1:-}" tag
    local -a tags=()
    IFS=';,' read -ra tags <<< "$current"
    for tag in "${tags[@]}"; do
        tag="${tag//[[:space:]]/}"
        [[ "$tag" == gen-* ]] && return 0
    done
    return 1
}

# Comma-separated tags for `qm set --tags`: keep existing, ensure runner, append gen-1.
adopt_tags_with_gen1() {
    local current="${1:-}" tag has_runner=0
    local -a kept=() out=()
    IFS=';,' read -ra kept <<< "$current"
    local -a existing=()
    for tag in "${kept[@]}"; do
        tag="${tag//[[:space:]]/}"
        [[ -n "$tag" ]] || continue
        [[ "$tag" == "gen-1" ]] && continue
        if [[ "$tag" == "runner" ]]; then
            has_runner=1
        fi
        existing+=("$tag")
    done
    if [[ "$has_runner" -eq 1 ]]; then
        out=("${existing[@]}" "gen-1")
    else
        out=("runner" "${existing[@]}" "gen-1")
    fi
    local IFS=','
    printf '%s' "${out[*]}"
}

# Clone VMIDs whose disk traces to TEMPLATE_ID (nested volid or ZFS origin).
# Empty when origin cannot be resolved — skip unattributable rather than
# tagging every runner cicustom.
adopt_linked_clone_vmids() {
    local child_list volid child
    child_list=$(list_template_linked_clone_volids) || return 0
    [[ -n "$child_list" ]] || return 0
    while read -r volid; do
        [[ -n "$volid" ]] || continue
        child=$(linked_clone_child_vmid "$volid")
        [[ -n "$child" ]] || continue
        printf '%s\n' "$child"
    done <<< "$child_list"
}

# Best-effort probe of a running clone. Always prints a token (never fails).
# Parses qm guest exec JSON by hand so unit tests do not need a jq stub.
adopt_probe_runner_version() {
    local vmid="$1" result raw
    result=$(qm guest exec "$vmid" -- \
        /home/runner/actions-runner/bin/Runner.Listener --version \
        2>/dev/null </dev/null) || {
        printf 'unknown\n'
        return 0
    }
    if [[ "$result" =~ \"out-data\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        raw="${BASH_REMATCH[1]}"
        raw="${raw//\\n/ }"
        raw="${raw//\\r/ }"
        raw="${raw//\\t/ }"
    else
        raw="$result"
    fi
    raw="${raw//$'\n'/ }"
    raw="${raw//$'\r'/ }"
    if [[ "$raw" =~ ([0-9]+\.[0-9]+([.][0-9]+)*) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf 'unknown\n'
}

# Adopt the deployed TEMPLATE_ID template as generation 1.
# Usage: adopt_deployed_template
# Exit: always 0 except when gen_create refuses a write after deciding to adopt.
adopt_deployed_template() {
    local min_vmid probed=unknown
    local all_vms vmid vm_name status cfg tags_line new_tags rec list resume=0
    local linked
    local -a tag_vmids=() tag_values=() recs=()
    local -A traced=()

    list=$(gen_list) || return 1
    if [[ -n "$list" ]]; then
        while read -r rec; do
            [[ -n "$rec" ]] || continue
            recs+=("$rec")
        done <<< "$list"
        if ((${#recs[@]} == 1)); then
            gen_read "${recs[0]}" || return 1
            if [[ "$GEN_ID" == "1" && "$GEN_VMID" == "${TEMPLATE_ID:-}" ]]; then
                resume=1
            else
                log_info "Generation store already has records — skipping adoption"
                return 0
            fi
        else
            log_info "Generation store already has records — skipping adoption"
            return 0
        fi
    fi

    if [[ -z "${TEMPLATE_ID:-}" ]]; then
        log_warn "TEMPLATE_ID is not set — nothing to adopt"
        return 0
    fi

    if ! qm status "$TEMPLATE_ID" >/dev/null 2>&1 </dev/null; then
        log_warn "Template VM $TEMPLATE_ID is not present — nothing to adopt"
        return 0
    fi

    if ! qm config "$TEMPLATE_ID" 2>/dev/null </dev/null | grep -q '^template:[[:space:]]*1'; then
        log_warn "TEMPLATE_ID $TEMPLATE_ID is not a Proxmox template — nothing to adopt"
        return 0
    fi

    min_vmid="${MIN_VMID:-}"
    if [[ ! "$min_vmid" =~ ^[0-9]+$ ]]; then
        min_vmid=$((TEMPLATE_ID + 1))
    fi

    linked=$(adopt_linked_clone_vmids) || linked=""
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        traced["$vmid"]=1
    done <<< "$linked"

    if ((${#traced[@]} > 0)); then
        all_vms=$(qm list 2>/dev/null </dev/null) || all_vms=""
        while read -r vmid vm_name status _; do
            [[ "$vmid" =~ ^[0-9]+$ ]] || continue
            [[ "$vmid" != "$TEMPLATE_ID" ]] || continue
            [[ "$vmid" -ge "$min_vmid" ]] || continue
            [[ -n "${traced[$vmid]:-}" ]] || continue

            cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || continue
            [[ -n "$cfg" ]] || continue
            if grep -q '^template:[[:space:]]*1' <<< "$cfg"; then
                continue
            fi
            tags_line=$(grep -m1 '^tags:' <<< "$cfg" || true)
            tags_line="${tags_line#tags:}"
            if adopt_tags_have_gen "$tags_line"; then
                continue
            fi
            if [[ "$status" == "running" && "$probed" == "unknown" ]]; then
                probed=$(adopt_probe_runner_version "$vmid")
            fi
            tag_vmids+=("$vmid")
            tag_values+=("$tags_line")
        done <<< "$(tail -n +2 <<< "$all_vms")"
    fi

    if [[ "$resume" -eq 0 ]]; then
        gen_create "$TEMPLATE_ID" \
            GEN_ID=1 \
            GEN_STATE=active \
            GEN_RUNNER_VERSION="${probed:-unknown}" \
            GEN_IMAGE_SHA256=unknown \
            GEN_TEMPLATE_DIGEST=unknown || return 1
        log_info "Adopted template VMID $TEMPLATE_ID as generation 1"
    fi

    if [[ ${#tag_vmids[@]} -gt 0 ]]; then
        local i
        for i in "${!tag_vmids[@]}"; do
            new_tags=$(adopt_tags_with_gen1 "${tag_values[$i]}")
            if ! qm set "${tag_vmids[$i]}" --tags "$new_tags" </dev/null; then
                log_warn "Failed to tag VMID ${tag_vmids[$i]} as gen-1"
            fi
        done
    fi

    return 0
}
