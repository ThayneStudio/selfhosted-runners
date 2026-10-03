#!/bin/bash
# Runner slot recycling shared by reclone.sh (after a VM's post-stop hook)
# and watch.sh (every 30 s). Callers source common.sh first, and bake.sh for
# refill_runner_slot.
#
# Per-slot failure backoff, kept in /run so a reboot starts every slot fresh:
# - A failed clone_runner holds the slot for 30 s, doubling with each failure
#   in a row up to 30 min. A successful clone clears it.
# - reclone.sh, and the watcher for a stopped VM that nothing recycled, count
#   VMs that die within RAPID_DEATH_SECS of their clone.
#   Every RAPID_DEATH_LIMIT of those in a row leave the slot empty and hold
#   it, again doubling up to 30 min. A VM that lives longer clears the count,
#   and so does a clone whose JIT mint finds no runner of that name still on
#   GitHub: GitHub removes an ephemeral runner once it finishes a job, so the
#   fast death was a short job. A runner that never ran one (GitHub rejected
#   its version, the guest failed to start it) stays registered.
#   That mint, not the lifetime, tells a short job from a guest that never
#   ran one, so the window is wide: a refused or broken guest can take
#   minutes to give up after a slow boot or a long wait for its network.
# - Neither the watcher nor reclone.sh clones a held slot, so a slot that
#   fails every time stops minting a JIT runner on every tick.
set -euo pipefail

# Same directory as RUN_DIR in common.sh. Callers source common.sh first.
SLOT_STATE_DIR="${RUN_DIR:-/run/github-runners}"
# Per-slot lock taken by watch.sh, reclone.sh, create.sh and destroy.sh.
# slot-<name>.lock stays clear of runner-vmid.lock,
# runner-vmid-reserve-*.lock and runner-clone-slot-*.lock in this directory.
SLOT_LOCK_PREFIX="$SLOT_STATE_DIR/slot"
SLOT_BACKOFF_BASE=30
SLOT_BACKOFF_MAX=1800
RAPID_DEATH_SECS=600
RAPID_DEATH_LIMIT=3
# Extra runners from `runner create`, one "<name> <org>" line each. The
# watcher fills them like slots, so one that a hold, the template gate or a
# failed clone left empty comes back. Unlike the holds, it survives a reboot.
EXTRA_RUNNERS_FILE="/var/lib/github-runners/extras"
EXTRA_RUNNERS_LOCK_FILE="$SLOT_STATE_DIR/github-runner-extras.lock"

slot_lock_file() {
    printf '%s-%s.lock\n' "$SLOT_LOCK_PREFIX" "$1"
}

slot_state_file() {
    printf '%s/slot-%s\n' "$SLOT_STATE_DIR" "$1"
}

# Loads slot $1's state into SLOT_HOLD_UNTIL, SLOT_FAILURES, SLOT_RAPID and
# SLOT_DEFERRALS. A missing or garbled file reads as a healthy slot. The
# watcher reads without the slot lock, so the file can vanish mid-read.
slot_state_load() {
    local state key value
    SLOT_HOLD_UNTIL=0
    SLOT_FAILURES=0
    SLOT_RAPID=0
    SLOT_DEFERRALS=0
    state=$(cat "$(slot_state_file "$1")" 2>/dev/null) || return 0
    while IFS='=' read -r key value; do
        [[ "$value" =~ ^[0-9]{1,12}$ ]] || continue
        value=$((10#$value))
        case "$key" in
            hold_until) SLOT_HOLD_UNTIL=$value ;;
            failures) SLOT_FAILURES=$value ;;
            rapid) SLOT_RAPID=$value ;;
            deferrals) SLOT_DEFERRALS=$value ;;
        esac
    done <<< "$state"
}

# Writes the loaded state for slot $1. A healthy slot has no file.
slot_state_save() {
    local file tmp
    file=$(slot_state_file "$1")
    if (( SLOT_HOLD_UNTIL == 0 && SLOT_FAILURES == 0 && SLOT_RAPID == 0 && SLOT_DEFERRALS == 0 )); then
        rm -f "$file"
        return
    fi
    ensure_private_dir "$SLOT_STATE_DIR" || return 1
    tmp=$(mktemp "$SLOT_STATE_DIR/.slot.XXXXXX") || return 1
    if ! printf 'hold_until=%s\nfailures=%s\nrapid=%s\ndeferrals=%s\n' \
            "$SLOT_HOLD_UNTIL" "$SLOT_FAILURES" "$SLOT_RAPID" "$SLOT_DEFERRALS" > "$tmp" \
        || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}

# Forget every slot's failures, so each slot is tried again at once.
clear_slot_backoff() {
    rm -f "$SLOT_STATE_DIR"/slot-*
}

# Seconds to hold a slot after its Nth failure in a row: 30, 60 ... 1800.
slot_backoff_seconds() {
    local n="$1" secs="$SLOT_BACKOFF_BASE"
    while (( n > 1 && secs < SLOT_BACKOFF_MAX )); do
        secs=$((secs * 2))
        n=$((n - 1))
    done
    (( secs < SLOT_BACKOFF_MAX )) || secs=$SLOT_BACKOFF_MAX
    printf '%s\n' "$secs"
}

# 0 while slot $1 is held by the backoff, with the seconds left in
# SLOT_HOLD_LEFT. No hold is set for longer than SLOT_BACKOFF_MAX, so one
# that ends later was set before the clock was stepped back: it is over,
# instead of lasting the size of the step on top.
slot_is_held() {
    local now
    SLOT_HOLD_LEFT=0
    slot_state_load "$1"
    now=$(date +%s)
    (( SLOT_HOLD_UNTIL > now && SLOT_HOLD_UNTIL - now <= SLOT_BACKOFF_MAX )) || return 1
    SLOT_HOLD_LEFT=$((SLOT_HOLD_UNTIL - now))
}

slot_note_clone_failure() {
    local name="$1" hold
    slot_state_load "$name"
    SLOT_FAILURES=$((SLOT_FAILURES + 1))
    hold=$(slot_backoff_seconds "$SLOT_FAILURES")
    SLOT_HOLD_UNTIL=$(( $(date +%s) + hold ))
    slot_state_save "$name" || log_warn "Could not record the backoff for $name in $SLOT_STATE_DIR"
    log_warn "Holding $name for ${hold}s after $SLOT_FAILURES failed clone(s) in a row"
}

# Record a successful clone_runner for slot $1. $2 is clone_runner's
# CLONE_MINT_CONFLICT. Without a conflict the previous runner of this name
# finished a job, so a fast death before this clone was a short job, not a
# failure, and the fast-death count starts over.
slot_note_clone_success() {
    local name="$1" mint_conflict="${2:-1}"
    slot_state_load "$name"
    if [[ "$mint_conflict" == 0 ]]; then
        SLOT_RAPID=0
        SLOT_DEFERRALS=0
    fi
    SLOT_FAILURES=0
    SLOT_HOLD_UNTIL=0
    slot_state_save "$name" || log_warn "Could not clear the backoff for $name in $SLOT_STATE_DIR"
}

# Count the death of slot $1's VM, which lived $2 seconds. An empty or
# non-numeric lifetime (snippet gone) counts nothing. $3 prefixes the log
# line (default reclone:).
slot_note_death() {
    local name="$1" lifetime="$2" tag="${3:-reclone:}" hold
    [[ "$lifetime" =~ ^[0-9]+$ ]] || return 0
    slot_state_load "$name"
    if (( lifetime >= RAPID_DEATH_SECS )); then
        (( SLOT_RAPID > 0 || SLOT_DEFERRALS > 0 )) || return 0
        SLOT_RAPID=0
        SLOT_DEFERRALS=0
    else
        SLOT_RAPID=$((SLOT_RAPID + 1))
        if (( SLOT_RAPID >= RAPID_DEATH_LIMIT )); then
            SLOT_RAPID=0
            SLOT_DEFERRALS=$((SLOT_DEFERRALS + 1))
            hold=$(slot_backoff_seconds "$SLOT_DEFERRALS")
            SLOT_HOLD_UNTIL=$(( $(date +%s) + hold ))
            logger -t github-runner "$tag $name died within ${RAPID_DEATH_SECS}s of its clone $RAPID_DEATH_LIMIT times in a row; holding the slot for ${hold}s"
        fi
    fi
    slot_state_save "$name" || log_warn "Could not record the backoff for $name in $SLOT_STATE_DIR"
}

file_mtime() {
    stat -c %Y "$1" 2>/dev/null
}

# Seconds from when clone_runner wrote VM $1's meta snippet, which it does
# just before starting the VM, to epoch time $2. Prints nothing when the
# snippet is gone or is newer than $2.
runner_vm_lifetime() {
    local mtime end="${2:-}"
    [[ "$end" =~ ^[0-9]+$ ]] || return 0
    mtime=$(file_mtime "$SNIPPETS_DIR/runner-$1-meta.yaml") || return 0
    if [[ ! "$mtime" =~ ^[0-9]+$ ]] || (( mtime > end )); then
        return 0
    fi
    printf '%s\n' "$((end - mtime))"
}

# Seconds since clone_runner wrote VM $1's meta snippet. Prints nothing when
# the snippet is gone.
runner_vm_age() {
    runner_vm_lifetime "$1" "$(date +%s)"
}

# Sets ORG_SLOT_PREFIX and ORG_SLOT_COUNT for org $1, read the way the
# watcher reads them. ORG_SLOT_COUNT is empty when RUNNER_COUNT is missing or
# not a number.
read_org_slots() {
    local org_file="$ORG_CONFIG_DIR/$1.conf" count prefix
    count=$(grep '^RUNNER_COUNT=' "$org_file" 2>/dev/null | head -1 | sed 's/^RUNNER_COUNT=//' | tr -d '"') || true
    prefix=$(grep '^RUNNER_PREFIX=' "$org_file" 2>/dev/null | head -1 | sed 's/^RUNNER_PREFIX=//' | tr -d '"') || true
    ORG_SLOT_PREFIX="${prefix:-runner}"
    ORG_SLOT_COUNT=""
    if [[ "$count" =~ ^[0-9]{1,9}$ ]]; then
        ORG_SLOT_COUNT=$((10#$count))
    fi
}

# Prints the recorded extra runners, "<name> <org>" per line. A line without
# a valid runner name and org name is skipped.
list_extra_runners() {
    local name org rest
    [[ -e "$EXTRA_RUNNERS_FILE" ]] || return 0
    while read -r name org rest || [[ -n "$name" ]]; do
        if [[ -z "$rest" ]] && validate_runner_name "$name" && validate_org_name "$org"; then
            printf '%s %s\n' "$name" "$org"
        fi
    done < "$EXTRA_RUNNERS_FILE"
}

# Prints the org that extra runner $1 is recorded for. Fails when it is not
# recorded, or the list cannot be read.
extra_runner_org() {
    local list name org
    list=$(list_extra_runners) || return 1
    while read -r name org; do
        if [[ -n "$name" && "$name" == "$1" ]]; then
            printf '%s\n' "$org"
            return 0
        fi
    done <<< "$list"
    return 1
}

# 0 when extra runner $1 is recorded for org $2.
extra_runner_recorded() {
    local org
    org=$(extra_runner_org "$1") && [[ "$org" == "$2" ]]
}

# Replaces the extras list with the lines given; none removes it. The list is
# written beside the old one and renamed over it, so a failed write (ENOSPC)
# returns non-zero and leaves the old list. Callers hold the extras lock.
write_extra_runners() {
    local dir tmp
    if [[ $# -eq 0 ]]; then
        rm -f "$EXTRA_RUNNERS_FILE"
        return
    fi
    dir=$(dirname "$EXTRA_RUNNERS_FILE")
    install -d -m 700 "$dir" || return 1
    tmp=$(mktemp "$dir/.extras.XXXXXX") || return 1
    if ! printf '%s\n' "$@" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$EXTRA_RUNNERS_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

# Under the extras lock, drops the entries of name $1 and org $2 (an empty
# one matches any), then adds the line $3 when given. `runner create`,
# `runner destroy` and reclones can change the list at the same time.
update_extra_runners() {
    local drop_name="$1" drop_org="$2" add="${3:-}" list name org changed=0
    local -a kept=()
    prepare_lock_file "$EXTRA_RUNNERS_LOCK_FILE" || return 1
    (
        flock -w 30 205 || exit 1
        list=$(list_extra_runners) || exit 1
        while read -r name org; do
            [[ -n "$name" ]] || continue
            if [[ ( -z "$drop_name" || "$name" == "$drop_name" ) && ( -z "$drop_org" || "$org" == "$drop_org" ) ]]; then
                changed=1
                continue
            fi
            kept+=("$name $org")
        done <<< "$list"
        if [[ -n "$add" ]]; then
            kept+=("$add")
            changed=1
        fi
        [[ "$changed" == 1 ]] || exit 0
        write_extra_runners "${kept[@]}"
    ) 205> "$EXTRA_RUNNERS_LOCK_FILE"
}

# Records extra runner $1 of org $2, in place of any entry of that name.
record_extra_runner() {
    update_extra_runners "$1" "" "$1 $2"
}

# Forgets the extra runners of name $1 and org $2; an empty one matches any,
# but not both.
forget_extra_runners() {
    [[ -n "$1$2" ]] || return 1
    [[ -e "$EXTRA_RUNNERS_FILE" ]] || return 0
    update_extra_runners "$1" "$2"
}

# Forgets every extra runner.
forget_all_extra_runners() {
    [[ -e "$EXTRA_RUNNERS_FILE" ]] || return 0
    update_extra_runners "" ""
}

# Prints the kind clone_runner recorded in VM config text $1 (slot or
# extra). Prints nothing for VMs cloned before it was recorded.
runner_vm_kind() {
    local line kind_re='^description: selfhosted-runners org=[a-zA-Z0-9-]+ kind=(slot|extra)'
    line=$(grep -m1 '^description:' <<< "$1") || return 0
    if [[ "$line" =~ $kind_re ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

# 0 when runner $1 of org $2 must not be re-cloned, with the reason in
# RETIRE_REASON. $3 is the kind clone_runner recorded for it. The pool shrinks
# when the org was removed, when a VM cloned as one of the org's slots is no
# longer one (RUNNER_COUNT lowered or RUNNER_PREFIX changed), and when another
# org now uses the name as a slot. An extra runner from `runner create` keeps
# being re-cloned until `runner destroy`.
runner_slot_retired() {
    local name="$1" org="$2" kind="$3" other n
    RETIRE_REASON=""
    if [[ ! -f "$ORG_CONFIG_DIR/${org}.conf" ]]; then
        RETIRE_REASON="org $org is no longer configured"
        return 0
    fi
    read_org_slots "$org"
    # An unreadable RUNNER_COUNT must not look like "shrink to nothing".
    if [[ -n "$ORG_SLOT_COUNT" ]]; then
        n=$(slot_number "$name" "$ORG_SLOT_PREFIX") || n=""
        if [[ -n "$n" ]] && (( n <= ORG_SLOT_COUNT )); then
            return 1
        fi
        if [[ "$kind" == "slot" ]]; then
            RETIRE_REASON="it is no longer one of $org's $ORG_SLOT_COUNT slots named ${ORG_SLOT_PREFIX}-N"
            return 0
        fi
        # Cloned before the kind was recorded: a <prefix>-N past the count is
        # a slot that the count no longer covers.
        if [[ -z "$kind" && -n "$n" ]]; then
            RETIRE_REASON="it is beyond $org's RUNNER_COUNT ($ORG_SLOT_COUNT)"
            return 0
        fi
    fi
    while IFS= read -r other; do
        [[ -n "$other" && "$other" != "$org" ]] || continue
        read_org_slots "$other"
        [[ -n "$ORG_SLOT_COUNT" ]] || continue
        n=$(slot_number "$name" "$ORG_SLOT_PREFIX") || continue
        if (( n <= ORG_SLOT_COUNT )); then
            RETIRE_REASON="org $other now uses $name as a slot"
            return 0
        fi
    done < <(list_orgs)
    return 1
}

# Destroy runner VM $1, retrying while Proxmox may still hold its config lock
# from the stop, then remove its snippets. The snippets go only once the VM
# is gone: anything that starts the VM again (vzdump restarting it after a
# stop-mode backup) cannot start it without them.
destroy_runner_vm() {
    local vmid="$1" attempt output rc
    for attempt in 1 2 3; do
        output=$(qm destroy "$vmid" 200>&- 202>&- 2>&1) && rc=0 || rc=$?
        printf '%s\n' "$output" | logger -t github-runner || true
        if [[ $rc -eq 0 ]]; then
            rm -f "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" "${SNIPPETS_DIR}/runner-${vmid}-user-"*.yaml \
                "${SNIPPETS_DIR}/runner-${vmid}-vendor.yaml"
            return 0
        fi
        [[ $attempt -eq 3 ]] || sleep 2
    done
    return 1
}

# Clone the replacement for runner $1 of org $2 once its VM is destroyed. The
# caller holds the slot lock (fd 200) and shared pool activity (fd 202), $3
# prefixes the log lines and $4 is the old VM's kind (runner_vm_kind). Nothing
# is cloned for a retired name (runner_slot_retired), and the watcher no
# longer fills it as an extra runner. The slot stays empty while the backoff
# holds it, when the name is taken again, when the pool started draining or
# while TEMPLATE_ID is not a finished template; the watcher fills it, or the
# extra runner of that name, later. Returns 1 only when clone_runner failed.
# Needs template_is_converted from bake.sh.
refill_runner_slot() {
    local name="$1" org="$2" tag="$3" kind="${4:-}"
    if runner_slot_retired "$name" "$org" "$kind"; then
        log_info "$tag not re-cloning $name: $RETIRE_REASON"
        forget_extra_runners "$name" "$org" \
            || log_warn "$tag could not remove $name from $EXTRA_RUNNERS_FILE; the watcher may clone it again"
        return 0
    fi
    if slot_is_held "$name"; then
        logger -t github-runner "$tag $name is held for ${SLOT_HOLD_LEFT}s after repeated failures; the watcher refills it after that"
        return 0
    fi
    if qm list 200>&- 202>&- 2>/dev/null | awk 'NR>1{print $2}' | grep -qxF "$name"; then
        log_info "$tag $name already exists, skipping"
        return 0
    fi
    if pool_is_draining; then
        logger -t github-runner "$tag pool drain active after destroy for $name, leaving slot empty"
        return 0
    fi
    # The template is being rebuilt at TEMPLATE_ID (`qm destroy` and
    # `runner setup`), or was never converted. A clone of the unfinished VM
    # is a full copy, with no disk at all before the bake attaches one, and
    # holds a lock on the bake VM that can fail the bake. The watcher, which
    # waits for the same check, fills the slot once the template is done.
    if ! template_is_converted "$TEMPLATE_ID"; then
        log_warn "$tag template $TEMPLATE_ID is not a finished template; leaving $name empty for the watcher"
        return 0
    fi
    load_org_config "$org"
    if clone_runner "$name" "$org" >/dev/null; then
        slot_note_clone_success "$name" "${CLONE_MINT_CONFLICT:-1}"
        log_info "$tag re-cloned $name for org $org"
        return 0
    fi
    # A drain refuses the clone on purpose; that is not the slot failing.
    pool_is_draining || slot_note_clone_failure "$name"
    log_error "$tag failed to re-clone $name for org $org"
    return 1
}
