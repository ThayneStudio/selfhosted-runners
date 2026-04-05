#!/bin/bash
set -euo pipefail
# Safety-net watcher: fills missing runner slots in parallel.
# The hookscript handles steady-state re-cloning. This is a fallback
# for initial pool fill and missed re-clones.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "watch"

[[ -f "$CONFIG_FILE" ]] || exit 0
load_infra_config

# Template must be ready
qm config "$TEMPLATE_ID" 2>/dev/null | grep -q "^template: 1" || exit 0

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

log_info "[watch] Filling ${#MISSING[@]} missing slot(s) in parallel"

for entry in "${MISSING[@]}"; do
    slot="${entry%% *}"
    org="${entry##* }"
    (
        # Re-check: reclone.sh or another process may have filled this slot
        if qm list 2>/dev/null | awk '{print $2}' | grep -qxF "$slot"; then
            exit 0
        fi
        load_org_config "$org" 2>/dev/null || { log_warn "[watch] Bad config for $org, skipping $slot"; exit 0; }
        clone_runner "$slot" "$org" >/dev/null \
            && log_info "[watch] Created $slot" \
            || log_warn "[watch] Failed to create $slot"
    ) &
done

# Wait for all background jobs — || true prevents set -e from killing us if any subshell fails
wait || true
