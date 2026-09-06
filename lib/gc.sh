#!/bin/bash
# Generation garbage collection (spec 9). Library at source time; the CLI
# validates options, loads host configuration, and calls gc_main.
# GEN_* fields are loaded into this shell by gen_read; mutating generation
# helpers intentionally use subshells, as documented in generations.sh.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_GC_LOADED:-}" ]]; then
    return 0
fi
RUNNER_GC_LOADED=1

declare -ag GC_PROJECTED_SUPERSEDED=()
declare -Ag GC_PROJECTED_STATE=()

# shellcheck source=generations.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/generations.sh"

gc_age_seconds() {
    local stamp="${1:-}" now then_epoch now_epoch
    [[ -n "$stamp" ]] || return 1
    now=$(gen_now) || return 1
    then_epoch=$(python3 -c 'import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$stamp") || return 1
    now_epoch=$(python3 -c 'import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$now") || return 1
    if (( now_epoch < then_epoch )); then
        printf '0\n'
    else
        printf '%s\n' $((now_epoch - then_epoch))
    fi
}

gc_storage_used_bytes() {
    local row used_kib
    row=$(pvesm status 2>/dev/null | awk -v name="$VM_STORAGE" '$1 == name { print; exit }') || return 1
    [[ -n "$row" ]] || return 1
    used_kib=$(awk '{ print $5 }' <<< "$row")
    [[ "$used_kib" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' $((used_kib * 1024))
}

# Verify both Proxmox configuration and storage are gone before the generation
# record is archived and removed. known child volids were captured before qm
# destroy, when the template config still described its base disks.
gc_storage_is_clean() {
    local vmid="$1"
    shift
    local listing volid known

    if [[ -n "$(vm_config_path "$vmid")" ]] || qm status "$vmid" >/dev/null 2>&1; then
        log_error "Generation VMID $vmid still exists after destroy"
        return 1
    fi
    listing=$(pvesm list "$VM_STORAGE" 2>/dev/null) || {
        log_error "Cannot verify storage after destroying generation VMID $vmid"
        return 1
    }
    while read -r volid _; do
        [[ -n "$volid" ]] || continue
        if [[ "$volid" =~ ^${VM_STORAGE}:([^/]+/)?(base-|vm-)${vmid}- ]]; then
            log_error "Generation VMID $vmid still owns storage volume $volid"
            return 1
        fi
        for known in "$@"; do
            if [[ "$volid" == "$known" ]]; then
                log_error "Generation VMID $vmid still has child volume $volid"
                return 1
            fi
        done
    done <<< "$listing"
    return 0
}

gc_warn_failure() {
    local gen_id="$1" vmid="$2" message="$3"
    log_warn "$message"
    if [[ "${GC_DRY_RUN:-false}" != "true" ]]; then
        NOTIFY_GENERATION="$gen_id" notify warn gc.failed "$message" "vmid=$vmid"
    fi
}

# gen_record_is_legacy_adopted / gen_record_is_rollback_eligible live in
# generations.sh (spec 9/15): they are pure generation-record predicates, and
# gen_rollback_target needs the exact same eligibility test GC uses so a
# retained generation and a rollback target can never disagree.

# Re-prove that a VMID still names the generation GC selected. This is called
# after every potentially slow inventory operation and immediately before qm
# destroy, closing the stale-record/VMID-reuse hole.
gc_verify_destroy_ownership() {
    local vmid="$1" expected_state="$2" expected_id="$3"
    local pointer cfg name expected_name

    pointer=$(reload_active_template_id) || {
        log_error "Could not re-read TEMPLATE_ID before destroying VMID $vmid"
        return 1
    }
    [[ "$vmid" != "$pointer" ]] || {
        log_error "Refusing to destroy current TEMPLATE_ID $vmid"
        return 1
    }
    gen_read "$vmid" || return 1
    if [[ "$GEN_VMID" != "$vmid" || "$GEN_ID" != "$expected_id" ]] ||
        [[ "$GEN_STATE" != "$expected_state" && ! ( "${GC_DRY_RUN:-false}" == "true" && "${GC_PROJECTED_STATE[$vmid]:-}" == "$expected_state" ) ]]; then
        log_error "Generation ownership changed before destroy of VMID $vmid"
        return 1
    fi
    if ! cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || [[ -z "$cfg" ]]; then
        log_error "Cannot read Proxmox config for generation $expected_id (VMID $vmid)"
        return 1
    fi
    grep -q '^template:[[:space:]]*1' <<< "$cfg" || {
        log_error "Refusing to destroy VMID $vmid: it is not a Proxmox template"
        return 1
    }
    name=$(awk '/^name:/{print $2; exit}' <<< "$cfg")
    expected_name="${GEN_TEMPLATE_NAME:-github-runner-gen-${expected_id}}"
    # Pre-marker generation 1 was adopted from the legacy deployment under
    # this fixed name and deliberately kept that name. Its two unknown
    # provenance values distinguish it from a baked generation record.
    if [[ -z "${GEN_TEMPLATE_NAME:-}" ]] && gen_record_is_legacy_adopted &&
        [[ "$name" == "ubuntu-cloud-template" ]]; then
        expected_name="$name"
    fi
    if [[ "$name" != "$expected_name" ]]; then
        log_error "Refusing to destroy VMID $vmid: name is ${name:-<empty>}, expected $expected_name"
        return 1
    fi
}

gc_destroy_generation() {
    local vmid="$1" expected_state="$2" dry_run="$3"
    local gen_id runner_version child_list before="" after="" reclaimed=0 rc=0 vm_exists=false
    local -a child_volids=()

    gen_read "$vmid" || return 1
    gen_id="$GEN_ID"
    runner_version="${GEN_RUNNER_VERSION:-unknown}"
    if [[ "$GEN_STATE" != "$expected_state" && ! ( "$dry_run" == "true" && "${GC_PROJECTED_STATE[$vmid]:-}" == "$expected_state" ) ]]; then
        gc_warn_failure "$gen_id" "$vmid" \
            "Generation $gen_id (VMID $vmid) changed from $expected_state to $GEN_STATE during GC; skipping"
        return 1
    fi
    if [[ "$vmid" == "${TEMPLATE_ID:-}" ]]; then
        gc_warn_failure "$gen_id" "$vmid" \
            "Refusing to garbage-collect current TEMPLATE_ID $vmid (record state $expected_state)"
        return 1
    fi

    child_list=$(list_template_linked_clone_volids "$vmid") || {
        gc_warn_failure "$gen_id" "$vmid" \
            "Could not inventory child volumes for generation $gen_id (VMID $vmid); record retained"
        return 1
    }
    [[ -z "$child_list" ]] || mapfile -t child_volids <<< "$child_list"
    before=$(gc_storage_used_bytes) || before=""

    # A prior partial run may already have removed the VM config. In that case
    # continue with residual cleanup and verification rather than wedging the
    # retained record forever.
    if [[ -n "$(vm_config_path "$vmid")" ]] || qm status "$vmid" >/dev/null 2>&1; then
        vm_exists=true
    fi
    if [[ "$vm_exists" == "true" ]]; then
        if ! gc_verify_destroy_ownership "$vmid" "$expected_state" "$gen_id"; then
            gc_warn_failure "$gen_id" "$vmid" \
                "Ownership verification failed for generation $gen_id (VMID $vmid); refusing destroy"
            return 1
        fi
        if [[ "$dry_run" == "true" ]]; then
            printf 'Would destroy generation %s (VMID %s, state %s)\n' "$gen_id" "$vmid" "$expected_state"
            return 0
        fi
        if ! qm destroy "$vmid" --purge; then
            gc_warn_failure "$gen_id" "$vmid" \
                "Failed to destroy generation $gen_id (VMID $vmid); record retained"
            return 1
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        printf 'Would clean residual storage and remove generation %s (VMID %s, state %s)\n' \
            "$gen_id" "$vmid" "$expected_state"
        return 0
    fi

    if ((${#child_volids[@]} > 0)); then
        cleanup_template_orphan_volumes "$vmid" "${child_volids[@]}" || rc=$?
        if ((rc != 0)); then
            gc_warn_failure "$gen_id" "$vmid" \
                "Failed to free all child volumes for generation $gen_id (VMID $vmid); record retained"
            return 1
        fi
    fi
    if ! gc_storage_is_clean "$vmid" "${child_volids[@]}"; then
        gc_warn_failure "$gen_id" "$vmid" \
            "Storage verification failed for generation $gen_id (VMID $vmid); record retained"
        return 1
    fi

    after=$(gc_storage_used_bytes) || after=""
    if [[ -n "$before" && -n "$after" && "$before" -gt "$after" ]]; then
        reclaimed=$((before - after))
    fi
    if ! gen_archive_has_event "$gen_id" "$vmid" destroyed; then
        if ! gen_archive_append "$gen_id" "$vmid" destroyed \
            "state=$expected_state" "runner=$runner_version" "reclaimed_bytes=$reclaimed"; then
            gc_warn_failure "$gen_id" "$vmid" \
                "Could not archive destroyed generation $gen_id (VMID $vmid); record retained"
            return 1
        fi
    fi
    if ! gen_remove "$vmid"; then
        gc_warn_failure "$gen_id" "$vmid" \
            "Could not remove the clean record for generation $gen_id (VMID $vmid)"
        return 1
    fi

    log_info "Destroyed generation $gen_id (VMID $vmid); reclaimed $reclaimed bytes"
    NOTIFY_GENERATION="$gen_id" notify info gc.destroyed \
        "Destroyed generation $gen_id (VMID $vmid)" "reclaimed_bytes=$reclaimed"
    return 0
}

gc_reconcile_candidates() {
    local dry_run="$1" list vmid newest="" newest_id=-1 newest_active_id=-1 age id active_list
    local -a candidates=()

    list=$(gen_list candidate) || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        candidates+=("$vmid")
        gen_read "$vmid" || return 1
        id=$(gen_require_numeric_id "$vmid") || return 1
        if ((id > newest_id)); then
            newest_id="$id"
            newest="$vmid"
        fi
    done <<< "$list"
    [[ -n "$newest" ]] || return 0

    active_list=$(gen_list active) || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || return 1
        id=$(gen_require_numeric_id "$vmid") || return 1
        ((id > newest_active_id)) && newest_active_id="$id"
    done <<< "$active_list"

    for vmid in "${candidates[@]}"; do
        gen_read "$vmid" || return 1
        id=$(gen_require_numeric_id "$vmid") || return 1
        if [[ "$vmid" != "$newest" || "$id" -lt "$newest_active_id" ]]; then
            if [[ "$dry_run" == "true" ]]; then
                printf 'Would supersede orphaned candidate generation %s (VMID %s)\n' "$GEN_ID" "$vmid"
                GC_PROJECTED_STATE["$vmid"]=superseded
                GC_PROJECTED_SUPERSEDED+=("$vmid")
            elif ! gen_transition "$vmid" superseded "superseded by newer candidate"; then
                gc_warn_failure "$GEN_ID" "$vmid" \
                    "Could not supersede orphaned candidate generation $GEN_ID (VMID $vmid)"
                return 1
            fi
            continue
        fi

        age=$(gc_age_seconds "$GEN_CREATED_AT") || {
            gc_warn_failure "$GEN_ID" "$vmid" \
                "Cannot determine age of candidate generation $GEN_ID (VMID $vmid)"
            return 1
        }
        if ((age >= CANDIDATE_MAX_AGE_DAYS * 86400)); then
            if [[ "$dry_run" == "true" ]]; then
                printf 'Would mark candidate generation %s (VMID %s) failed: never promoted after %s days\n' \
                    "$GEN_ID" "$vmid" "$CANDIDATE_MAX_AGE_DAYS"
                GC_PROJECTED_STATE["$vmid"]=failed
            elif gen_transition "$vmid" failed \
                "never promoted after ${CANDIDATE_MAX_AGE_DAYS} days"; then
                NOTIFY_GENERATION="$GEN_ID" notify warn candidate.failed \
                    "Candidate generation $GEN_ID (VMID $vmid) was never promoted" \
                    "age_days=$((age / 86400))"
            else
                gc_warn_failure "$GEN_ID" "$vmid" \
                    "Could not fail expired candidate generation $GEN_ID (VMID $vmid)"
                return 1
            fi
        fi
    done
}

gc_collect_superseded() {
    local dry_run="$1" list vmid retain="" blockers age
    local -a superseded=()
    local pointer active_id=""

    # Retention must be the exact same *selection* gen_rollback_target makes,
    # not a parallel highest-GEN_ID tiebreak of our own -- two independent
    # algorithms can each look locally reasonable and still name different
    # VMIDs as "the retained generation" (issue #19 review round 1). A
    # rollback re-activates an older generation and leaves the one it escaped
    # superseded by a later crash-reconcile (maintain_reconcile_two_actives),
    # never rejected; only gen_rollback_target's own recency tiebreak (never
    # highest GEN_ID, spec 15) reliably prefers the true previous generation
    # over that leftover, including across any number of promotions that
    # happen afterward. Re-reads the pointer with reload_active_template_id
    # rather than trusting the in-memory TEMPLATE_ID, the same as
    # gc_verify_destroy_ownership does immediately before a destroy: a
    # destructive policy must not silently fall back to a less-safe rule just
    # because its guard input could not be resolved.
    pointer=$(reload_active_template_id) || pointer=""
    if [[ -n "$pointer" ]] && gen_exists "$pointer"; then
        gen_read "$pointer" || return 1
        active_id=$(gen_require_numeric_id "$pointer") || return 1
    else
        log_warn "gc: could not resolve the active generation from TEMPLATE_ID — skipping superseded collection"
        return 1
    fi

    # Suppressed: "nothing retained" is the ordinary state of a fresh fleet
    # or one already fully collected, not a gc.sh-level error -- callers that
    # need to report it as one (gen_rollback_target's own direct callers) get
    # gen_rollback_target's own log_error undisturbed.
    retain=$(gen_rollback_target "$active_id" 2>/dev/null) || retain=""

    list=$(gen_list superseded) || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        superseded+=("$vmid")
    done <<< "$list"
    if [[ "$dry_run" == "true" && ${#GC_PROJECTED_SUPERSEDED[@]} -gt 0 ]]; then
        superseded+=("${GC_PROJECTED_SUPERSEDED[@]}")
    fi

    for vmid in "${superseded[@]}"; do
        gen_read "$vmid" || return 1
        blockers=$(generation_ref_vmids "$GEN_ID") || {
            gc_warn_failure "$GEN_ID" "$vmid" \
                "Could not compute refcount for generation $GEN_ID (VMID $vmid); record retained"
            return 1
        }
        if [[ -n "$blockers" ]]; then
            log_info "Generation $GEN_ID (VMID $vmid) is blocked by VMIDs: ${blockers//$'\n'/ }"
            if [[ -n "$GEN_SUPERSEDED_AT" ]]; then
                age=$(gc_age_seconds "$GEN_SUPERSEDED_AT") || age=0
            else
                age=0
            fi
            if [[ "$dry_run" != "true" ]] && ((age >= GC_STUCK_WARN_HOURS * 3600)); then
                NOTIFY_GENERATION="$GEN_ID" notify warn gc.blocked \
                    "Generation $GEN_ID (VMID $vmid) is still blocked" \
                    "blocking_vmids=${blockers//$'\n'/,}"
            fi
            continue
        fi
        if [[ "$vmid" == "$retain" ]] && gen_record_is_rollback_eligible; then
            log_info "Retaining newest superseded generation $GEN_ID (VMID $vmid) for rollback"
            continue
        fi
        gc_destroy_generation "$vmid" superseded "$dry_run" || return 1
    done
}

gc_collect_terminal() {
    local state="$1" dry_run="$2" list vmid stamp age blockers
    list=$(gen_list "$state") || return 1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || return 1
        stamp="$GEN_TERMINAL_AT"
        if [[ -z "$stamp" ]]; then
            # Migration fallback for records written before GEN_TERMINAL_AT.
            stamp="$GEN_CREATED_AT"
            [[ "$state" != "rejected" || -z "$GEN_SUPERSEDED_AT" ]] || stamp="$GEN_SUPERSEDED_AT"
        fi
        age=$(gc_age_seconds "$stamp") || {
            gc_warn_failure "$GEN_ID" "$vmid" \
                "Cannot determine age of $state generation $GEN_ID (VMID $vmid)"
            return 1
        }
        ((age >= FAILED_GEN_RETAIN_DAYS * 86400)) || continue
        blockers=$(generation_ref_vmids "$GEN_ID") || {
            gc_warn_failure "$GEN_ID" "$vmid" \
                "Could not compute refcount for generation $GEN_ID (VMID $vmid); record retained"
            return 1
        }
        if [[ -n "$blockers" ]]; then
            log_warn "$state generation $GEN_ID (VMID $vmid) is blocked by VMIDs: ${blockers//$'\n'/ }"
            continue
        fi
        gc_destroy_generation "$vmid" "$state" "$dry_run" || return 1
    done <<< "$list"
}

gc_main() {
    local dry_run="${1:-false}"
    local rc=0
    local GC_DRY_RUN="$dry_run"
    GC_PROJECTED_SUPERSEDED=()
    GC_PROJECTED_STATE=()
    apply_generation_defaults
    gen_store_init || return 1

    mkdir -p "$(dirname "$GC_LOCK_FILE")" || return 1
    exec 214>"$GC_LOCK_FILE" || return 1
    if ! flock -w 30 214; then
        log_error "Timed out acquiring garbage-collection lock"
        return 1
    fi

    # Lock order matches upgrade: bake, then pool. The bake lock keeps manual
    # GC from racing candidate publication/cleanup. The exclusive pool lock
    # keeps promotion, rollback, and new clones from changing the active or
    # retained generation between refcount and destroy.
    exec 215>"$BAKE_LOCK_FILE" || { exec 214>&-; return 1; }
    if ! flock -w 30 215; then
        log_error "Timed out waiting for an active bake before garbage collection"
        exec 215>&- 214>&-
        return 1
    fi
    # Publish and exclusively own the same pause file promotion uses before
    # waiting for the pool lock. New clones stop joining the shared lock, so a
    # steady workload cannot starve GC. If promotion owns the pause, defer GC;
    # taking the pause before pool also preserves the global lock order.
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")" || { exec 215>&- 214>&-; return 1; }
    exec 217>"$PROMOTION_PAUSE_FILE" || { exec 215>&- 214>&-; return 1; }
    if ! flock -n 217; then
        log_warn "Promotion pause is owned by another operation — skipping garbage collection"
        exec 217>&- 215>&- 214>&-
        return 1
    fi
    exec 216>"$POOL_ACTIVITY_LOCK_FILE" || { rm -f "$PROMOTION_PAUSE_FILE"; exec 217>&- 215>&- 214>&-; return 1; }
    if ! flock -w 30 216; then
        log_error "Timed out waiting for pool activity before garbage collection"
        rm -f "$PROMOTION_PAUSE_FILE"
        exec 216>&- 217>&- 215>&- 214>&-
        return 1
    fi

    gc_reconcile_candidates "$dry_run" || rc=1
    ((rc == 0)) && gc_collect_superseded "$dry_run" || rc=1
    ((rc == 0)) && gc_collect_terminal failed "$dry_run" || rc=1
    ((rc == 0)) && gc_collect_terminal rejected "$dry_run" || rc=1
    exec 216>&-
    rm -f "$PROMOTION_PAUSE_FILE"
    exec 217>&- 215>&- 214>&-
    return "$rc"
}

gc_cli() {
    local dry_run=false
    while (($# > 0)); do
        case "$1" in
            --dry-run) dry_run=true ;;
            -h|--help)
                echo "Usage: runner gc [--dry-run]"
                return 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: runner gc [--dry-run]" >&2
                return 1
                ;;
        esac
        shift
    done
    gc_main "$dry_run"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root gc
    load_infra_config
    gc_cli "$@"
fi
