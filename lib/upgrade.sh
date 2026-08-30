#!/bin/bash
# Operator-invoked bake-then-promote. Not a timer. Maintain never promotes.
#
# Library: functions only at source time. Tests load_lib upgrade.sh and call
# upgrade_main. When executed as the CLI (`BASH_SOURCE == $0`), require_root,
# load_infra_config, then upgrade_main.
#
# --yes on promote is allowed here: invoking `runner upgrade` is the
# confirmation. Maintain and the 02:30 timer still do not promote.
# --yes is for setup bootstrap, tests, and this verb.
#
# Success is the post-state: TEMPLATE_ID is a Proxmox template whose generation
# record matches the current digest. Step return 0 is not enough (memoed
# digest, busy bake lock, and REBAKE_ENABLED=false all look like "nothing to
# do" in bake/detect).
#
# Without --foreground and without INVOCATION_ID, the CLI enqueues
# github-runner-upgrade.service (oneshot, ExecStart --foreground) so an SSH
# drop cannot bake_fail+memo. --force is passed via $RUNNER_STATE_DIR/upgrade.force
# because ExecStart cannot grow flags. --dry-run stays in-process.
#
# fd 210: bake lock. Distinct from the bake CLI's fd 207 so we can hold the
# lock across bake_locked then promote. Proven by "upgrade holds BAKE_LOCK_FILE
# on fd 210 across promote" and "held bake lock makes upgrade --foreground exit 1".
#
# GEN_* fields are loaded via gen_read in this shell.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_UPGRADE_LOADED:-}" ]]; then
    return 0
fi
RUNNER_UPGRADE_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=bake.sh
source "$LIB_DIR/bake.sh"
# shellcheck source=promote.sh
source "$LIB_DIR/promote.sh"
# two-actives repair after promote. maintain.sh sources bake.sh (already loaded).
# shellcheck source=maintain.sh
source "$LIB_DIR/maintain.sh"

upgrade_usage() {
    echo "Usage: runner upgrade [--dry-run] [--force] [--foreground]"
}

# True when this process should enqueue the oneshot instead of baking here.
upgrade_should_wrap() {
    local foreground="$1" dry_run="$2"
    [[ "$dry_run" -eq 0 ]] || return 1
    [[ "$foreground" -eq 0 ]] || return 1
    [[ -z "${INVOCATION_ID:-}" ]] || return 1
    return 0
}

upgrade_preflight() {
    local cfg avail

    apply_generation_defaults

    if [[ "${CANARY_ENABLED}" == "true" ]]; then
        log_error "CANARY_ENABLED=true — runner upgrade will not skip-canary"
        log_error "Set CANARY_ENABLED=false or wait for canary (#21/#22)"
        return 1
    fi

    if [[ -z "${TEMPLATE_ID:-}" ]]; then
        log_error "TEMPLATE_ID is not set — this is a bootstrap, run 'runner setup'"
        return 1
    fi
    if ! cfg=$(qm config "$TEMPLATE_ID" 2>/dev/null); then
        log_error "No live template at TEMPLATE_ID $TEMPLATE_ID — this is a bootstrap, run 'runner setup'"
        return 1
    fi
    if ! grep -q '^template:[[:space:]]*1' <<< "$cfg"; then
        log_error "TEMPLATE_ID $TEMPLATE_ID is not a Proxmox template — this is a bootstrap, run 'runner setup'"
        return 1
    fi

    validate_band_inventory || return 1

    avail=$(storage_avail_gb) || {
        log_error "Could not parse free space for $VM_STORAGE"
        return 1
    }
    if (( avail < BAKE_MIN_FREE_GB )); then
        log_error "Insufficient free space on $VM_STORAGE: ${avail}G available, ${BAKE_MIN_FREE_GB}G required"
        return 1
    fi
    return 0
}

upgrade_print_status() {
    local pointer="$1" cand="${2:-}" prev="${3:-}" digest="${4:-}"
    local gid="" ver="" logpath="" live="${cand:-$pointer}"

    if [[ -n "$live" ]] && gen_exists "$live"; then
        gen_read "$live" || true
        gid="${GEN_ID:-}"
        ver="${GEN_RUNNER_VERSION:-}"
        logpath="${GEN_BAKE_LOG:-}"
        [[ -n "$digest" ]] || digest="${GEN_TEMPLATE_DIGEST:-}"
    fi

    printf 'TEMPLATE_ID=%s\n' "$pointer"
    printf 'vmid=%s\n' "$live"
    [[ -n "$gid" ]] && printf 'generation=%s\n' "$gid"
    [[ -n "$ver" ]] && printf 'runner_version=%s\n' "$ver"
    [[ -n "$digest" ]] && printf 'digest=%s\n' "$digest"
    [[ -n "$prev" && "$prev" != "$pointer" ]] && printf 'previous_vmid=%s\n' "$prev"
    [[ -n "$logpath" ]] && printf 'bake_log=%s\n' "$logpath"
    printf 'drain_bound_hours=%s\n' "${MAX_VM_LIFETIME_HOURS:-$DEFAULT_MAX_VM_LIFETIME_HOURS}"
}

# Newest matching active for $digest. If $2 is set, skip that VMID (the
# pointer) so a leftover extra is visible. Newest GEN_PROMOTED_AT, never
# lowest VMID. Proven by "same-digest two actives: pointer on higher VMID
# is kept" and "same-digest two actives: pointer still on older VMID
# promotes the newer".
upgrade_matching_active() {
    local digest="$1" skip="${2:-}" vmid="" keep="" best_ts="" ts
    [[ -n "$digest" ]] || return 1
    while read -r vmid; do
        [[ -n "$vmid" && "$vmid" != "$skip" ]] || continue
        gen_read "$vmid" || return 1
        [[ "$GEN_TEMPLATE_DIGEST" == "$digest" ]] || continue
        ts="${GEN_PROMOTED_AT:-}"
        if [[ -z "$keep" ]]; then
            keep="$vmid"
            best_ts="$ts"
            continue
        fi
        if [[ -n "$ts" && ( -z "$best_ts" || "$ts" > "$best_ts" ) ]]; then
            keep="$vmid"
            best_ts="$ts"
        fi
    done < <(gen_list active)
    [[ -n "$keep" ]] || return 1
    printf '%s\n' "$keep"
}

# Prefer a candidate so weekly-floor promotes the new bake, not the old
# active with the same digest. Then newest matching active (same-digest
# split-brain), not the lowest VMID.
upgrade_resolve_target() {
    local digest="$1" vmid=""
    [[ -n "$digest" ]] || return 1
    vmid=$(bake_matching_candidate "$digest") && { printf '%s\n' "$vmid"; return 0; }
    vmid=$(upgrade_matching_active "$digest") && { printf '%s\n' "$vmid"; return 0; }
    vmid=$(bake_matching_generation "$digest") && { printf '%s\n' "$vmid"; return 0; }
    return 1
}

upgrade_dry_run() {
    local force="${1:-0}"
    local digest planned decision match match_gen pointer promote_vmid="" other=""

    upgrade_preflight || return 1

    pointer=$(reload_active_template_id) || pointer="${TEMPLATE_ID:-}"
    printf 'pointer=%s\n' "$pointer"
    printf 'template=1\n'
    printf 'band_inventory=ok\n'
    printf 'free_gb=%s\n' "$(storage_avail_gb)"

    decision=$(detect_should_bake) || return 1
    printf 'detect=%s\n' "$decision"

    digest=$(compute_template_digest) || return 1
    printf 'digest=%s\n' "$digest"
    planned=$(bake_planned_vmid) || planned="none"
    printf 'planned_vmid=%s\n' "$planned"
    match=""
    match=$(bake_matching_candidate "$digest") || match=""
    printf 'matching_candidate=%s\n' "$match"
    match_gen=""
    match_gen=$(upgrade_matching_active "$digest") || match_gen=""
    printf 'matching_generation=%s\n' "$match_gen"
    other=$(upgrade_matching_active "$digest" "$pointer") || other=""
    if [[ "$force" -eq 1 ]]; then
        printf 'reason=force\n'
    elif [[ "$decision" == yes\ * ]]; then
        printf 'reason=%s\n' "${decision#yes }"
    else
        printf 'reason=%s\n' "${decision#no }"
    fi
    if [[ "$force" -eq 1 ]]; then
        if [[ -n "$match" ]]; then
            printf 'bake_plan=skip (candidate exists)\n'
        else
            printf 'bake_plan=bake\n'
        fi
    elif [[ "$decision" == yes\ * ]]; then
        if [[ -n "$match" ]]; then
            printf 'bake_plan=skip (candidate exists)\n'
        elif [[ -n "$other" ]]; then
            printf 'bake_plan=skip (matching active, pointer stale)\n'
        else
            printf 'bake_plan=bake\n'
        fi
    else
        printf 'bake_plan=none\n'
    fi
    if [[ -n "$match" ]]; then
        promote_vmid="$match"
    elif [[ -n "$match_gen" ]]; then
        promote_vmid="$match_gen"
    fi
    if [[ "$force" -eq 0 && "$decision" == no\ memoed-digest ]]; then
        printf 'promote_plan=refuse (memoed-digest)\n'
    elif [[ "$force" -eq 0 && "$decision" == no\ rebake-disabled ]]; then
        printf 'promote_plan=refuse (rebake-disabled)\n'
    elif [[ -n "$promote_vmid" && "$promote_vmid" != "$pointer" ]]; then
        gen_read "$promote_vmid" || true
        printf 'promote_plan=gen %s VMID %s -> TEMPLATE_ID (was %s)\n' \
            "${GEN_ID:-?}" "$promote_vmid" "$pointer"
    elif [[ "$force" -eq 1 ]]; then
        printf 'promote_plan=after bake\n'
    elif [[ "$decision" == no\ up-to-date ]]; then
        printf 'promote_plan=none (already current)\n'
    elif [[ "$decision" == yes\ * ]]; then
        printf 'promote_plan=after bake\n'
    else
        printf 'promote_plan=none\n'
    fi
    return 0
}

# Held under exclusive flock on BAKE_LOCK_FILE fd 210.
upgrade_locked() {
    local force="$1"
    local decision digest cand pointer prev gid attempt sleep_s rc=0
    local match_cand="" match_other=""

    decision=$(detect_should_bake) || return 1

    if [[ "$force" -eq 0 ]]; then
        case "$decision" in
            no\ memoed-digest)
                log_error "memoed digest: a previous bake failed and needs a person, not a retry"
                log_error "run: runner upgrade --force"
                return 1
                ;;
            no\ rebake-disabled)
                log_error "REBAKE_ENABLED=false — upgrade will not bake or promote"
                log_error "Set REBAKE_ENABLED=true in the infra config, or use runner upgrade --force"
                return 1
                ;;
            yes\ *|no\ *)
                ;;
            *)
                log_error "detect_should_bake produced an unreadable decision: ${decision:-<empty>}"
                return 1
                ;;
        esac
    fi

    digest=$(compute_template_digest) || return 1
    pointer=$(reload_active_template_id) || return 1
    prev="$pointer"
    match_cand=$(bake_matching_candidate "$digest") || match_cand=""
    match_other=""
    match_other=$(upgrade_matching_active "$digest" "$pointer") || match_other=""

    if [[ "$force" -eq 1 ]]; then
        # Match --dry-run --force: a digest-matching candidate is already the
        # bake we would produce. Rebaking would destroy it via
        # bake_fail_other_candidates. Proven by "--force with a matching
        # candidate skips bake_locked".
        if [[ -n "$match_cand" ]]; then
            log_info "nothing to bake: candidate VMID $match_cand already matches"
        else
            bake_locked 1 || return 1
            digest="${_BAKE_DIGEST:-$digest}"
        fi
    elif [[ "$decision" == yes\ * ]]; then
        # Candidate already matching → promote only. Any matching active that
        # is not the pointer is a promote crash; do not bake N+1. Weekly
        # floor: the pointer is the sole match, so we still bake.
        if [[ -n "$match_cand" ]]; then
            log_info "nothing to bake: candidate VMID $match_cand already matches"
        elif [[ -n "$match_other" ]]; then
            log_info "nothing to bake: matching active VMID $match_other, pointer is stale"
        else
            log_info "bake needed: ${decision#yes }"
            bake_locked 0 || return 1
            digest="${_BAKE_DIGEST:-$digest}"
        fi
    else
        log_info "nothing to bake: ${decision#no }"
    fi

    cand=$(upgrade_resolve_target "$digest") || cand=""
    pointer=$(reload_active_template_id) || return 1

    if [[ -z "$cand" ]]; then
        log_error "bake produced no candidate for this digest"
        return 1
    fi

    if [[ "$pointer" != "$cand" ]]; then
        gen_read "$cand" || return 1
        gid="$GEN_ID"
        [[ -n "$gid" ]] || return 1
        sleep_s="${UPGRADE_PROMOTE_RETRY_SLEEP:-2}"
        [[ "$sleep_s" =~ ^[0-9]+$ ]] || sleep_s=2
        rc=1
        for attempt in 1 2 3; do
            if promote_generation "$gid" --skip-canary --yes; then
                rc=0
                break
            fi
            log_warn "promote attempt $attempt failed"
            (( attempt == 3 )) || sleep "$sleep_s"
        done
        [[ "$rc" -eq 0 ]] || {
            log_error "Failed to promote generation $gid after 3 attempts"
            return 1
        }
    fi

    # rewrite_template_id does not assign this shell's TEMPLATE_ID.
    # Reconcile keeps in-memory TEMPLATE_ID when it is still in the
    # active set. Always run so extras die even when pointer == cand.
    # Proven by "reconcile after promote keeps the on-disk pointer, not
    # in-shell TEMPLATE_ID" and "same-digest two actives: pointer on
    # higher VMID is kept".
    TEMPLATE_ID=$(reload_active_template_id) || return 1
    pointer="$TEMPLATE_ID"
    maintain_clear_stale_promotion_pause || true
    maintain_reconcile_two_actives || {
        log_error "Failed to reconcile split-brain active generations"
        return 1
    }
    gen_read "$cand" || return 1
    if [[ "$GEN_STATE" != "active" ]]; then
        log_error "Promoted VMID $cand is $GEN_STATE, not active"
        return 1
    fi
    pointer=$(reload_active_template_id) || return 1

    if [[ "$pointer" != "$cand" ]]; then
        log_error "TEMPLATE_ID is $pointer, expected candidate $cand"
        return 1
    fi
    if ! qm config "$cand" 2>/dev/null | grep -q '^template:[[:space:]]*1'; then
        log_error "Promoted VMID $cand is not a Proxmox template"
        return 1
    fi
    upgrade_print_status "$pointer" "$cand" "$prev" "$digest"
    return 0
}

upgrade_force_flag() {
    printf '%s\n' "$RUNNER_STATE_DIR/upgrade.force"
}

# Oneshot ExecStart cannot grow --force. The wrap writes this flag; the
# unit consumes it. Proven by "runner upgrade --force writes the force flag
# the oneshot consumes".
upgrade_write_force_flag() {
    local force="$1" path
    path=$(upgrade_force_flag)
    ensure_state_dir "$RUNNER_STATE_DIR" || return 1
    if [[ "$force" -eq 1 ]]; then
        printf '1\n' > "$path" || return 1
        chmod 600 "$path" 2>/dev/null || true
    else
        rm -f "$path"
    fi
    return 0
}

upgrade_consume_force_flag() {
    local path
    path=$(upgrade_force_flag)
    [[ -f "$path" ]] || return 1
    rm -f "$path"
    return 0
}

upgrade_foreground() {
    local force="$1"

    if upgrade_consume_force_flag; then
        force=1
    fi

    upgrade_preflight || return 1
    adopt_deployed_template || {
        log_error "Adoption failed"
        return 1
    }

    mkdir -p "$(dirname "$BAKE_LOCK_FILE")" || {
        log_error "Cannot create bake lock directory"
        return 1
    }
    exec 210>"$BAKE_LOCK_FILE" || {
        log_error "Cannot open bake lock $BAKE_LOCK_FILE"
        return 1
    }
    log_info "Waiting for the bake lock (up to ${BAKE_TIMEOUT}s)"
    if ! flock -w "${BAKE_TIMEOUT}" 210; then
        log_error "Timed out waiting for the bake lock"
        log_error "bake in progress: journalctl -fu github-runner-upgrade.service"
        log_error "or: journalctl -fu github-runner-maintain.service"
        exec 210>&- || true
        return 1
    fi

    local rc=0
    upgrade_locked "$force" || rc=$?
    exec 210>&- || true
    return "$rc"
}

upgrade_via_unit() {
    local force="${1:-0}"
    local unit_src="" unit_dst before_id
    unit_dst="$SYSTEMD_UNIT_DIR/github-runner-upgrade.service"
    if [[ -f "$LIB_DIR/../templates/github-runner-upgrade.service" ]]; then
        unit_src="$LIB_DIR/../templates/github-runner-upgrade.service"
    elif [[ -f "${INSTALL_DIR}/templates/github-runner-upgrade.service" ]]; then
        unit_src="${INSTALL_DIR}/templates/github-runner-upgrade.service"
    fi
    if [[ -z "$unit_src" ]]; then
        log_error "github-runner-upgrade.service template is not in this install"
        return 1
    fi
    mkdir -p "$SYSTEMD_UNIT_DIR"
    cp "$unit_src" "$unit_dst" || return 1
    upgrade_write_force_flag "$force" || return 1
    systemctl daemon-reload || {
        log_error "systemctl daemon-reload failed — is github-runner-upgrade.service installed?"
        rm -f "$(upgrade_force_flag)"
        return 1
    }
    before_id=$(systemctl show -p InvocationID --value github-runner-upgrade.service 2>/dev/null || true)
    if ! systemctl start --no-block github-runner-upgrade.service; then
        log_error "Failed to start github-runner-upgrade.service"
        rm -f "$(upgrade_force_flag)"
        return 1
    fi
    log_info "Upgrade running (bake can take up to 90 minutes)."
    log_info "Ctrl-C detaches; the unit keeps running (this CLI exits non-zero)."
    log_info "  journalctl -u github-runner-upgrade.service -f"
    # start was --no-block, so SIGINT here must not stop the unit.
    # Proven by "without --foreground, wrap wait status is the unit Result".
    upgrade_wait_unit "$before_id"
}

# Follow this oneshot until it leaves activating. SIGINT detaches non-zero.
# A new InvocationID is required; leftover Result=success is not this run.
# Proven by "upgrade_wait_unit rejects leftover Result=success without a new
# InvocationID" and "without --foreground, wrap wait status is the unit Result".
upgrade_wait_unit() {
    local before_id="${1:-}"
    local after_id="" new_id="" unit_state unit_result journal_pid="" poll
    local max_poll="${UPGRADE_WAIT_POLLS:-240}"
    local sleep_s="${UPGRADE_WAIT_SLEEP:-0.25}"
    local done_sleep="${UPGRADE_WAIT_DONE_SLEEP:-2}"

    _upgrade_wait_cleanup() {
        if [[ -n "${journal_pid:-}" ]]; then
            kill "$journal_pid" 2>/dev/null || true
            wait "$journal_pid" 2>/dev/null || true
            journal_pid=""
        fi
        trap - INT
    }
    trap '_upgrade_wait_cleanup; log_info "Detached. Unit continues: journalctl -u github-runner-upgrade.service -f"; exit 1' INT

    if [[ -t 1 ]] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u github-runner-upgrade.service -f --no-pager --since now &
        journal_pid=$!
    fi
    [[ "$max_poll" =~ ^[0-9]+$ ]] || max_poll=240
    poll=0
    while (( poll < max_poll )); do
        after_id=$(systemctl show -p InvocationID --value github-runner-upgrade.service 2>/dev/null || true)
        if [[ -n "$after_id" && "$after_id" != "$before_id" ]]; then
            new_id="$after_id"
            break
        fi
        poll=$((poll + 1))
        sleep "$sleep_s"
    done
    if [[ -z "$new_id" ]]; then
        unit_state=$(systemctl is-active github-runner-upgrade.service 2>/dev/null || true)
        after_id=$(systemctl show -p InvocationID --value github-runner-upgrade.service 2>/dev/null || true)
        if [[ -n "$after_id" && ( "$unit_state" == "activating" || "$unit_state" == "active" ) ]]; then
            # start --no-block on an already-running oneshot often returns 0
            # and reuses InvocationID. Join that run instead of lying "did
            # not start". Proven by "upgrade_wait_unit joins an activating
            # unit with the same InvocationID".
            new_id="$after_id"
            log_info "Joining already-running upgrade unit"
        else
            _upgrade_wait_cleanup
            rm -f "$(upgrade_force_flag)"
            log_error "Upgrade unit did not start (no new InvocationID)"
            return 1
        fi
    fi
    while true; do
        after_id=$(systemctl show -p InvocationID --value github-runner-upgrade.service 2>/dev/null || true)
        if [[ "$after_id" != "$new_id" ]]; then
            _upgrade_wait_cleanup
            log_error "Upgrade unit InvocationID changed during wait"
            return 1
        fi
        unit_state=$(systemctl is-active github-runner-upgrade.service 2>/dev/null || true)
        case "$unit_state" in
            activating|active) sleep "$done_sleep" ;;
            inactive|failed) break ;;
            "") sleep "$sleep_s" ;;
            *) break ;;
        esac
    done
    _upgrade_wait_cleanup
    after_id=$(systemctl show -p InvocationID --value github-runner-upgrade.service 2>/dev/null || true)
    if [[ "$after_id" != "$new_id" ]]; then
        log_error "Upgrade unit InvocationID changed during wait"
        return 1
    fi
    unit_result=$(systemctl show -p Result --value github-runner-upgrade.service 2>/dev/null || true)
    if [[ "$unit_result" != "success" ]]; then
        log_error "Upgrade unit finished with Result=${unit_result:-unknown}"
        log_error "journalctl -u github-runner-upgrade.service"
        return 1
    fi
    return 0
}

upgrade_main() {
    local force=0 dry_run=0 foreground=0

    apply_generation_defaults

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            --foreground) foreground=1; shift ;;
            -h|--help)
                upgrade_usage
                return 0
                ;;
            *)
                log_error "Unknown option: $1"
                upgrade_usage
                return 1
                ;;
        esac
    done

    if [[ "$dry_run" -eq 1 ]]; then
        upgrade_dry_run "$force"
        return $?
    fi

    if upgrade_should_wrap "$foreground" "$dry_run"; then
        upgrade_preflight || return 1
        upgrade_via_unit "$force"
        return $?
    fi

    upgrade_foreground "$force"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root upgrade
    load_infra_config
    upgrade_main "$@"
fi
