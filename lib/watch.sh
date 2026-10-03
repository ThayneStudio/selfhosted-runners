#!/bin/bash
set -euo pipefail
# Safety-net watcher: fills missing runner slots and reclaims dead runner VMs
# in parallel. The hookscript handles steady-state re-cloning. This is the
# fallback for the initial pool fill and for every VM the hookscript missed:
# - stopped, with nothing recycling it: a host crash or reboot, a pool drain,
#   a reclone that was killed or gave up, a clone cut off before it started,
#   a missing hookscript;
# - still running long after the guest should have shut itself down;
# - started again after its one boot (vzdump after a stop-mode backup,
#   `qm reboot`), which leaves a VM with no runner.

WATCH_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=common.sh
source "$WATCH_LIB_DIR/common.sh"
# shellcheck source=recycle.sh
source "$WATCH_LIB_DIR/recycle.sh"

WATCH_MAX_PARALLEL=6
# The guest powers itself off 360 minutes after boot. The margin also covers
# a guest that re-arms that shutdown when a job starts (up to 6 hours idle,
# then a 6-hour job). A VM up longer than this lost its shutdown: a hung
# guest, or a job that cancelled it.
RUNNER_MAX_UPTIME=$(( (12 * 60 + 30) * 60 ))
# A runner VM boots once. A QEMU process this much younger than the VM's
# clone was started again, and cloud-init never starts the runner twice.
RUNNER_RESTART_SLACK=600
# A stopped VM is reclaimed only after this long, so the hookscript's reclone
# normally gets it first and counts its death for the backoff.
STOPPED_GRACE=60

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

# Worker: recycle runner VM $1 named $2, which the scan found dead for reason
# $3 (stopped, overdue or restarted). Runs in its own subshell. Everything is
# checked again under the slot lock, so a reclone, `runner destroy` or clone
# that holds the slot wins, and only a VM that carries this tool's snippet or
# clone-time marker is touched.
reclaim_runner_vm() {
    local vmid="$1" name="$2" reason="$3" config org status_out status uptime age
    exec 200>"$(slot_lock_file "$name")"
    flock -n 200 || return 0
    if pool_is_draining; then
        return 0
    fi

    config=$(qm config "$vmid" 200>&- 2>/dev/null) || return 0
    [[ "$(awk '/^name:/{print $2; exit}' <<< "$config")" == "$name" ]] || return 0
    if grep -qE '^(lock:|template: 1)' <<< "$config"; then
        return 0
    fi
    org=$(get_vm_org "$vmid")
    if [[ "$org" == "unknown" ]]; then
        log_warn "[watch] $name (VMID $vmid) is $reason but carries no selfhosted-runners snippet or marker; leaving it. If it is a leftover clone, remove it with: qm destroy $vmid"
        return 0
    fi

    status_out=$(qm status "$vmid" --verbose 200>&- 2>/dev/null) || return 0
    status=$(awk '/^status:/{print $2; exit}' <<< "$status_out")
    uptime=$(awk '/^uptime:/{print $2; exit}' <<< "$status_out")
    [[ "$uptime" =~ ^[0-9]+$ ]] || uptime=0
    case "$reason" in
        stopped)
            [[ "$status" == "stopped" ]] || return 0
            ;;
        overdue)
            [[ "$status" == "running" ]] || return 0
            (( uptime > RUNNER_MAX_UPTIME )) || return 0
            ;;
        restarted)
            [[ "$status" == "running" ]] || return 0
            age=$(runner_vm_age "$vmid")
            [[ -n "$age" ]] || return 0
            (( age - uptime > RUNNER_RESTART_SLACK )) || return 0
            ;;
        *) return 0 ;;
    esac

    # As in reclone.sh: hold shared pool activity so `runner stop` waits for
    # the destroy and the refill. A stop already waiting means a drain is
    # starting, so do not queue behind it.
    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -n -s 202 || return 0
    POOL_ACTIVITY_LOCK_HELD=1
    if pool_is_draining; then
        return 0
    fi

    case "$reason" in
        stopped) log_warn "[watch] Reclaiming $name (VMID $vmid): stopped and not recycled" ;;
        overdue) log_warn "[watch] Reclaiming $name (VMID $vmid): up $((uptime / 3600))h$((uptime % 3600 / 60))m, long past the guest's own shutdown" ;;
        restarted) log_warn "[watch] Reclaiming $name (VMID $vmid): started again after its first boot, so it has no runner" ;;
    esac
    if [[ "$status" == "running" ]] && ! qm stop "$vmid" 200>&- 202>&-; then
        log_warn "[watch] Failed to stop $name (VMID $vmid); retrying next tick"
        return 0
    fi
    if ! destroy_runner_vm "$vmid"; then
        log_warn "[watch] Failed to destroy $name (VMID $vmid); retrying next tick"
        return 0
    fi
    refill_runner_slot "$name" "$org" "[watch]" "$(runner_vm_kind "$config")" || true
}

watch_main() {
    local vm_table now vmid name status uptime lock template age since key prefix slot entry reason n org
    local stopped_state tmp candidate
    local -a orgs=() prefixes=() slots=() missing=() reclaim=() stopped_now=()
    local -A vm_names=() stopped_since=()

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

    # One read of every VM's name, status, QEMU uptime and config lock.
    if ! vm_table=$(pvesh get /nodes/localhost/qemu --output-format json 2>/dev/null \
        | jq -r '.[] | [.vmid, (.name // "-"), (.status // "-"), (.uptime // 0), (.lock // "-"), (.template // 0)] | @tsv'); then
        log_warn "[watch] Could not list VMs; skipping this tick"
        exit 0
    fi

    # Every configured slot, and every org's prefix.
    mapfile -t orgs < <(list_orgs)
    for org in "${orgs[@]}"; do
        [[ -f "$ORG_CONFIG_DIR/${org}.conf" ]] || continue
        read_org_slots "$org"
        prefixes+=("$ORG_SLOT_PREFIX")
        if [[ -z "$ORG_SLOT_COUNT" ]] || (( ORG_SLOT_COUNT == 0 )); then
            continue
        fi
        for n in $(seq 1 "$ORG_SLOT_COUNT"); do
            slots+=("${ORG_SLOT_PREFIX}-${n} $org")
        done
    done

    # When each stopped runner VM was first seen stopped, from earlier ticks.
    stopped_state="$SLOT_STATE_DIR/watch-stopped"
    while read -r vmid name since; do
        [[ "$vmid" =~ ^[0-9]+$ && "$since" =~ ^[0-9]+$ ]] || continue
        stopped_since["$vmid $name"]=$since
    done <<< "$(cat "$stopped_state" 2>/dev/null || true)"

    now=$(date +%s)
    while IFS=$'\t' read -r vmid name status uptime lock template; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        vm_names["$name"]=1
        [[ "$template" != 1 && "$vmid" != "$TEMPLATE_ID" ]] || continue
        [[ "$uptime" =~ ^[0-9]+$ ]] || uptime=0

        # Runner VMs have the meta snippet clone_runner writes before
        # --cicustom. A clone cut off before that has only its slot name.
        candidate=0
        if [[ -e "$SNIPPETS_DIR/runner-${vmid}-meta.yaml" ]]; then
            candidate=1
        elif [[ "$status" == "stopped" ]]; then
            for prefix in "${prefixes[@]}"; do
                if slot_number "$name" "$prefix" > /dev/null; then
                    candidate=1
                    break
                fi
            done
        fi
        (( candidate )) || continue

        if [[ "$status" == "stopped" ]]; then
            key="$vmid $name"
            since=${stopped_since[$key]:-$now}
            stopped_now+=("$key $since")
            if [[ "$lock" != "-" ]]; then
                if [[ -z "${stopped_since[$key]:-}" ]]; then
                    log_info "[watch] $name (VMID $vmid) is stopped and locked ($lock); reclaiming it once the lock is gone"
                fi
                continue
            fi
            if (( now - since >= STOPPED_GRACE )); then
                reclaim+=("$vmid $name stopped")
            fi
        elif [[ "$status" == "running" && "$lock" == "-" ]]; then
            if (( uptime > RUNNER_MAX_UPTIME )); then
                reclaim+=("$vmid $name overdue")
                continue
            fi
            age=$(runner_vm_age "$vmid")
            if [[ -n "$age" ]] && (( age - uptime > RUNNER_RESTART_SLACK )); then
                reclaim+=("$vmid $name restarted")
            fi
        fi
    done <<< "$vm_table"

    if (( ${#stopped_now[@]} > 0 )); then
        if install -d -m 700 "$SLOT_STATE_DIR" && tmp=$(mktemp "$SLOT_STATE_DIR/.watch.XXXXXX"); then
            if ! printf '%s\n' "${stopped_now[@]}" > "$tmp" || ! mv -f "$tmp" "$stopped_state"; then
                rm -f "$tmp"
            fi
        fi
    else
        rm -f "$stopped_state"
    fi

    for entry in "${slots[@]}"; do
        slot="${entry%% *}"
        [[ -z "${vm_names[$slot]:-}" ]] || continue
        # A slot that keeps failing is retried when its backoff ends,
        # not on every tick.
        slot_is_held "$slot" && continue
        missing+=("$entry")
    done

    (( ${#missing[@]} + ${#reclaim[@]} > 0 )) || exit 0

    if (( ${#reclaim[@]} > 0 )); then
        log_info "[watch] Reclaiming ${#reclaim[@]} dead runner VM(s)"
    fi
    if (( ${#missing[@]} > 0 )); then
        log_info "[watch] Filling ${#missing[@]} missing slot(s) with up to ${WATCH_MAX_PARALLEL} parallel worker(s)"
    fi

    # VMID allocation is serialized inside clone_runner via the global
    # $VMID_LOCK_FILE flock, so parallel subshells can safely pick their own.
    for entry in "${reclaim[@]}"; do
        wait_for_watch_slot
        read -r vmid name reason <<< "$entry"
        ( reclaim_runner_vm "$vmid" "$name" "$reason" ) &
    done
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
