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
# Scope is narrow: "pick free VMID -> qm clone returns (config persisted)".
# pvesh get /cluster/nextid is not atomic and does not reserve, so without
# this lock two parallel clones reliably pick the same VMID.
VMID_LOCK_FILE="/run/lock/runner-vmid.lock"

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

# Find next free VMID
next_vmid() {
    if [[ "${MIN_VMID:-0}" -gt 0 ]]; then
        local vmid="$MIN_VMID"
        # This runs while fd 201 is held. Check pmxcfs config presence instead
        # of invoking qm status so a stuck status probe cannot block all clones.
        while vmid_in_use "$vmid"; do
            vmid=$((vmid + 1))
        done
        echo "$vmid"
    else
        pvesh get /cluster/nextid
    fi
}

# Clone template, configure cloud-init, set hookscript, start VM.
# Returns VMID on stdout. Returns 1 on failure (cleans up partial clone).
clone_runner() {
    local name="$1" org="$2" vmid="${3:-}"

    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -s 202

    if pool_is_draining; then
        log_warn "clone_runner: pool drain active, refusing to create $name"
        exec 202>&-
        return 1
    fi

    # Cleanup helper: destroy VM (only if it belongs to us) and remove snippet.
    # The ownership check prevents destroying another process's VM on VMID collision.
    # If there's no VM config at all, the clone failed mid-transaction — free any
    # orphan storage volumes at this VMID so ZFS/LVM datasets don't leak.
    _fail() {
        local owner
        owner=$(qm config "$vmid" 200>&- 201>&- 202>&- 2>/dev/null | awk '/^name:/{print $2}') || true
        if [[ "$owner" == "$name" ]]; then
            rm -f "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml"
            qm destroy "$vmid" --purge 200>&- 201>&- 202>&- 2>/dev/null || true
        elif [[ -z "$owner" ]]; then
            # No VM config — free any orphan volumes left by a half-finished clone.
            rm -f "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml"
            local volid
            while read -r volid; do
                [[ -n "$volid" ]] || continue
                pvesm free "$volid" 2>/dev/null || log_warn "Failed to free orphan volume $volid"
            done < <(
                { pvesm list "$VM_STORAGE" --vmid "$vmid" 2>/dev/null || pvesm list "$VM_STORAGE" 2>/dev/null; } |
                    awk -v v="$vmid" 'NR>1 && ($1 ~ (":vm-" v "-disk-") || $1 ~ (":" v "/vm-" v "-disk-")) {print $1}'
            )
        fi
    }

    # Acquire global VMID allocation lock. Scope is tight: "pick VMID -> qm
    # clone returns (config persisted)". qm set/start run unlocked.
    # Timeout is intentionally high because qm clone is serialized here and a
    # cold pool refill can queue many linked clones behind the same lock on
    # slower storage backends.
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
        if ! vmid=$(next_vmid); then
            exec 201>&-
            exec 202>&-
            return 1
        fi
    else
        # Caller pre-allocated. Re-verify under lock — a concurrent process
        # could have grabbed it between the caller's check and now.
        while vmid_in_use "$vmid"; do
            vmid=$((vmid + 1))
        done
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        exec 201>&-
        exec 202>&-
        return 1
    fi

    # Keep maintenance locks in this shell only. Proxmox helper children can
    # spawn long-lived kvm processes; those must not inherit runner lock fds.
    if ! qm clone "$TEMPLATE_ID" "$vmid" --name "$name" 200>&- 201>&- 202>&-; then
        _fail
        exec 201>&-
        exec 202>&-
        return 1
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active after cloning $name, cleaning up VM $vmid"
        exec 201>&-
        _fail
        exec 202>&-
        return 1
    fi

    # Clone succeeded — VMID is now claimed in Proxmox. Release lock before
    # the long tail of qm set / qm start so other clones can proceed.
    exec 201>&-

    # Deterministic MAC
    local mac net0
    mac=$(generate_mac "$name")
    net0=$(qm config "$vmid" 200>&- 201>&- 202>&- | grep '^net0:' | sed 's/^net0: //') || true
    if [[ -n "$net0" ]]; then
        net0=$(echo "$net0" | sed "s/virtio=[^,]*/virtio=$mac/")
        qm set "$vmid" --net0 "$net0" 200>&- 201>&- 202>&- || { _fail; exec 202>&-; return 1; }
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
        || { _fail; exec 202>&-; return 1; }
    qm set "$vmid" --ipconfig0 ip=dhcp \
        200>&- \
        201>&- \
        202>&- \
        || { _fail; exec 202>&-; return 1; }
    [[ -z "${DNS_SERVERS:-}" ]] || qm set "$vmid" --nameserver "$DNS_SERVERS" \
        200>&- \
        201>&- \
        202>&- \
        || { _fail; exec 202>&-; return 1; }
    qm set "$vmid" --ciuser runner \
        200>&- \
        201>&- \
        202>&- \
        || { _fail; exec 202>&-; return 1; }

    # Hookscript for auto-destroy on shutdown
    if [[ -f "$SNIPPETS_DIR/runner-hookscript.sh" ]]; then
        qm set "$vmid" --hookscript "local:snippets/runner-hookscript.sh" \
            200>&- \
            201>&- \
            202>&- \
            || log_warn "Failed to set hookscript on $vmid — VM will not auto-recycle"
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active while configuring $name, cleaning up VM $vmid"
        _fail
        exec 202>&-
        return 1
    fi

    # Start
    if ! qm start "$vmid" 200>&- 201>&- 202>&-; then
        _fail
        exec 202>&-
        return 1
    fi

    exec 202>&-
    echo "$vmid"
}
