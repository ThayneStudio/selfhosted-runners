#!/bin/bash
set -euo pipefail
# Safety-net watcher: fills missing runner slots in parallel.
# The hookscript handles steady-state re-cloning. This is a fallback
# for initial pool fill and missed re-clones.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

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
ALL_VM_NAMES=$(qm list 2>/dev/null | awk 'NR>1 {print $2}') || exit 0

# Collect ALL missing slots across ALL orgs
MISSING=()
mapfile -t ORGS < <(list_orgs)
for org in "${ORGS[@]}"; do
    org_file="$ORG_CONFIG_DIR/${org}.conf"
    [[ -f "$org_file" ]] || continue

    count=$(grep '^RUNNER_COUNT=' "$org_file" | head -1 | sed 's/^RUNNER_COUNT=//' | tr -d '"') || true
    prefix=$(grep '^RUNNER_PREFIX=' "$org_file" | head -1 | sed 's/^RUNNER_PREFIX=//' | tr -d '"') || true
    count="${count:-0}"
    prefix="${prefix:-runner}"
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || continue
    [[ -f "$SNIPPETS_DIR/runner-user-data-${org}.yaml" ]] || continue

    for n in $(seq 1 "$count"); do
        slot="${prefix}-${n}"
        echo "$ALL_VM_NAMES" | grep -qxF "$slot" || MISSING+=("$slot $org")
    done
done

[[ ${#MISSING[@]} -gt 0 ]] || exit 0

WATCH_MAX_PARALLEL=6

wait_for_watch_slot() {
    while (( $(jobs -rp | wc -l) >= WATCH_MAX_PARALLEL )); do
        wait -n || true
    done
}

log_info "[watch] Filling ${#MISSING[@]} missing slot(s) with up to ${WATCH_MAX_PARALLEL} parallel worker(s)"

# VMID allocation is serialized inside clone_runner via the global
# $VMID_LOCK_FILE flock, so parallel subshells can safely pick their own.
for entry in "${MISSING[@]}"; do
    wait_for_watch_slot
    slot="${entry%% *}"
    org="${entry##* }"
    (
        # Per-runner lock prevents races with reclone.sh on the same slot
        exec 200>"/run/lock/runner-${slot}.lock"
        flock -n 200 || exit 0

        # Re-check: another process may have filled this slot
        if qm list 200>&- 2>/dev/null | awk 'NR>1{print $2}' | grep -qxF "$slot"; then
            exit 0
        fi
        if ! load_org_config "$org" 2>/dev/null; then
            log_warn "[watch] Skipping $slot — bad config for $org"
            exit 0
        fi
        if clone_runner "$slot" "$org" >/dev/null; then
            log_info "[watch] Created $slot"
        else
            log_warn "[watch] Failed to create $slot"
        fi
    ) &
done

# Wait for all background jobs
wait || true
