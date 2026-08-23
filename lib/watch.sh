#!/bin/bash
set -euo pipefail
# Safety-net watcher: fills missing runner slots in parallel.
# The hookscript handles steady-state re-cloning. This is a fallback
# for initial pool fill and missed re-clones.

# shellcheck source=common.sh
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

# Workers report clone failures here rather than notifying individually. The
# timer fires every 30s and a template or PAT problem fails every slot at once,
# so one notification per run is the difference between an alert and a flood.
# /run is tmpfs; rm first in case a killed run left this PID's file behind, and
# trap so an abnormal exit does not leave one for the next PID to inherit.
# The trap is safe with the workers below: bash does not run an inherited EXIT
# trap in an async ( ) & subshell.
FAILED_SLOTS="/run/github-runner-watch-failures.$$"
rm -f "$FAILED_SLOTS"
trap 'rm -f "$FAILED_SLOTS"' EXIT

# VMID allocation is serialized inside clone_runner via the global
# $VMID_LOCK_FILE flock, so parallel subshells can safely pick their own.
for entry in "${MISSING[@]}"; do
    wait_for_watch_slot
    slot="${entry%% *}"
    org="${entry##* }"
    (
        # Per-runner lock prevents races with reclone.sh on the same slot
        exec 200>"${RUNNER_SLOT_LOCK_PREFIX}-${slot}.lock"
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
            echo "$slot" >> "$FAILED_SLOTS"
        fi
    ) &
done

# Wait for all background jobs
wait || true

if [[ -s "$FAILED_SLOTS" ]]; then
    mapfile -t FAILED < "$FAILED_SLOTS"
    # Every attempted slot failing is a pool-wide condition — bad template,
    # revoked PAT, storage full — and has to page even at
    # NOTIFY_MIN_SEVERITY=error. A partial fill is a flaky clone that the next
    # timer tick will retry on its own.
    SEVERITY="warn"
    [[ "${#FAILED[@]}" -lt "${#MISSING[@]}" ]] || SEVERITY="error"
    notify "$SEVERITY" clone.failed \
        "watcher could not fill ${#FAILED[@]} of ${#MISSING[@]} runner slot(s)" \
        "slots: ${FAILED[*]} (template $TEMPLATE_ID)"
fi
