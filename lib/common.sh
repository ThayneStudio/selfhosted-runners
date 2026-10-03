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

# A VM name `qm clone --name` accepts (Proxmox's dns-name format): dot-separated
# labels of letters, digits and hyphens, each starting and ending with a letter
# or digit. Check a runner name before minting a JIT config for it — the mint
# registers the runner on GitHub, and a name qm rejects can never be cloned.
validate_runner_name() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
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
    # /run/lock is 1777 on Debian. mkdir -p leaves an existing directory's
    # mode alone; install -d -m 755 would chmod it and lock out non-root users.
    mkdir -p "$(dirname "$POOL_DRAIN_FILE")"
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

# Prints N when $1 is slot <prefix $2>-N as the watcher names it (no leading
# zeros); fails for any other name, such as a manual runner-01.
slot_number() {
    local name="$1" prefix="$2" n
    [[ -n "$prefix" && "$name" == "${prefix}-"* ]] || return 1
    n="${name#"${prefix}-"}"
    [[ "$n" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
    printf '%s\n' "$n"
}

# Prints the org of runner VM $1, or "unknown". $2, when given, is the VM's
# config as the caller already read it.
get_vm_org() {
    local config cicustom description
    local marker_re='^description: selfhosted-runners org=([a-zA-Z0-9-]+)'
    if (( $# > 1 )); then
        config="$2"
    else
        config=$(qm config "$1" 2>/dev/null) || true
    fi
    cicustom=$(grep -m1 '^cicustom:' <<< "$config") || true
    description=$(grep -m1 '^description:' <<< "$config") || true
    # New per-VM snippet: runner-<vmid>-user-<org>.yaml (org has no dots).
    # Legacy per-org snippet: runner-user-data-<org>.yaml (kept as a fallback so
    # VMs created before the token refactor stay identifiable/destroyable).
    # The two are mutually exclusive: legacy names have no digits after "runner-".
    # Last, the marker clone_runner passes to qm clone: a clone cut off before
    # --cicustom carries only that, and would otherwise hold its slot name
    # with no runner command able to see or remove it.
    if [[ "$cicustom" =~ runner-[0-9]+-user-([a-zA-Z0-9-]+)\.yaml ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$cicustom" =~ runner-user-data-([^.]+)\.yaml ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$description" =~ $marker_re ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

# Guest configs of every cluster node.
PVE_NODES_DIR="/etc/pve/nodes"

# VMIDs are cluster-wide and shared by VMs and containers. A container's
# LVM-thin, LVM and RBD volumes are named vm-<ctid>-disk-N like a VM's, so a
# VMID counts as taken when either guest type has a config for it on any node.
vm_config_path() {
    local vmid="$1"
    compgen -G "$PVE_NODES_DIR/*/qemu-server/${vmid}.conf" | head -n 1 ||
        compgen -G "$PVE_NODES_DIR/*/lxc/${vmid}.conf" | head -n 1
}

vmid_in_use() {
    [[ -n "$(vm_config_path "$1")" ]]
}

# pmxcfs serves /etc/pve. While it restarts (every pve-cluster upgrade
# restarts it) /etc/pve is an empty directory, and after a crash it cannot
# be read, so vm_config_path finds no config for any guest. Every node has a
# directory in nodes, and only a live pmxcfs can list them. A lookup proves
# less: after a crash the kernel can answer one from its cache for up to a
# second, such as one for /etc/pve/local, the link PVE's own
# check_cfs_is_mounted tests.
pve_cfs_serving() {
    compgen -G "$PVE_NODES_DIR/*" > /dev/null
}

# vm_config_path for callers that free VMID $1's volumes when it prints
# nothing. Finding no config proves nothing unless pmxcfs served /etc/pve
# both before and after the lookup, so this fails otherwise, and the caller
# stops freeing. vmid_in_use stays a plain lookup: reserve_vmid steps past
# every VMID in use, and would never stop while pmxcfs is down if a lookup
# that failed counted as in use.
vm_config_path_checked() {
    pve_cfs_serving || return 1
    vm_config_path "$1" || true
    pve_cfs_serving
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
    # Closing an fd that is not open is silent and returns 0. A redirection
    # on a bare exec applies to this shell for good: 2>/dev/null here would
    # hide every later log line.
    exec 203>&-
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
    # No 2>/dev/null: see release_vmid_reservation.
    exec 204>&-
}

list_template_base_volids() {
    local template_id="${1:-$TEMPLATE_ID}"
    qm config "$template_id" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null | base_volids_in_config
}

# Base volumes on $VM_STORAGE among the disks of the VM config on stdin.
base_volids_in_config() {
    awk -F': ' -v storage="$VM_STORAGE:" '
        $1 ~ /^(ide|sata|scsi|virtio)[0-9]+$/ {
            split($2, parts, ",")
            volume = substr(parts[1], length(storage) + 1)
            if (index(parts[1], storage) == 1 && volume ~ /^([0-9]+\/)?base-/) {
                print parts[1]
            }
        }
    '
}

# Base volumes of the runner templates: TEMPLATE_ID, and each template the
# rebake retired but has not destroyed yet (lib/rebake.sh). The rebake also
# keeps ids that are no longer runner templates on that list, so a retired id
# counts only while it is a template named ubuntu-cloud-template, the check
# retire_retired_templates makes before it destroys one.
runner_template_base_volids() {
    local retired_file="${RETIRED_TEMPLATES_FILE:-/var/lib/github-runners/retired-templates}"
    local id config
    list_template_base_volids "$TEMPLATE_ID" || true
    [[ -f "$retired_file" ]] || return 0
    while IFS= read -r id || [[ -n "$id" ]]; do
        [[ "$id" =~ ^[0-9]+$ && "$id" != "$TEMPLATE_ID" ]] || continue
        config=$(qm config "$id" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null) || continue
        grep -q '^template: 1[[:space:]]*$' <<< "$config" || continue
        grep -q '^name: ubuntu-cloud-template[[:space:]]*$' <<< "$config" || continue
        base_volids_in_config <<< "$config"
    done < "$retired_file" || true
}

# 0 when the storage listing shows volume $1 as a linked clone of one of the
# base volumes that follow. Proxmox lists a ZFS, RBD or directory linked clone
# under its base; LVM-thin lists it on its own, so it never matches.
volume_is_linked_clone_of() {
    local volid="$1" base
    shift
    for base in "$@"; do
        [[ "$volid" == "$base/"* ]] && return 0
    done
    return 1
}

linked_clone_child_vmid() {
    local volid="$1"
    local child_name="${volid#*:}"
    child_name="${child_name##*/}"
    if [[ "$child_name" =~ ^vm-([0-9]+)-disk- ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Prints the ZFS dataset behind zvol volume $1. Like pvesm path, it does not
# check that the dataset exists.
zfs_dataset_from_volid() {
    local volid="$1"
    local path

    command -v zfs >/dev/null 2>&1 || return 1
    path=$(pvesm path "$volid" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null) || return 1
    [[ "$path" == /dev/zvol/* ]] || return 1

    printf '%s\n' "${path#/dev/zvol/}"
}

# 0 only when a listing of the volume's storage succeeds and no longer shows
# it. A failed listing is not proof that the volume is gone.
volume_confirmed_absent() {
    local volid="$1" listing
    listing=$(pvesm list "${volid%%:*}" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null) || return 1
    awk -v v="$volid" '$1 == v { found = 1 } END { exit found }' <<< "$listing"
}

# `pvesm free` exits 0 even when its deletion task fails (a busy zvol, an open
# LV): the error only reaches stderr and the task log. A free counts only once
# the volume is gone from its storage listing.
free_volume() {
    local volid="$1"
    pvesm free "$volid" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- || return 1
    volume_confirmed_absent "$volid"
}

list_template_linked_clone_volids() {
    local template_id="${1:-$TEMPLATE_ID}"
    local storage_list base_volid base_path prefix volid child_name base_dataset dataset origin zfs_path base_vols
    local -A seen=()

    # An unreadable config must not look like "no linked clones". Callers
    # destroy a template only when this function succeeds and prints nothing.
    if ! qm config "$template_id" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- >/dev/null 2>&1; then
        log_error "Failed to read config for template $template_id"
        return 1
    fi

    if ! storage_list=$(pvesm list "$VM_STORAGE" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null); then
        log_error "Failed to list storage volumes on $VM_STORAGE"
        return 1
    fi
    [[ -n "$storage_list" ]] || return 0

    # An empty result is permission to destroy the template. < <(...) would
    # discard a failed listing and look like no base volumes.
    if ! base_vols=$(list_template_base_volids "$template_id"); then
        log_error "Failed to list base volumes for template $template_id"
        return 1
    fi

    while read -r base_volid; do
        [[ -n "$base_volid" ]] || continue
        base_path="${base_volid#*:}"
        prefix="${VM_STORAGE}:${base_path}/"

        while read -r volid _; do
            [[ "$volid" == "$prefix"* ]] || continue
            child_name="${volid#"$prefix"}"
            # Directory-backed clones include the child VMID before the filename.
            child_name="${child_name##*/}"
            [[ "$child_name" =~ ^vm-[0-9]+-disk- ]] || continue
            [[ -n "${seen[$volid]:-}" ]] && continue
            seen["$volid"]=1
            printf '%s\n' "$volid"
        done <<< "$storage_list"
    done <<< "$base_vols"

    # ZFS linked clones are sibling zvols, not nested volids. They point at
    # the template base volume snapshot via the ZFS origin property. A failed
    # path or origin lookup must fail this function, unless the volume is
    # gone (below): an empty result is permission to destroy the template. A
    # path that is not a zvol is dir or LVM storage, already handled above.
    while read -r base_volid; do
        [[ -n "$base_volid" ]] || continue
        if ! zfs_path=$(pvesm path "$base_volid" 199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null); then
            log_error "Failed to resolve path for template volume $base_volid"
            return 1
        fi
        [[ "$zfs_path" == /dev/zvol/* ]] || continue
        if ! command -v zfs >/dev/null 2>&1; then
            log_error "Template volume $base_volid is a zvol but zfs is not available"
            return 1
        fi
        base_dataset="${zfs_path#/dev/zvol/}"
        if ! zfs list -H -o name "$base_dataset" >/dev/null 2>&1; then
            log_error "Failed to resolve ZFS dataset for $base_volid"
            return 1
        fi

        while read -r volid _; do
            [[ "$volid" == "$VM_STORAGE:vm-"* ]] || continue
            [[ -n "${seen[$volid]:-}" ]] && continue
            if ! dataset=$(zfs_dataset_from_volid "$volid"); then
                log_error "Failed to resolve ZFS dataset for $volid"
                return 1
            fi
            # Runners are destroyed and recloned while this scan runs. A
            # volume that is gone depends on nothing, so this lookup's own
            # "dataset does not exist" (what Proxmox's ZFS plugin also takes
            # as gone) skips it. A second lookup would not do: by then a new
            # volume can have the same name. Any other failure fails closed.
            if ! origin=$(LC_ALL=C zfs get -H -o value origin "$dataset" 2>&1); then
                [[ "$origin" == *"dataset does not exist"* ]] && continue
                log_error "Failed to read ZFS origin for $dataset"
                return 1
            fi
            # stderr is captured too, so anything but one word fails closed.
            if [[ -z "$origin" || "$origin" == *[[:space:]]* ]]; then
                log_error "Unexpected ZFS origin for $dataset: $origin"
                return 1
            fi
            # "-" is a real origin value meaning "not a clone".
            [[ "$origin" == "$base_dataset@"* ]] || continue

            seen["$volid"]=1
            printf '%s\n' "$volid"
        done <<< "$storage_list"
    done <<< "$base_vols"
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
        if [[ -n "$child_vmid" ]] && ! config_path=$(vm_config_path_checked "$child_vmid"); then
            log_error "pmxcfs is not serving /etc/pve, so VM configs cannot be checked; not freeing $volid"
            log_error "Check that pve-cluster is running, then run 'runner stop' again."
            return 1
        fi

        if [[ -n "$config_path" ]]; then
            log_warn "Template child volume still has a VM config: $volid ($config_path)"
            blocked_volids+=("$volid")
            continue
        fi

        log_info "Freeing orphaned template child volume: $volid"
        if ! free_volume "$volid"; then
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

# Sweep VM image volumes on $VM_STORAGE whose VMID has no VM or container
# config on any node — leftovers from clones that failed before writing config
# (or whose _fail cleanup couldn't fully reap). Holds the pool activity lock
# exclusive non-blocking so it can never race a clone in progress. Scoped to
# VMIDs runners can get: vmid >= MIN_VMID and != TEMPLATE_ID. MIN_VMID=0
# ("auto") sets no lower bound, so the floor is then TEMPLATE_ID + 1. Listing
# only images content also leaves out every container's rootdir volumes.
# Runners get VMIDs below that floor too (MIN_VMID=0 hands out the cluster's
# next free ones). There it frees only linked clones of the live or a retired
# runner template; a runner disk left there would otherwise stay for good and
# keep its template from being retired. qm clone writes the new VM's config
# before it creates a disk, so a clone in progress is never config-less. The
# sweep stops at a lookup pmxcfs did not serve (vm_config_path_checked).
cleanup_runner_orphan_volumes() {
    local min_vmid="${MIN_VMID:-}"
    if [[ ! "$min_vmid" =~ ^[1-9][0-9]*$ ]]; then
        min_vmid=$((TEMPLATE_ID + 1))
    fi

    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    if ! flock -n -x 202; then
        exec 202>&-
        return 0
    fi

    local volid vmid config_path freed=0 template_bases_read=0
    local -a template_bases=()
    while IFS= read -r volid; do
        [[ -n "$volid" ]] || continue
        if [[ "$volid" =~ (:|/)vm-([0-9]+)-(disk-[0-9]+|cloudinit)$ ]]; then
            vmid="${BASH_REMATCH[2]}"
        else
            continue
        fi
        [[ "$vmid" -ne "$TEMPLATE_ID" ]] || continue
        # Below the floor only a volume listed under a base volume can be a
        # runner's. Template configs are read once, and only when needed.
        [[ "$vmid" -ge "$min_vmid" || "$volid" == */* ]] || continue
        if ! config_path=$(vm_config_path_checked "$vmid"); then
            log_warn "[orphan-sweep] pmxcfs is not serving /etc/pve, so guest configs cannot be checked; stopping the sweep"
            break
        fi
        [[ -z "$config_path" ]] || continue
        if [[ "$vmid" -lt "$min_vmid" ]]; then
            if [[ "$template_bases_read" == 0 ]]; then
                # </dev/null: its qm calls must not read this loop's listing.
                mapfile -t template_bases < <(runner_template_base_volids </dev/null)
                template_bases_read=1
            fi
            volume_is_linked_clone_of "$volid" "${template_bases[@]}" || continue
        fi
        log_info "[orphan-sweep] freeing $volid (vmid $vmid has no config)"
        if free_volume "$volid" 2>/dev/null; then
            freed=$((freed + 1))
        else
            log_warn "[orphan-sweep] pvesm free $volid failed"
        fi
    done < <(pvesm list "$VM_STORAGE" --content images 2>/dev/null | awk 'NR>1 {print $1}')

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

    local runner_id name_q
    name_q=$(jq -nr --arg n "$runner_name" '$n|@uri') || return 0
    # ?name= is exact match on GitHub's side, but still filter in jq so a
    # surprising API change cannot DELETE the wrong runner. Avoids paging
    # through every org runner (per_page max 100) to find a stale JIT leftover.
    runner_id=$(curl -sf --max-time 10 \
        -H "Accept: application/vnd.github+json" \
        --config <(printf 'header = "Authorization: token %s"\n' "$pat") \
        "https://api.github.com/orgs/${github_org}/actions/runners?name=${name_q}&per_page=100" 2>/dev/null \
        | jq --arg name "$runner_name" -r '.runners[] | select(.name == $name) | .id' 2>/dev/null) || return 0

    [[ -n "$runner_id" && "$runner_id" != "null" && "$runner_id" =~ ^[0-9]+$ ]] || return 0

    # stdout suppressed: DELETE returns 204 (empty), but this runs inside
    # $(clone_runner) on the retry path, so keep it off the captured stdout.
    curl -sf --max-time 10 -X DELETE \
        -H "Accept: application/vnd.github+json" \
        --config <(printf 'header = "Authorization: token %s"\n' "$pat") \
        "https://api.github.com/orgs/${github_org}/actions/runners/${runner_id}" >/dev/null 2>&1 || return 0
}

# --- Shared runner VM helpers ---

# Mint a single-use JIT (just-in-time) runner config on the host. The runner
# registers and auto-removes using this config, and it CANNOT be reused to
# register another runner — so even if a job reads it from the cloud-init drive
# it cannot be replayed. Requires GITHUB_PAT and GITHUB_ORG in scope (caller ran
# load_org_config). The PAT is passed via curl --config to keep it off argv; the
# request body (name/labels/group) is not sensitive. RUNNER_GROUP_ID (default 1
# = the org's "Default" group) and RUNNER_LABELS may be set in the org config.
# Prints the base64 encoded_jit_config on stdout.
# Returns 0 on success, 2 on HTTP 409 (duplicate runner name), 1 on any other failure.
fetch_jit_config() {
    local name="$1"
    local group="${RUNNER_GROUP_ID:-1}"
    local labels="${RUNNER_LABELS:-self-hosted,linux,x64}"
    [[ -n "$labels" ]] || labels="self-hosted,linux,x64"
    # Group IDs are >=1 (1 = Default); clamp anything else to 1.
    [[ "$group" =~ ^[1-9][0-9]*$ ]] || group=1
    local body http_code jit tmp
    # split → trim each label → drop empties, so a hand-edited RUNNER_LABELS with
    # spaces or a trailing comma still yields clean labels.
    body=$(jq -n --arg name "$name" --argjson group "$group" --arg labels "$labels" \
        '{name: $name, runner_group_id: $group,
          labels: ($labels | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)))}') || return 1
    tmp=$(mktemp) || return 1
    http_code=$(curl -sS -o "$tmp" -w "%{http_code}" --max-time 15 --retry 3 -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        --config <(printf 'header = "Authorization: token %s"\n' "$GITHUB_PAT") \
        --data "$body" \
        "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/generate-jitconfig") || http_code="000"
    body=$(cat "$tmp")
    rm -f "$tmp"
    if [[ "$http_code" == "409" ]]; then
        log_warn "JIT mint conflict: a runner named '$name' already exists"
        return 2
    fi
    if [[ "$http_code" != "201" && "$http_code" != "200" ]]; then
        case "$http_code" in
            401|403) log_error "JIT mint failed for '$name' (HTTP $http_code) — PAT needs runner write access" ;;
            404) log_error "JIT mint failed for '$name' (HTTP $http_code) — org or runner group $group not found" ;;
            422) log_error "JIT mint failed for '$name' (HTTP $http_code) — invalid name, labels, or group" ;;
            *) log_error "JIT mint failed for '$name' (HTTP $http_code)" ;;
        esac
        return 1
    fi
    jit=$(jq -r '.encoded_jit_config // empty' <<<"$body" 2>/dev/null) || return 1
    # Must be a single base64 token — rejects anything with quotes/newlines that
    # could break out of the YAML string it gets rendered into.
    [[ -n "$jit" && "$jit" =~ ^[A-Za-z0-9+/=_-]+$ ]] || return 1
    printf '%s' "$jit"
}

# Render a per-VM cloud-init user snippet carrying only the single-use JIT
# config and org (never the PAT). Uses awk with the config passed via ENVIRON so
# it never appears in the process list.
# Usage: render_user_snippet <vmid> <org> <jit_config>
render_user_snippet() {
    local vmid="$1" org="$2" jit_config="$3"
    local tmp
    tmp=$(mktemp "$SNIPPETS_DIR/.runner-${vmid}-user.XXXXXX") || return 1
    chmod 600 "$tmp"
    JIT_CONFIG="$jit_config" GITHUB_ORG="$GITHUB_ORG" DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-}" DNS_SERVERS="${DNS_SERVERS:-}" awk '
    # Literal string replace (avoids gsub special chars: & and \)
    function lreplace(str, old, new,    i, result) {
        result = ""
        while ((i = index(str, old)) > 0) {
            result = result substr(str, 1, i - 1) new
            str = substr(str, i + length(old))
        }
        return result str
    }
    {
        $0 = lreplace($0, "{{JIT_CONFIG}}", ENVIRON["JIT_CONFIG"])
        $0 = lreplace($0, "{{GITHUB_ORG}}", ENVIRON["GITHUB_ORG"])
        $0 = lreplace($0, "{{DOCKER_MIRROR_URL}}", ENVIRON["DOCKER_MIRROR_URL"])
        $0 = lreplace($0, "{{DNS_SERVERS}}", ENVIRON["DNS_SERVERS"])
        print
    }' "$INSTALL_DIR/templates/runner-user-data.yaml" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$SNIPPETS_DIR/runner-${vmid}-user-${org}.yaml" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SNIPPETS_DIR/runner-${vmid}-user-${org}.yaml"
}

# Deterministic MAC from name. Locally-administered unicast (02:xx:xx:xx:xx:xx).
generate_mac() {
    echo -n "$1" | md5sum | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\).*/02:\1:\2:\3:\4:\5/'
}

# Clone template, configure cloud-init, set hookscript, start VM.
# Returns VMID on stdout. Returns 1 on failure (cleans up partial clone).
# Sets CLONE_MINT_CONFLICT to 1 when a runner of this name was still
# registered on GitHub. An ephemeral runner is removed once it finishes a
# job, so that means the previous runner of this name never finished one.
clone_runner() {
    local name="$1" org="$2" vmid="${3:-}"
    local RESERVED_VMID=""
    local pool_lock_owned=0
    CLONE_MINT_CONFLICT=0

    # GITHUB_PAT/GITHUB_ORG must be in scope (caller ran load_org_config).
    if [[ -z "${GITHUB_PAT:-}" || -z "${GITHUB_ORG:-}" ]]; then
        log_error "clone_runner: org config not loaded (GITHUB_PAT/GITHUB_ORG unset)"
        return 1
    fi

    # reclone.sh holds fd 202 for its whole lifetime (POOL_ACTIVITY_LOCK_HELD=1)
    # so runner stop's exclusive 202 waits out destroy+mint, not just qm clone.
    # Do not exec 202> in that case — it would drop the caller's lock.
    _pool_lock_acquire() {
        if [[ "${POOL_ACTIVITY_LOCK_HELD:-0}" == "1" ]]; then
            return 0
        fi
        exec 202>"$POOL_ACTIVITY_LOCK_FILE"
        flock -s 202
        pool_lock_owned=1
    }
    _pool_lock_release() {
        if [[ "$pool_lock_owned" == "1" ]]; then
            exec 202>&-
            pool_lock_owned=0
        fi
    }

    _pool_lock_acquire

    if pool_is_draining; then
        log_warn "clone_runner: pool drain active, refusing to create $name"
        _pool_lock_release
        return 1
    fi

    # Cleanup helper: destroy VM (only if it belongs to us), remove snippet, and
    # sweep orphan volumes at this VMID. The ownership check prevents touching
    # another process's VM on VMID collision. An empty owner is not a free
    # VMID: qm config cannot read a container, a VM on another node or a VM
    # with no name. The sweep covers our VM's residue (qm destroy can leave a
    # busy ZFS dataset, etc.) and a clone that failed before writing config.
    # It frees nothing while any guest config holds the VMID: a destroy that a
    # lock refused (vzdump, for example) leaves a config still using those
    # volumes, and once the config is gone a parallel clone can take the VMID,
    # so the check runs again before each free. Nor while pmxcfs is not
    # serving /etc/pve, when no config shows. No --purge: it deletes the
    # VMID from backup jobs, and the next clone reuses this VMID.
    _fail() {
        local owner
        owner=$(qm config "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null | awk '/^name:/{print $2}') || true

        if [[ -n "$owner" && "$owner" != "$name" ]]; then
            return 0
        fi
        if [[ -z "$owner" ]] && vmid_in_use "$vmid"; then
            log_warn "VMID $vmid belongs to another guest; leaving it and its volumes"
            return 0
        fi

        rm -f "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" "${SNIPPETS_DIR}/runner-${vmid}-user-"*.yaml "${SNIPPETS_DIR}/runner-${vmid}-vendor.yaml"

        if [[ "$owner" == "$name" ]]; then
            local destroy_err; destroy_err=$(mktemp)
            if ! qm destroy "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&- 2>"$destroy_err"; then
                log_warn "qm destroy $vmid failed: $(tr '\n' ' ' < "$destroy_err")"
            fi
            rm -f "$destroy_err"
        fi

        local volid config_path
        while read -r volid; do
            [[ -n "$volid" ]] || continue
            if ! config_path=$(vm_config_path_checked "$vmid"); then
                log_warn "pmxcfs is not serving /etc/pve; not freeing the volumes of VMID $vmid"
                break
            fi
            if [[ -n "$config_path" ]]; then
                log_warn "VMID $vmid still has a guest config; not freeing its volumes"
                break
            fi
            free_volume "$volid" 2>/dev/null || log_warn "Failed to free orphan volume $volid"
        done < <(
            pvesm list "$VM_STORAGE" --content images 2>/dev/null |
                awk -v v="$vmid" 'NR>1 && $1 ~ ("(^|:|/)vm-" v "-(disk-[0-9]+|cloudinit)$") {print $1}'
        )
    }

    # Mint the single-use JIT config BEFORE cloning so the PAT never enters the
    # VM. Fail fast here (return 1, not _fail): nothing has been created yet, and
    # on a VMID collision _fail's name match could destroy a foreign VM.
    # generate-jitconfig 409s if a runner of this name still exists (e.g. a
    # crashed VM left a stale entry). A healthy ephemeral runner auto-removes
    # after its job, so the common path mints in one call; only on failure do we
    # deregister the stale entry (mirrors config.sh --replace) and retry once.
    local jit_config mint_rc=0
    jit_config=$(fetch_jit_config "$name") && mint_rc=0 || mint_rc=$?
    if [[ $mint_rc -eq 2 ]]; then
        # Duplicate name: deregister the stale GitHub-side runner and mint once more.
        # Read by the callers' failure backoff (recycle.sh).
        # shellcheck disable=SC2034
        CLONE_MINT_CONFLICT=1
        deregister_runner "$org" "$name" || true
        jit_config=$(fetch_jit_config "$name") && mint_rc=0 || mint_rc=$?
        if [[ $mint_rc -ne 0 ]]; then
            log_error "Failed to mint JIT config for org '$GITHUB_ORG' after removing a stale runner named '$name'"
            _pool_lock_release
            return 1
        fi
    elif [[ $mint_rc -ne 0 ]]; then
        _pool_lock_release
        return 1
    fi

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
        _pool_lock_release
        return 1
    fi

    if [[ -z "$vmid" ]]; then
        if ! reserve_vmid; then
            exec 201>&-
            _pool_lock_release
            return 1
        fi
        vmid="$RESERVED_VMID"
    else
        # Caller pre-allocated. Re-verify under lock — a concurrent process
        # could have grabbed it between the caller's check and now.
        if ! reserve_vmid "$vmid"; then
            exec 201>&-
            _pool_lock_release
            return 1
        fi
        vmid="$RESERVED_VMID"
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        exec 201>&-
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi

    # VMID is reserved; release the allocator so other workers can reserve and
    # clone different VMIDs while this clone runs.
    exec 201>&-

    if ! acquire_clone_slot; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        release_clone_slot
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi

    # Whether this is one of the org's RUNNER_COUNT slots, which the pool
    # retires once the count or prefix no longer covers it, or an extra runner
    # from `runner create`, which recycles until `runner destroy`.
    local kind="" slot_n
    if [[ "${RUNNER_COUNT:-}" =~ ^[0-9]{1,9}$ ]]; then
        kind=extra
        if slot_n=$(slot_number "$name" "${RUNNER_PREFIX:-runner}") && (( slot_n <= 10#$RUNNER_COUNT )); then
            kind=slot
        fi
    fi

    # Keep maintenance locks in this shell only. Proxmox helper children can
    # spawn long-lived kvm processes; those must not inherit runner lock fds.
    # Capture stderr so the actual ZFS/Proxmox error surfaces under
    # `journalctl -t github-runner` instead of being buried under the service
    # unit log (which the operator does not look at first).
    # The description is the ownership marker get_vm_org falls back to, with
    # the kind. qm clone writes it in the same config write as the name, so a
    # clone that is killed before --cicustom below is still recognisably ours.
    local clone_err; clone_err=$(mktemp)
    if ! qm clone "$TEMPLATE_ID" "$vmid" --name "$name" --description "selfhosted-runners org=$org${kind:+ kind=$kind}" \
        200>&- 201>&- 202>&- 203>&- 204>&- 2>"$clone_err"; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && log_error "qm clone $vmid: $line"
        done < "$clone_err"
        rm -f "$clone_err"
        release_clone_slot
        _fail
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi
    rm -f "$clone_err"
    release_clone_slot

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active after cloning $name, cleaning up VM $vmid"
        _fail
        release_vmid_reservation "$vmid"
        _pool_lock_release
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
        qm set "$vmid" --net0 "$net0" 200>&- 201>&- 202>&- 203>&- 204>&- || { _fail; _pool_lock_release; return 1; }
    fi

    # Cloud-init meta (instance-id / hostname). Guard the write itself — a brace
    # group's exit status is its LAST command, so a failed write (e.g. ENOSPC mid
    # clone) followed by a successful chmod would be masked and boot a VM with a
    # truncated meta snippet.
    printf 'instance-id: "%s"\nlocal-hostname: "%s"\n' "$name" "$name" \
        > "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" || { _fail; _pool_lock_release; return 1; }
    chmod 600 "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" || { _fail; _pool_lock_release; return 1; }

    # Per-VM user snippet carrying the single-use JIT config (must exist before
    # qm set --cicustom, which validates the referenced volume).
    render_user_snippet "$vmid" "$org" "$jit_config" || { _fail; _pool_lock_release; return 1; }

    qm set "$vmid" --cicustom "user=local:snippets/runner-${vmid}-user-${org}.yaml,meta=local:snippets/runner-${vmid}-meta.yaml" \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }
    qm set "$vmid" --ipconfig0 ip=dhcp \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }
    [[ -z "${DNS_SERVERS:-}" ]] || qm set "$vmid" --nameserver "$DNS_SERVERS" \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }
    qm set "$vmid" --ciuser runner \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }
    # A guest reboot must end the VM like a shutdown. By default QEMU resets
    # in place: no post-stop, no reclone, and cloud-init does not start the
    # one-shot runner again, so the VM idles in its slot.
    qm set "$vmid" --reboot 0 \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }

    # Hookscript for auto-destroy on shutdown
    if [[ -f "$SNIPPETS_DIR/runner-hookscript.sh" ]]; then
        qm set "$vmid" --hookscript "local:snippets/runner-hookscript.sh" \
            200>&- \
            201>&- \
            202>&- \
            203>&- \
            204>&- \
            || log_warn "Failed to set hookscript on $vmid — VM will not auto-recycle"
    else
        log_warn "$SNIPPETS_DIR/runner-hookscript.sh is missing, so $name (VMID $vmid) will not auto-recycle; the watcher reclaims it after it stops. Restore it with: install -m 755 $INSTALL_DIR/templates/runner-hookscript.sh $SNIPPETS_DIR/runner-hookscript.sh"
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active while configuring $name, cleaning up VM $vmid"
        _fail
        _pool_lock_release
        return 1
    fi

    # Start
    if ! qm start "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&-; then
        _fail
        _pool_lock_release
        return 1
    fi

    _pool_lock_release
    echo "$vmid"
}
