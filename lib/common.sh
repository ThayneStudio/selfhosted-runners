#!/bin/bash
set -euo pipefail
# Common functions and constants shared across all runner scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1" >&2; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2; }

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"

# Path constants
CONFIG_FILE="/etc/github-runners.conf"
ORG_CONFIG_DIR="/etc/github-runners.d"
SNIPPETS_DIR="/var/lib/vz/snippets"
INSTALL_DIR="/opt/selfhosted-runners"
POOL_DRAIN_FILE="/run/lock/github-runner-drain"
# Where the lifetime guard records when it first saw a VM stopped. A stopped VM
# reports no uptime, so the observation has to come from the host. Per-boot
# state on purpose, unlike the rest of the platform's state: a reboot makes
# every VM freshly observed, which is exactly what it is.
# shellcheck disable=SC2034  # consumed by lib/guard.sh via this shared file
GUARD_STATE_DIR="/run/github-runner-guard"
# Shared/exclusive lock coordinating maintenance mode with in-flight clones.
# clone_runner holds a shared lock for its full lifecycle; runner stop takes an
# exclusive lock so it can wait until all clone activity is quiesced.
POOL_ACTIVITY_LOCK_FILE="/run/lock/github-runner-pool.lock"
# Global lock serializing VMID allocation across reclone.sh/watch.sh/create.sh.
# Scope is narrow: "pick free VMID -> reserve it". A per-VMID reservation
# stays held until qm clone returns, so clone tasks can run with bounded
# parallelism without racing on the same VMID.
# pvesh get /cluster/nextid is not atomic and does not reserve, so without
# this lock two parallel clones reliably pick the same VMID.
VMID_LOCK_FILE="/run/lock/runner-vmid.lock"
VMID_RESERVATION_LOCK_PREFIX="/run/lock/runner-vmid-reserve"
CLONE_SLOT_LOCK_PREFIX="/run/lock/runner-clone-slot"
DEFAULT_CLONE_MAX_PARALLEL=2
# Per-runner slot lock, held across a clone by reclone.sh and watch.sh and
# around a single destroy by guard.sh. Those two build the path inline; the
# constant exists so the guard cannot drift away from the lock they take.
# shellcheck disable=SC2034  # consumed by lib/guard.sh via this shared file
RUNNER_SLOT_LOCK_PREFIX="/run/lock/runner"
# Host-side termination guard (lib/guard.sh). The lifetime ceiling sits above
# the guest's own 6h `shutdown -h +360` so the cooperative path normally wins.
# shellcheck disable=SC2034  # consumed by lib/guard.sh and lib/setup.sh
DEFAULT_MAX_VM_LIFETIME_HOURS=8
# shellcheck disable=SC2034  # consumed by lib/guard.sh and lib/setup.sh
DEFAULT_STOPPED_REAP_MINUTES=10
# shellcheck disable=SC2034  # consumed by lib/setup.sh; empty = exclude nothing
DEFAULT_GUARD_EXCLUDE_VMIDS=""
# Floor under the guard's structural freshness check. A VM whose config was
# written this recently may be a clone still in flight, so it is never reaped —
# this is what lets the guard skip the global pool lock entirely.
# shellcheck disable=SC2034  # consumed by lib/guard.sh via this shared file
GUARD_MIN_CONFIG_AGE_SECONDS=60
# Consecutive runs a VM may be deferred on a busy slot lock before the guard
# stops treating it as normal churn and says so.
# shellcheck disable=SC2034  # consumed by lib/guard.sh via this shared file
GUARD_DEFER_WARN_RUNS=3

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command must be run as root"
        echo "Try: sudo runner ${1:-}" >&2
        exit 1
    fi
}

validate_org_name() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

load_infra_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration not found at $CONFIG_FILE"
        log_error "Run 'runner setup' first."
        exit 1
    fi
    source "$CONFIG_FILE"
    for var in NETWORK_BRIDGE VM_STORAGE TEMPLATE_ID; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Missing required config variable: $var"
            exit 1
        fi
    done
}

load_org_config() {
    local org_name="$1"
    if ! validate_org_name "$org_name"; then
        log_error "Invalid organization name: $org_name"
        exit 1
    fi
    local org_file="$ORG_CONFIG_DIR/${org_name}.conf"
    if [[ ! -f "$org_file" ]]; then
        log_error "Organization '$org_name' not configured. Run 'runner add-org'."
        exit 1
    fi
    source "$org_file"
    if [[ -z "${GITHUB_ORG:-}" || -z "${GITHUB_PAT:-}" ]]; then
        log_error "Invalid org config for '$org_name' — missing GITHUB_ORG or GITHUB_PAT"
        exit 1
    fi
}

pool_is_draining() {
    [[ -e "$POOL_DRAIN_FILE" ]]
}

enable_pool_drain() {
    install -d -m 755 "$(dirname "$POOL_DRAIN_FILE")"
    : > "$POOL_DRAIN_FILE"
}

disable_pool_drain() {
    rm -f "$POOL_DRAIN_FILE"
}

list_orgs() {
    if [[ -d "$ORG_CONFIG_DIR" ]]; then
        for f in "$ORG_CONFIG_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            basename "$f" .conf
        done
    fi
}

select_org() {
    local org_flag="${1:-}"
    local orgs
    mapfile -t orgs < <(list_orgs)

    if [[ ${#orgs[@]} -eq 0 ]]; then
        log_error "No organizations configured. Run 'runner add-org'."
        exit 1
    fi

    if [[ -n "$org_flag" ]]; then
        if ! validate_org_name "$org_flag"; then
            log_error "Invalid organization name: $org_flag"
            exit 1
        fi
        if [[ ! -f "$ORG_CONFIG_DIR/${org_flag}.conf" ]]; then
            log_error "Organization '$org_flag' not configured"
            exit 1
        fi
        echo "$org_flag"
        return
    fi

    if [[ ${#orgs[@]} -eq 1 ]]; then
        echo "${orgs[0]}"
        return
    fi

    echo "" >&2
    echo "Multiple organizations configured:" >&2
    for i in "${!orgs[@]}"; do
        echo "  $((i + 1))) ${orgs[$i]}" >&2
    done
    echo "" >&2

    while true; do
        echo -n "Select organization (number or name): " >&2
        read -r choice </dev/tty || { log_error "No input"; exit 1; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#orgs[@]} ]]; then
            echo "${orgs[$((choice - 1))]}"
            return
        fi
        for org in "${orgs[@]}"; do
            [[ "$org" == "$choice" ]] && { echo "$choice"; return; }
        done
        log_error "Invalid selection: $choice"
    done
}

get_vm_org() {
    local cicustom
    cicustom=$(qm config "$1" 2>/dev/null | grep "^cicustom:" || true)
    if [[ "$cicustom" =~ runner-user-data-([^.]+)\.yaml ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

vm_config_path() {
    local vmid="$1"
    compgen -G "/etc/pve/nodes/*/qemu-server/${vmid}.conf" | head -n 1
}

vmid_in_use() {
    [[ -n "$(vm_config_path "$1")" ]]
}

vmid_reservation_lock_file() {
    printf '%s-%s.lock\n' "$VMID_RESERVATION_LOCK_PREFIX" "$1"
}

reserve_vmid() {
    local vmid="${1:-}"
    local lock_file

    if [[ -z "$vmid" ]]; then
        if [[ "${MIN_VMID:-0}" -gt 0 ]]; then
            vmid="$MIN_VMID"
        else
            vmid=$(pvesh get /cluster/nextid) || return 1
        fi
    fi

    while true; do
        if vmid_in_use "$vmid"; then
            vmid=$((vmid + 1))
            continue
        fi

        lock_file=$(vmid_reservation_lock_file "$vmid")
        exec 203>"$lock_file"
        if flock -n 203; then
            if vmid_in_use "$vmid"; then
                exec 203>&-
                vmid=$((vmid + 1))
                continue
            fi
            RESERVED_VMID="$vmid"
            return 0
        fi
        exec 203>&-
        vmid=$((vmid + 1))
    done
}

release_vmid_reservation() {
    local vmid="${1:-${RESERVED_VMID:-}}"
    exec 203>&- 2>/dev/null || true
    [[ -n "$vmid" ]] && rm -f "$(vmid_reservation_lock_file "$vmid")" 2>/dev/null || true
}

clone_max_parallel() {
    local max="${CLONE_MAX_PARALLEL:-$DEFAULT_CLONE_MAX_PARALLEL}"
    if [[ ! "$max" =~ ^[0-9]+$ || "$max" -lt 1 ]]; then
        max="$DEFAULT_CLONE_MAX_PARALLEL"
    fi
    echo "$max"
}

acquire_clone_slot() {
    local max slot
    max=$(clone_max_parallel)

    while true; do
        pool_is_draining && return 1
        for ((slot = 1; slot <= max; slot++)); do
            exec 204>"${CLONE_SLOT_LOCK_PREFIX}-${slot}.lock"
            if flock -n 204; then
                return 0
            fi
            exec 204>&-
        done
        sleep 1
    done
}

release_clone_slot() {
    exec 204>&- 2>/dev/null || true
}

list_template_base_volids() {
    qm config "$TEMPLATE_ID" 2>/dev/null | awk -F': ' -v storage="$VM_STORAGE:" '
        $1 ~ /^(ide|sata|scsi|virtio)[0-9]+$/ {
            split($2, parts, ",")
            if (index(parts[1], storage "base-") == 1) {
                print parts[1]
            }
        }
    '
}

linked_clone_child_vmid() {
    local volid="$1"
    local child_name="${volid#*:}"
    child_name="${child_name##*/}"
    if [[ "$child_name" =~ ^vm-([0-9]+)-disk- ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

zfs_dataset_from_volid() {
    local volid="$1"
    local path dataset

    command -v zfs >/dev/null 2>&1 || return 1
    path=$(pvesm path "$volid" 2>/dev/null) || return 1
    [[ "$path" == /dev/zvol/* ]] || return 1

    dataset="${path#/dev/zvol/}"
    zfs list -H -o name "$dataset" >/dev/null 2>&1 || return 1
    printf '%s\n' "$dataset"
}

list_template_linked_clone_volids() {
    local storage_list base_volid base_path prefix volid child_name base_dataset dataset origin
    local -A seen=()

    if ! storage_list=$(pvesm list "$VM_STORAGE" 2>/dev/null); then
        log_error "Failed to list storage volumes on $VM_STORAGE"
        return 1
    fi
    [[ -n "$storage_list" ]] || return 0

    while read -r base_volid; do
        [[ -n "$base_volid" ]] || continue
        base_path="${base_volid#*:}"
        prefix="${VM_STORAGE}:${base_path}/"

        while read -r volid _; do
            [[ "$volid" == "$prefix"* ]] || continue
            child_name="${volid#$prefix}"
            [[ "$child_name" =~ ^vm-[0-9]+-disk- ]] || continue
            [[ -n "${seen[$volid]:-}" ]] && continue
            seen["$volid"]=1
            printf '%s\n' "$volid"
        done <<< "$storage_list"
    done < <(list_template_base_volids)

    # ZFS linked clones are sibling zvols, not nested volids. They point at
    # the template base volume snapshot via the ZFS origin property.
    while read -r base_volid; do
        [[ -n "$base_volid" ]] || continue
        base_dataset=$(zfs_dataset_from_volid "$base_volid") || continue

        while read -r volid _; do
            [[ "$volid" == "$VM_STORAGE:vm-"* ]] || continue
            [[ -n "${seen[$volid]:-}" ]] && continue

            dataset=$(zfs_dataset_from_volid "$volid") || continue
            origin=$(zfs get -H -o value origin "$dataset" 2>/dev/null || true)
            [[ "$origin" == "$base_dataset@"* ]] || continue

            seen["$volid"]=1
            printf '%s\n' "$volid"
        done <<< "$storage_list"
    done < <(list_template_base_volids)
}

cleanup_template_orphan_volumes() {
    local child_vmid config_path volid
    local -a child_volids=()
    local -a blocked_volids=()
    local -a freed_volids=()

    local child_list
    if ! child_list=$(list_template_linked_clone_volids); then
        return 1
    fi
    if [[ -n "$child_list" ]]; then
        mapfile -t child_volids <<< "$child_list"
    fi
    [[ ${#child_volids[@]} -gt 0 ]] || return 0

    log_info "Checking ${#child_volids[@]} linked-clone child volume(s) for template $TEMPLATE_ID..."

    for volid in "${child_volids[@]}"; do
        child_vmid=$(linked_clone_child_vmid "$volid")
        config_path=""
        [[ -n "$child_vmid" ]] && config_path=$(vm_config_path "$child_vmid")

        if [[ -n "$config_path" ]]; then
            log_warn "Template child volume still has a VM config: $volid ($config_path)"
            blocked_volids+=("$volid")
            continue
        fi

        log_info "Freeing orphaned template child volume: $volid"
        if ! pvesm free "$volid"; then
            log_error "Failed to free orphaned template child volume: $volid"
            return 1
        fi
        freed_volids+=("$volid")
    done

    if [[ ${#freed_volids[@]} -gt 0 ]]; then
        log_info "Freed ${#freed_volids[@]} orphaned linked-clone volume(s) for template $TEMPLATE_ID."
    fi

    if [[ ${#blocked_volids[@]} -gt 0 ]]; then
        log_error "Template $TEMPLATE_ID still has linked-clone child volume(s) with VM configs."
        log_error "Destroy those VMs/templates before deleting the template."
        return 2
    fi

    return 0
}

# Sweep zvols on $VM_STORAGE whose VMID has no /etc/pve config — leftovers from
# clones that failed before writing config (or whose _fail cleanup couldn't
# fully reap). Holds the pool activity lock exclusive non-blocking so it can
# never race a clone in progress. Scoped to vmid >= MIN_VMID and != TEMPLATE_ID
# so non-runner VMs on the same storage are never touched.
cleanup_runner_orphan_volumes() {
    local min_vmid="${MIN_VMID:-$((TEMPLATE_ID + 1))}"

    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    if ! flock -n -x 202; then
        exec 202>&-
        return 0
    fi

    local volid vmid freed=0
    while IFS= read -r volid; do
        [[ -n "$volid" ]] || continue
        if [[ "$volid" =~ (:|/)vm-([0-9]+)-(disk-[0-9]+|cloudinit)$ ]]; then
            vmid="${BASH_REMATCH[2]}"
        else
            continue
        fi
        [[ "$vmid" -ge "$min_vmid" && "$vmid" -ne "$TEMPLATE_ID" ]] || continue
        [[ -z "$(vm_config_path "$vmid")" ]] || continue
        log_info "[orphan-sweep] freeing $volid (vmid $vmid has no config)"
        if pvesm free "$volid" 2>/dev/null; then
            freed=$((freed + 1))
        else
            log_warn "[orphan-sweep] pvesm free $volid failed"
        fi
    done < <(pvesm list "$VM_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}')

    [[ "$freed" -gt 0 ]] && log_info "[orphan-sweep] reaped $freed orphan volume(s)"
    exec 202>&-
}

deregister_runner() {
    local org="$1" runner_name="$2"
    local org_file="$ORG_CONFIG_DIR/${org}.conf"
    [[ -f "$org_file" ]] || return 0

    local pat="" github_org=""
    pat=$(source "$org_file" && echo "$GITHUB_PAT") || return 0
    github_org=$(source "$org_file" && echo "$GITHUB_ORG") || return 0
    [[ -n "$pat" && -n "$github_org" ]] || return 0

    local runner_id
    runner_id=$(curl -sf --max-time 10 \
        -H "Accept: application/vnd.github.v3+json" \
        --config <(printf 'header = "Authorization: token %s"\n' "$pat") \
        "https://api.github.com/orgs/${github_org}/actions/runners?per_page=100" 2>/dev/null \
        | jq --arg name "$runner_name" -r '.runners[] | select(.name == $name) | .id' 2>/dev/null) || return 0

    [[ -n "$runner_id" && "$runner_id" != "null" && "$runner_id" =~ ^[0-9]+$ ]] || return 0

    curl -sf --max-time 10 -X DELETE \
        -H "Accept: application/vnd.github.v3+json" \
        --config <(printf 'header = "Authorization: token %s"\n' "$pat") \
        "https://api.github.com/orgs/${github_org}/actions/runners/${runner_id}" 2>/dev/null || return 0
}

# --- Shared runner VM helpers ---

# Deterministic MAC from name. Locally-administered unicast (02:xx:xx:xx:xx:xx).
generate_mac() {
    echo -n "$1" | md5sum | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\).*/02:\1:\2:\3:\4:\5/'
}

# Clone template, configure cloud-init, set hookscript, start VM.
# Returns VMID on stdout. Returns 1 on failure (cleans up partial clone).
clone_runner() {
    local name="$1" org="$2" vmid="${3:-}"
    local RESERVED_VMID=""

    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -s 202

    if pool_is_draining; then
        log_warn "clone_runner: pool drain active, refusing to create $name"
        exec 202>&-
        return 1
    fi

    # Cleanup helper: destroy VM (only if it belongs to us), remove snippet, and
    # sweep orphan zvols at this VMID. The ownership check prevents touching
    # another process's VM on VMID collision. Orphan sweep runs unconditionally
    # for our-VMID and no-owner cases because qm destroy --purge can silently
    # leave residue (busy ZFS dataset, etc.) and a clone that fails before
    # writing config leaves zvols with no VM to attach to.
    _fail() {
        local owner
        owner=$(qm config "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null | awk '/^name:/{print $2}') || true

        if [[ -n "$owner" && "$owner" != "$name" ]]; then
            return 0
        fi

        rm -f "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml"

        if [[ "$owner" == "$name" ]]; then
            local destroy_err; destroy_err=$(mktemp)
            if ! qm destroy "$vmid" --purge 200>&- 201>&- 202>&- 203>&- 204>&- 2>"$destroy_err"; then
                log_warn "qm destroy $vmid failed: $(tr '\n' ' ' < "$destroy_err")"
            fi
            rm -f "$destroy_err"
        fi

        local volid
        while read -r volid; do
            [[ -n "$volid" ]] || continue
            pvesm free "$volid" 2>/dev/null || log_warn "Failed to free orphan volume $volid"
        done < <(
            pvesm list "$VM_STORAGE" 2>/dev/null |
                awk -v v="$vmid" 'NR>1 && $1 ~ ("(^|:|/)vm-" v "-(disk-[0-9]+|cloudinit)$") {print $1}'
        )
    }

    # Acquire global VMID allocation lock only long enough to reserve one VMID.
    # The per-VMID reservation stays held until qm clone returns, which lets
    # other workers reserve different VMIDs and clone with bounded parallelism.
    # Timeout is intentionally high because a cold pool refill can queue many
    # workers behind the same allocation lock.
    # Callers (reclone.sh/watch.sh) must acquire their per-slot fd 200 lock
    # before entering clone_runner to avoid deadlock on lock order inversion.
    exec 201>"$VMID_LOCK_FILE"
    if ! flock -w 300 201; then
        log_error "clone_runner: timed out acquiring VMID lock for $name"
        exec 201>&-
        exec 202>&-
        return 1
    fi

    if [[ -z "$vmid" ]]; then
        if ! reserve_vmid; then
            exec 201>&-
            exec 202>&-
            return 1
        fi
        vmid="$RESERVED_VMID"
    else
        # Caller pre-allocated. Re-verify under lock — a concurrent process
        # could have grabbed it between the caller's check and now.
        if ! reserve_vmid "$vmid"; then
            exec 201>&-
            exec 202>&-
            return 1
        fi
        vmid="$RESERVED_VMID"
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        exec 201>&-
        release_vmid_reservation "$vmid"
        exec 202>&-
        return 1
    fi

    # VMID is reserved; release the allocator so other workers can reserve and
    # clone different VMIDs while this clone runs.
    exec 201>&-

    if ! acquire_clone_slot; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        release_vmid_reservation "$vmid"
        exec 202>&-
        return 1
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        release_clone_slot
        release_vmid_reservation "$vmid"
        exec 202>&-
        return 1
    fi

    # Keep maintenance locks in this shell only. Proxmox helper children can
    # spawn long-lived kvm processes; those must not inherit runner lock fds.
    # Capture stderr so the actual ZFS/Proxmox error surfaces under
    # `journalctl -t github-runner` instead of being buried under the service
    # unit log (which the operator does not look at first).
    local clone_err; clone_err=$(mktemp)
    if ! qm clone "$TEMPLATE_ID" "$vmid" --name "$name" 200>&- 201>&- 202>&- 203>&- 204>&- 2>"$clone_err"; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && log_error "qm clone $vmid: $line"
        done < "$clone_err"
        rm -f "$clone_err"
        release_clone_slot
        _fail
        release_vmid_reservation "$vmid"
        exec 202>&-
        return 1
    fi
    rm -f "$clone_err"
    release_clone_slot

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active after cloning $name, cleaning up VM $vmid"
        _fail
        release_vmid_reservation "$vmid"
        exec 202>&-
        return 1
    fi

    # Clone succeeded — VMID is now claimed in Proxmox.
    release_vmid_reservation "$vmid"

    # Deterministic MAC
    local mac net0
    mac=$(generate_mac "$name")
    net0=$(qm config "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&- | grep '^net0:' | sed 's/^net0: //') || true
    if [[ -n "$net0" ]]; then
        net0=$(echo "$net0" | sed "s/virtio=[^,]*/virtio=$mac/")
        qm set "$vmid" --net0 "$net0" 200>&- 201>&- 202>&- 203>&- 204>&- || { _fail; exec 202>&-; return 1; }
    fi

    # Cloud-init
    cat > "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" << EOF
instance-id: "$name"
local-hostname: "$name"
EOF
    chmod 600 "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml"

    qm set "$vmid" --cicustom "user=local:snippets/runner-user-data-${org}.yaml,meta=local:snippets/runner-${vmid}-meta.yaml" \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; exec 202>&-; return 1; }
    qm set "$vmid" --ipconfig0 ip=dhcp \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; exec 202>&-; return 1; }
    [[ -z "${DNS_SERVERS:-}" ]] || qm set "$vmid" --nameserver "$DNS_SERVERS" \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; exec 202>&-; return 1; }
    qm set "$vmid" --ciuser runner \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; exec 202>&-; return 1; }

    # Hookscript for auto-destroy on shutdown
    if [[ -f "$SNIPPETS_DIR/runner-hookscript.sh" ]]; then
        qm set "$vmid" --hookscript "local:snippets/runner-hookscript.sh" \
            200>&- \
            201>&- \
            202>&- \
            203>&- \
            204>&- \
            || log_warn "Failed to set hookscript on $vmid — VM will not auto-recycle"
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active while configuring $name, cleaning up VM $vmid"
        _fail
        exec 202>&-
        return 1
    fi

    # Start
    if ! qm start "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&-; then
        _fail
        exec 202>&-
        return 1
    fi

    exec 202>&-
    echo "$vmid"
}
