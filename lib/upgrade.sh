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
# drop cannot bake_fail+memo. --dry-run stays in-process.
#
# fd 210: bake lock. Distinct from the bake CLI's fd 207 so we can hold the
# lock across bake_locked then promote. Proven by "upgrade holds BAKE_LOCK_FILE
# on fd 210 and calls bake_locked".
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
        log_error "TEMPLATE_ID is not set"
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

# Prefer a candidate so weekly-floor promotes the new bake, not the old
# active with the same digest. Then any matching active (stale pointer).
upgrade_resolve_target() {
    local digest="$1" vmid=""
    [[ -n "$digest" ]] || return 1
    vmid=$(bake_matching_candidate "$digest") && { printf '%s\n' "$vmid"; return 0; }
    vmid=$(bake_matching_generation "$digest") && { printf '%s\n' "$vmid"; return 0; }
    return 1
}

upgrade_dry_run() {
    local digest planned decision match match_gen pointer promote_vmid=""

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
    match_gen=$(bake_matching_generation "$digest") || match_gen=""
    printf 'matching_generation=%s\n' "$match_gen"
    if [[ "$decision" == yes\ * ]]; then
        printf 'reason=%s\n' "${decision#yes }"
    else
        printf 'reason=%s\n' "${decision#no }"
    fi
    if [[ "$decision" == yes\ * ]]; then
        if [[ -n "$match" ]]; then
            printf 'bake_plan=skip (candidate exists)\n'
        elif [[ -n "$match_gen" && "$match_gen" != "$pointer" ]]; then
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
    if [[ -n "$promote_vmid" && "$promote_vmid" != "$pointer" ]]; then
        gen_read "$promote_vmid" || true
        printf 'promote_plan=gen %s VMID %s -> TEMPLATE_ID (was %s)\n' \
            "${GEN_ID:-?}" "$promote_vmid" "$pointer"
    elif [[ "$decision" == no\ up-to-date ]]; then
        printf 'promote_plan=none (already current)\n'
    elif [[ "$decision" == yes\ weekly-floor ]]; then
        printf 'promote_plan=after bake (same digest, weekly-floor)\n'
    fi
    return 0
}

# Held under exclusive flock on BAKE_LOCK_FILE fd 210.
upgrade_locked() {
    local force="$1"
    local decision digest cand pointer prev gid attempt sleep_s rc=0
    local match_cand="" match_gen=""

    decision=$(detect_should_bake) || return 1

    if [[ "$force" -eq 0 ]]; then
        case "$decision" in
            no\ memoed-digest)
                log_error "memoed digest: a previous bake failed and needs a person, not a retry"
                log_error "run: runner bake --force && runner upgrade"
                return 1
                ;;
            no\ rebake-disabled)
                log_error "REBAKE_ENABLED=false — upgrade will not bake or promote"
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
    match_gen=$(bake_matching_generation "$digest") || match_gen=""

    if [[ "$force" -eq 1 ]]; then
        bake_locked 1 || return 1
        digest="${_BAKE_DIGEST:-$digest}"
    elif [[ "$decision" == yes\ * ]]; then
        # Candidate already matching → promote only. Matching active that is
        # not the pointer is a promote-before-rewrite crash; do not bake N+1.
        # Weekly floor: the pointer itself matches, so we still bake.
        if [[ -n "$match_cand" ]]; then
            log_info "nothing to bake: candidate VMID $match_cand already matches"
        elif [[ -n "$match_gen" && "$match_gen" != "$pointer" ]]; then
            log_info "nothing to bake: matching active VMID $match_gen, pointer is stale"
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
        maintain_reconcile_two_actives || true
        pointer=$(reload_active_template_id) || return 1
    fi

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

upgrade_foreground() {
    local force="$1"

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
    if ! flock -w "${BAKE_TIMEOUT}" 210; then
        log_error "Timed out waiting for the bake lock"
        log_error "bake in progress: journalctl -fu github-runner-maintain.service"
        exec 210>&- || true
        return 1
    fi

    local rc=0
    upgrade_locked "$force" || rc=$?
    exec 210>&- || true
    return "$rc"
}

upgrade_via_unit() {
    local unit_src="${INSTALL_DIR:-/opt/selfhosted-runners}/templates/github-runner-upgrade.service"
    if [[ -f "$unit_src" ]]; then
        mkdir -p "$SYSTEMD_UNIT_DIR"
        cp "$unit_src" "$SYSTEMD_UNIT_DIR/github-runner-upgrade.service" || return 1
    fi
    systemctl daemon-reload || {
        log_error "systemctl daemon-reload failed — is github-runner-upgrade.service installed?"
        return 1
    }
    if ! systemctl start --no-block github-runner-upgrade.service; then
        log_error "Failed to start github-runner-upgrade.service"
        return 1
    fi
    log_info "Upgrade running (bake can take up to 90 minutes)."
    log_info "Ctrl-C detaches; the unit keeps running."
    log_info "  journalctl -u github-runner-upgrade.service -f"
    # TTY follow is convenience. start was --no-block, so SIGINT here must
    # not stop the unit. curl | bash has a pipe on stdin; -t 1 is stdout.
    # Proven by wrap test: start --no-block.
    if [[ -t 1 ]]; then
        upgrade_wait_unit
        return $?
    fi
    return 0
}

# Follow the oneshot until it leaves activating. SIGINT detaches.
upgrade_wait_unit() {
    local unit_state unit_result journal_pid="" poll saw_activating=0
    trap 'log_info "Detached. Unit continues: journalctl -u github-runner-upgrade.service -f"; trap - INT; return 0' INT
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u github-runner-upgrade.service -f --no-pager --since now &
        journal_pid=$!
    fi
    for poll in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        unit_state=$(systemctl is-active github-runner-upgrade.service 2>/dev/null || true)
        if [[ "$unit_state" == "activating" || "$unit_state" == "active" ]]; then
            saw_activating=1
            break
        fi
        sleep 0.25
    done
    unset poll
    if [[ "$saw_activating" -eq 1 ]]; then
        while true; do
            unit_state=$(systemctl is-active github-runner-upgrade.service 2>/dev/null || true)
            case "$unit_state" in
                activating|active) sleep 2 ;;
                *) break ;;
            esac
        done
    fi
    if [[ -n "$journal_pid" ]]; then
        kill "$journal_pid" 2>/dev/null || true
        wait "$journal_pid" 2>/dev/null || true
    fi
    trap - INT
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
        upgrade_dry_run
        return $?
    fi

    if upgrade_should_wrap "$foreground" "$dry_run"; then
        upgrade_via_unit
        return $?
    fi

    upgrade_foreground "$force"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root upgrade
    load_infra_config
    upgrade_main "$@"
fi
