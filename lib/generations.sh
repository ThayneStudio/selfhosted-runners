#!/bin/bash
# Generation state store: one shell-sourceable record per baked template, the
# monotonic id counter that numbers them, the lifecycle state machine, and the
# append-only archive log.
#
# This is the data layer only. Nothing here runs qm/pvesm/zfs, reads the fleet,
# or decides policy — it just keeps the on-disk state consistent for the bake,
# canary, promotion, and GC code that sits on top of it.
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

# ---------------------------------------------------------------------------
# Predicates
# ---------------------------------------------------------------------------

gen_is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
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
    install -d -m 700 "$RUNNER_STATE_DIR" || return 1
    install -d -m 700 "$GENERATIONS_DIR" || return 1
}

gen_record_path() {
    printf '%s/%s.conf\n' "$GENERATIONS_DIR" "$1"
}

gen_exists() {
    [[ -f "$(gen_record_path "$1")" ]]
}

# Replace a file in one step: the temp file is created in the same directory so
# the rename cannot cross filesystems, and is chmod'd before it is moved so the
# final path is never briefly readable by anyone but root. A writer killed
# part-way through leaves the temp file behind and the destination untouched.
# Same pattern as lib/setup.sh:203-215. Content comes from stdin.
gen_write_file_atomic() {
    local dest="$1" tmp
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! mv "$tmp" "$dest"; then
        rm -f "$tmp"
        log_error "Failed to write $dest"
        return 1
    fi
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
# spaces because the reader is line-oriented; only GEN_FAILED_REASON is ever
# free text, and a reason spanning lines is not worth breaking the format for.
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

gen_unescape_value() {
    local raw="${1:-}" out=''
    if [[ ${#raw} -ge 2 && "${raw:0:1}" == '"' && "${raw: -1}" == '"' ]]; then
        raw="${raw:1:${#raw}-2}"
    fi
    while [[ -n "$raw" ]]; do
        if [[ "${raw:0:1}" == "\\" && ${#raw} -ge 2 ]]; then
            out+="${raw:1:1}"
            raw="${raw:2}"
        else
            out+="${raw:0:1}"
            raw="${raw:1}"
        fi
    done
    printf '%s' "$out"
}

gen_clear_fields() {
    local field
    for field in "${GENERATION_FIELDS[@]}"; do
        printf -v "$field" '%s' ''
    done
}

# Writes the GEN_* variables currently in scope to the record for <vmid>.
gen_serialize_record() {
    local vmid="$1" field
    gen_store_init || return 1
    {
        printf '# Generation record for VMID %s — managed by the runner platform.\n' "$vmid"
        for field in "${GENERATION_FIELDS[@]}"; do
            printf '%s=%s\n' "$field" "$(gen_escape_value "${!field:-}")"
        done
    } | gen_write_file_atomic "$(gen_record_path "$vmid")"
}

# Applies KEY=VALUE arguments onto the GEN_* variables in scope.
gen_apply_pairs() {
    local pair key
    for pair in "$@"; do
        if [[ ! "$pair" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            log_error "Expected KEY=VALUE, got: $pair"
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        if ! gen_is_field "$key"; then
            log_error "Unknown generation field: $key"
            return 1
        fi
        printf -v "$key" '%s' "${BASH_REMATCH[2]}"
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
# would. Every field is reset first, so a field absent from this record can
# never carry over a value from a record read earlier.
gen_read() {
    local vmid="${1:-}" path line key
    path=$(gen_record_path "$vmid")
    if [[ ! -f "$path" ]]; then
        log_error "No generation record for VMID $vmid"
        return 1
    fi

    gen_clear_fields
    while IFS= read -r line || [[ -n "$line" ]]; do
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
        printf -v "$key" '%s' "$(gen_unescape_value "${BASH_REMATCH[2]}")"
    done < "$path"
}

# Creates the record for a newly allocated generation.
# Usage: gen_create <vmid> [KEY=VALUE ...]
# GEN_ID defaults to the next counter value, GEN_STATE to baking, and
# GEN_CREATED_AT to now. Any state is accepted here because this is an initial
# state, not a transition — adoption (spec 8) creates its record directly in
# `active`. Every later state change goes through gen_transition.
gen_create() (
    local vmid="${1:-}"
    shift || true

    if ! gen_is_uint "$vmid"; then
        log_error "Invalid generation VMID: ${vmid:-<empty>}"
        return 1
    fi
    # A VMID is only free once its record has been archived and removed, so a
    # collision here means the allocator handed back a VMID still in service.
    if gen_exists "$vmid"; then
        log_error "Generation record for VMID $vmid already exists"
        return 1
    fi

    gen_clear_fields
    gen_apply_pairs "$@" || return 1

    [[ -n "$GEN_ID" ]] || GEN_ID=$(gen_next_id) || return 1
    [[ -n "$GEN_STATE" ]] || GEN_STATE=baking
    [[ -n "$GEN_CREATED_AT" ]] || GEN_CREATED_AT=$(gen_now)
    GEN_VMID="$vmid"

    if ! gen_is_state "$GEN_STATE"; then
        log_error "Invalid generation state: $GEN_STATE"
        return 1
    fi
    if ! gen_is_uint "$GEN_ID"; then
        log_error "Invalid generation id: $GEN_ID"
        return 1
    fi

    gen_serialize_record "$vmid"
)

# Updates provenance fields on an existing record.
# Usage: gen_update <vmid> [KEY=VALUE ...]
# GEN_STATE is deliberately not settable here: routing every state change
# through gen_transition is what makes the state machine enforceable.
gen_update() (
    local vmid="${1:-}" pair
    shift || true

    for pair in "$@"; do
        case "$pair" in
            GEN_STATE=*)
                log_error "GEN_STATE is not settable via gen_update — use gen_transition"
                return 1
                ;;
            GEN_VMID=*)
                log_error "GEN_VMID is fixed at creation and identifies the record"
                return 1
                ;;
        esac
    done

    gen_read "$vmid" || return 1
    gen_apply_pairs "$@" || return 1
    gen_serialize_record "$vmid"
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
    local vmid="${1:-}"
    gen_read "$vmid" || return 1
    if [[ "$GEN_STATE" == "active" ]]; then
        log_error "Refusing to remove the active generation record (VMID $vmid)"
        return 1
    fi
    rm -f "$(gen_record_path "$vmid")"
)

# Lists generation VMIDs, one per line, numerically sorted.
# Usage: gen_list [state]
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
            gen_read "$vmid" || continue
            [[ "$GEN_STATE" == "$state_filter" ]] || continue
        fi
        printf '%s\n' "$vmid"
    done | sort -n
)

# Resolves a generation id to its VMID. Clone attribution (spec 5) works the
# other way round — record first, id second — but the CLI takes ids, so the
# lookup is needed in both directions.
gen_vmid_for_id() (
    local target="${1:-}" vmid

    if ! gen_is_uint "$target"; then
        log_error "Invalid generation id: ${target:-<empty>}"
        return 1
    fi
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || continue
        if [[ "$GEN_ID" == "$target" ]]; then
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

# Highest id any surviving record carries, or 0. Used to reseed the counter.
gen_max_recorded_id() (
    local vmid max=0
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || continue
        gen_is_uint "$GEN_ID" || continue
        [[ "$GEN_ID" -gt "$max" ]] && max="$GEN_ID"
    done < <(gen_list)
    printf '%s\n' "$max"
)

# Current counter value: the highest id ever handed out.
#
# The counter is the source of ids, but it is not the only record of them. If
# it is lost or restored from an older copy, the ids already in use are still
# visible in the records themselves, so the maximum of the two is taken. Ids are
# never reused — including after a generation is destroyed — and handing a live
# id out a second time would corrupt clone attribution (spec 5).
gen_counter_value() {
    local value max
    if [[ -f "$GENERATION_COUNTER_FILE" ]]; then
        value=$(< "$GENERATION_COUNTER_FILE")
        value="${value//[[:space:]]/}"
        if ! gen_is_uint "$value"; then
            log_error "Generation counter $GENERATION_COUNTER_FILE is corrupt: '$value'"
            return 1
        fi
    else
        value=0
    fi

    max=$(gen_max_recorded_id) || return 1
    [[ "$max" -gt "$value" ]] && value="$max"
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
# Exit codes: 0 changed, 3 already in that state (nothing written), 1 rejected
# or failed. 3 is separate so an interrupted-and-retried pipeline stage can
# treat "already there" as success without weakening the check for everyone
# else.
#
# Usage: gen_transition <vmid> <state> [reason]
gen_transition() (
    local vmid="${1:-}" to="${2:-}" reason="${3:-}" now

    if ! gen_is_state "$to"; then
        log_error "Invalid generation state: ${to:-<empty>}"
        return 1
    fi
    gen_read "$vmid" || return 1

    if [[ "$GEN_STATE" == "$to" ]]; then
        return 3
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
            GEN_FAILED_REASON="$reason"
            ;;
        failed)
            GEN_FAILED_REASON="$reason"
            ;;
    esac
    GEN_STATE="$to"

    gen_serialize_record "$vmid"
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
# in July".
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

    gen_store_init || return 1
    line=$(printf '%s gen=%s vmid=%s event=%s' \
        "$(gen_now)" \
        "$(gen_archive_token "$gen_id")" \
        "$(gen_archive_token "$vmid")" \
        "$(gen_archive_token "$event")")
    for extra in "$@"; do
        line+=" $(gen_archive_token "$extra")"
    done

    # umask so the log is created root-only without a chmod race on every append.
    ( umask 077; printf '%s\n' "$line" >> "$GENERATION_ARCHIVE_LOG" )
}
