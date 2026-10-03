#!/bin/bash
set -euo pipefail
# Safety-net watcher: fills missing runner slots in parallel.
# The hookscript handles steady-state re-cloning. This is a fallback
# for initial pool fill and missed re-clones.

WATCH_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=common.sh
source "$WATCH_LIB_DIR/common.sh"
# shellcheck source=recycle.sh
source "$WATCH_LIB_DIR/recycle.sh"

WATCH_MAX_PARALLEL=6

wait_for_watch_slot() {
    while (( $(jobs -rp | wc -l) >= WATCH_MAX_PARALLEL )); do
        wait -n || true
    done
}

# Worker: clone missing slot $1 for org $2. Runs in its own subshell.
fill_runner_slot() {
    local slot="$1" org="$2"
    # Per-runner lock prevents races with reclone.sh on the same slot
    exec 200>"$(slot_lock_file "$slot")"
    flock -n 200 || return 0

    # Re-check: another process may have filled or held this slot
    if qm list 200>&- 2>/dev/null | awk 'NR>1{print $2}' | grep -qxF "$slot"; then
        return 0
    fi
    if slot_is_held "$slot"; then
        return 0
    fi
    if ! load_org_config "$org" 2>/dev/null; then
        log_warn "[watch] Skipping $slot — bad config for $org"
        return 0
    fi
    if clone_runner "$slot" "$org" >/dev/null; then
        slot_note_clone_success "$slot"
        log_info "[watch] Created $slot"
    else
        # A drain refuses the clone on purpose; that is not the slot failing.
        pool_is_draining || slot_note_clone_failure "$slot"
        log_warn "[watch] Failed to create $slot"
    fi
}

watch_main() {
    local all_vm_names org org_file count prefix n slot entry
    local -a orgs=() missing=()

    require_root "watch"

    [[ -f "$CONFIG_FILE" ]] || exit 0
    load_infra_config

    if pool_is_draining; then
        log_info "[watch] Pool drain active — skipping refill"
        exit 0
    fi

    # Template must be ready
    qm config "$TEMPLATE_ID" 2>/dev/null | grep -q "^template: 1" || exit 0

    # Reap zvols left behind by failed clones before computing missing slots, so
    # VMIDs whose only residue was an orphan zvol become available for refill.
    cleanup_runner_orphan_volumes

    # Snapshot all VM names once
    all_vm_names=$(qm list 2>/dev/null | awk 'NR>1 {print $2}') || exit 0

    # Collect ALL missing slots across ALL orgs
    mapfile -t orgs < <(list_orgs)
    for org in "${orgs[@]}"; do
        org_file="$ORG_CONFIG_DIR/${org}.conf"
        [[ -f "$org_file" ]] || continue

        count=$(grep '^RUNNER_COUNT=' "$org_file" | head -1 | sed 's/^RUNNER_COUNT=//' | tr -d '"') || true
        prefix=$(grep '^RUNNER_PREFIX=' "$org_file" | head -1 | sed 's/^RUNNER_PREFIX=//' | tr -d '"') || true
        count="${count:-0}"
        prefix="${prefix:-runner}"
        [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || continue

        for n in $(seq 1 "$count"); do
            slot="${prefix}-${n}"
            echo "$all_vm_names" | grep -qxF "$slot" && continue
            # A slot that keeps failing is retried when its backoff ends,
            # not on every tick.
            slot_is_held "$slot" && continue
            missing+=("$slot $org")
        done
    done

    [[ ${#missing[@]} -gt 0 ]] || exit 0

    log_info "[watch] Filling ${#missing[@]} missing slot(s) with up to ${WATCH_MAX_PARALLEL} parallel worker(s)"

    # VMID allocation is serialized inside clone_runner via the global
    # $VMID_LOCK_FILE flock, so parallel subshells can safely pick their own.
    for entry in "${missing[@]}"; do
        wait_for_watch_slot
        slot="${entry%% *}"
        org="${entry##* }"
        ( fill_runner_slot "$slot" "$org" ) &
    done

    # Wait for all background jobs
    wait || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    watch_main "$@"
fi
