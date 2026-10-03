#!/bin/bash
# Runner slot recycling shared by reclone.sh (after a VM's post-stop hook)
# and watch.sh (every 30 s). Callers source common.sh first.
#
# Per-slot failure backoff, kept in /run so a reboot starts every slot fresh:
# - A failed clone_runner holds the slot for 30 s, doubling with each failure
#   in a row up to 30 min. A successful clone clears it.
# - reclone.sh counts VMs that die within RAPID_DEATH_SECS of their clone,
#   which ran no job (GitHub rejected the runner, the guest failed to start
#   it). Every RAPID_DEATH_LIMIT of those in a row leave the slot empty and
#   hold it, again doubling up to 30 min. A VM that lives longer clears it.
# - Neither the watcher nor reclone.sh clones a held slot, so a slot that
#   fails every time stops minting a JIT runner on every tick.
set -euo pipefail

SLOT_STATE_DIR="/run/github-runners"
# Per-slot lock taken by watch.sh, reclone.sh, create.sh and destroy.sh.
SLOT_LOCK_PREFIX="/run/lock/runner"
SLOT_BACKOFF_BASE=30
SLOT_BACKOFF_MAX=1800
RAPID_DEATH_SECS=120
RAPID_DEATH_LIMIT=3

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
    install -d -m 700 "$SLOT_STATE_DIR" || return 1
    tmp=$(mktemp "$SLOT_STATE_DIR/.slot.XXXXXX") || return 1
    if ! printf 'hold_until=%s\nfailures=%s\nrapid=%s\ndeferrals=%s\n' \
            "$SLOT_HOLD_UNTIL" "$SLOT_FAILURES" "$SLOT_RAPID" "$SLOT_DEFERRALS" > "$tmp" \
        || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
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
# SLOT_HOLD_LEFT.
slot_is_held() {
    local now
    SLOT_HOLD_LEFT=0
    slot_state_load "$1"
    now=$(date +%s)
    (( SLOT_HOLD_UNTIL > now )) || return 1
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

slot_note_clone_success() {
    local name="$1"
    slot_state_load "$name"
    (( SLOT_FAILURES > 0 || SLOT_HOLD_UNTIL > 0 )) || return 0
    SLOT_FAILURES=0
    SLOT_HOLD_UNTIL=0
    slot_state_save "$name" || log_warn "Could not clear the backoff for $name in $SLOT_STATE_DIR"
}

# Count the death of slot $1's VM, which lived $2 seconds. An empty or
# non-numeric lifetime (snippet gone) counts nothing.
slot_note_death() {
    local name="$1" lifetime="$2" hold
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
            logger -t github-runner "reclone: $name died within ${RAPID_DEATH_SECS}s of its clone $RAPID_DEATH_LIMIT times in a row; holding the slot for ${hold}s"
        fi
    fi
    slot_state_save "$name" || log_warn "Could not record the backoff for $name in $SLOT_STATE_DIR"
}

file_mtime() {
    stat -c %Y "$1" 2>/dev/null
}

# Seconds since clone_runner wrote VM $1's meta snippet, which it does just
# before starting the VM. Prints nothing when the snippet is gone.
runner_vm_age() {
    local mtime now
    mtime=$(file_mtime "$SNIPPETS_DIR/runner-$1-meta.yaml") || return 0
    now=$(date +%s)
    if [[ ! "$mtime" =~ ^[0-9]+$ ]] || (( mtime > now )); then
        return 0
    fi
    printf '%s\n' "$((now - mtime))"
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
# caller holds the slot lock (fd 200) and shared pool activity (fd 202), and
# $3 prefixes the log lines. The slot stays empty while the backoff holds it,
# when the name is taken again or when the pool started draining; the watcher
# fills it later. Returns 1 only when clone_runner failed.
refill_runner_slot() {
    local name="$1" org="$2" tag="$3"
    if slot_is_held "$name"; then
        logger -t github-runner "$tag: $name is held for ${SLOT_HOLD_LEFT}s after repeated failures; the watcher refills it after that"
        return 0
    fi
    if qm list 200>&- 202>&- 2>/dev/null | awk 'NR>1{print $2}' | grep -qxF "$name"; then
        log_info "$tag: $name already exists, skipping"
        return 0
    fi
    if pool_is_draining; then
        logger -t github-runner "$tag: pool drain active after destroy for $name, leaving slot empty"
        return 0
    fi
    load_org_config "$org"
    if clone_runner "$name" "$org" >/dev/null; then
        slot_note_clone_success "$name"
        log_info "$tag: re-cloned $name for org $org"
        return 0
    fi
    # A drain refuses the clone on purpose; that is not the slot failing.
    pool_is_draining || slot_note_clone_failure "$name"
    log_error "$tag: failed to re-clone $name for org $org"
    return 1
}
