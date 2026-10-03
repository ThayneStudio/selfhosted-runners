#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=rebake.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rebake.sh"
# shellcheck source=setup-prompts.sh
source "$LIB_DIR/setup-prompts.sh"

# Storages on this node that can hold the template and its linked clones, as
# "name type" lines. They must allow VM disk images. Thick LVM and iSCSI LUNs
# accept `qm template` without making a base volume, and every linked clone of
# such a template then fails.
template_storages() {
    pvesm status --content images 2>/dev/null \
        | awk 'NR > 1 && $2 !~ /^(lvm|iscsi|iscsidirect)$/ { print $1, $2 }'
}

check_vm_storage() {
    local storage="$1" storage_type
    if template_storages | awk -v s="$storage" '$1 == s { found = 1 } END { exit !found }'; then
        return 0
    fi
    storage_type=$(pvesm status 2>/dev/null | awk -v s="$storage" 'NR > 1 && $1 == s { print $2; exit }') || storage_type=""
    if [[ -z "$storage_type" ]]; then
        log_error "Storage pool '$storage' does not exist"
    else
        log_error "Storage '$storage' ($storage_type) cannot hold the template and its linked clones"
        log_error "Choose a listed storage: it allows VM disk images and is not thick LVM or iSCSI"
    fi
    return 1
}

# `pvesm set --content` replaces the whole list, so read the effective list and
# append snippets. pvesh also sees the built-in local storage when storage.cfg
# has no `dir: local` stanza. Never guess a list: that drops content types.
enable_local_snippets() {
    local content
    if pvesm status --content snippets 2>/dev/null | awk '{print $1}' | grep -qx "local"; then
        return 0
    fi
    if ! content=$(pvesh get /storage/local --output-format json 2>/dev/null | jq -r '.content // empty') \
        || [[ -z "$content" ]]; then
        log_error "Could not read the content types of local storage"
        log_error "Add snippets to them by hand (pvesm set local --content <current>,snippets), then re-run setup"
        return 1
    fi
    if [[ ",$content," == *,snippets,* ]]; then
        log_info "Snippets already in content types for local storage"
        return 0
    fi
    # "none" cannot be combined with another content type.
    if [[ "$content" == none ]]; then
        content=""
    fi
    if ! pvesm set local --content "${content:+$content,}snippets"; then
        log_error "Failed to enable snippets on local storage"
        return 1
    fi
}

# Decide what to do with the Template VM ID answer. A finished template is used
# as it is (TEMPLATE_READY=1). Any other VM there is refused, such as a bake
# that stopped before `qm template` converted its disk, or a runner. A free ID
# is baked. If the saved TEMPLATE_ID is a finished template, LIVE_TEMPLATE_ID
# keeps it serving clones until the new one is finished.
plan_template() {
    local saved="${SETUP_PREFILLS[TEMPLATE_ID]:-}" cfg name
    TEMPLATE_READY=0
    LIVE_TEMPLATE_ID=""
    if template_is_converted "$TEMPLATE_ID"; then
        TEMPLATE_READY=1
        return 0
    fi
    if cfg=$(qm_host config "$TEMPLATE_ID" 2>/dev/null); then
        name=$(printf '%s\n' "$cfg" | awk '/^name:/{print $2; exit}')
        if [[ "$name" == "ubuntu-cloud-template" ]]; then
            log_error "VM $TEMPLATE_ID is an unfinished template bake: its disk was never converted to a template"
            log_error "If nothing is still baking it, remove it and run setup again: qm stop $TEMPLATE_ID; qm destroy $TEMPLATE_ID"
        else
            log_error "VM $TEMPLATE_ID (${name:-unnamed}) is not a finished template. Choose another Template VM ID."
        fi
        return 1
    fi
    if vmid_in_use "$TEMPLATE_ID"; then
        log_error "VM ID $TEMPLATE_ID belongs to another guest. Choose another Template VM ID."
        return 1
    fi
    if [[ -n "$saved" ]] && template_is_converted "$saved"; then
        LIVE_TEMPLATE_ID="$saved"
    fi
}

# Linked clones stay on the template's own storage, so a VM_STORAGE that
# differs from it applies only from the next bake. Say so and how to bake now.
warn_template_storage() {
    local storages
    storages=$(qm_host config "$TEMPLATE_ID" 2>/dev/null | awk '
        /^(ide|sata|scsi|virtio)[0-9]+: / && !/media=cdrom/ { sub(/:.*/, "", $2); print $2 }
    ' | sort -u | paste -sd, -) || return 0
    [[ -n "$storages" && "$storages" != "$VM_STORAGE" ]] || return 0
    log_warn "Template $TEMPLATE_ID has its disks on $storages, not $VM_STORAGE."
    log_warn "Runners are linked clones on $storages until a template is baked on $VM_STORAGE."
    log_warn "To bake one now: rm -f $BAKED_VERSION_FILE && runner rebake"
}

# While a new template is baked beside the live one, the saved TEMPLATE_ID
# keeps naming the live one. bake_setup_template moves it afterwards.
# Lines this wizard does not prompt for stay where they are, including
# BAKE_TIMEOUT, BAKE_MIN_FREE_GIB and any other assignment an operator added.
write_infra_config() {
    local conf_tmp line key
    local -A new_value=()
    local -A written=()
    local managed_re='^[[:space:]]*(export[[:space:]]+)?(NETWORK_BRIDGE|VLAN_TAG|VM_STORAGE|TEMPLATE_ID|MIN_VMID|BALLOON|DNS_SERVERS|DOCKER_MIRROR_URL)='
    mkdir -p "$ORG_CONFIG_DIR"
    chmod 700 "$ORG_CONFIG_DIR"
    new_value[NETWORK_BRIDGE]="$NETWORK_BRIDGE"
    new_value[VLAN_TAG]="${VLAN_TAG}"
    new_value[VM_STORAGE]="$VM_STORAGE"
    new_value[TEMPLATE_ID]="${LIVE_TEMPLATE_ID:-$TEMPLATE_ID}"
    new_value[MIN_VMID]="$MIN_VMID"
    new_value[BALLOON]="$BALLOON"
    new_value[DNS_SERVERS]="$DNS_SERVERS"
    new_value[DOCKER_MIRROR_URL]="${DOCKER_MIRROR_URL:-}"
    conf_tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    {
        if [[ -f "$CONFIG_FILE" ]]; then
            # "|| [[ -n $line ]]" also reads a last line that has no newline.
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" =~ $managed_re ]]; then
                    key=${BASH_REMATCH[2]}
                    written[$key]=1
                    printf '%s=%q\n' "$key" "${new_value[$key]}"
                else
                    printf '%s\n' "$line"
                fi
            done < "$CONFIG_FILE"
        fi
        for key in NETWORK_BRIDGE VLAN_TAG VM_STORAGE TEMPLATE_ID MIN_VMID BALLOON DNS_SERVERS DOCKER_MIRROR_URL; do
            [[ -n "${written[$key]:-}" ]] || printf '%s=%q\n' "$key" "${new_value[$key]}"
        done
    } > "$conf_tmp"
    chmod 600 "$conf_tmp"
    mv "$conf_tmp" "$CONFIG_FILE"
}

# Prune obsolete per-org snippets that embedded the org PAT. Cloud-init is now
# rendered per-VM at clone time with a single-use JIT config; the PAT stays
# on the host.
prune_pat_snippets() {
    compgen -G "$SNIPPETS_DIR/runner-user-data-*.yaml" > /dev/null || return 0
    rm -f "$SNIPPETS_DIR"/runner-user-data-*.yaml
    log_info "Removed obsolete per-org PAT snippets"
}

# VMs cloned from those snippets keep the PAT on their cloud-init drive until
# they are destroyed. Look for the VMs, not the snippets: a run that removed
# the snippets can fail before it warns, and clones made with JIT configs
# never held the PAT.
warn_pat_snippet_vms() {
    local count
    count=$(grep -ls '^cicustom:.*user=local:snippets/runner-user-data-' "$PVE_NODES_DIR"/*/qemu-server/*.conf | wc -l) || count=0
    (( count > 0 )) || return 0
    log_warn "$((count)) runner VM(s) cloned from the old per-org snippets still have the org PAT on their cloud-init drive, where any job they run can read it."
    log_warn "Recycle the pool to destroy them: runner stop && runner start"
    echo ""
}

# A bake beside the live template is a VM that neither TEMPLATE_ID nor the
# retired list names. Record it as the rebake records its own bake, so the next
# rebake finishes or removes it when setup dies first (SIGKILL, power loss) or
# cleanup_bake cannot destroy it. There is one record. Replacing one whose VM
# may still exist would leave that VM to nobody, so refuse instead.
record_setup_bake() {
    local id=""
    if [[ -f "$PENDING_BAKE_FILE" ]]; then
        id=$(tr -d '[:space:]' < "$PENDING_BAKE_FILE") || return 1
    fi
    if [[ "$id" =~ ^[0-9]+$ && "$id" != "$TEMPLATE_ID" ]] && ! vm_confirmed_absent "$id"; then
        log_error "VM $id from an earlier bake is still recorded in $PENDING_BAKE_FILE"
        log_error "Run 'runner rebake' to finish or remove it, then run setup again"
        log_error "If 'qm config $id' on this node shows no VM named ubuntu-cloud-template, the record is stale; remove it instead: rm $PENDING_BAKE_FILE"
        return 1
    fi
    # A version left by an earlier record does not describe this bake.
    rm -f "$PENDING_VERSION_FILE" || return 1
    install -d -m 700 "$STATE_DIR" || return 1
    printf '%s\n' "$TEMPLATE_ID" > "$PENDING_BAKE_FILE" || return 1
    chmod 600 "$PENDING_BAKE_FILE"
}

# Drop the pending-bake record once VM $TEMPLATE_ID is published or destroyed.
# A record that names another VM belongs to a bake this setup did not make.
forget_setup_bake() {
    [[ -f "$PENDING_BAKE_FILE" ]] || return 0
    [[ "$(tr -d '[:space:]' < "$PENDING_BAKE_FILE")" == "$TEMPLATE_ID" ]] || return 0
    rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
}

# EXIT trap of the bake: destroy VM $TEMPLATE_ID unless it is a finished
# template. `template: 1` alone is written before qm template converts the
# disk, and nothing can be cloned from an unconverted one. A signal after the
# conversion must not destroy the template. A VM left in place keeps its
# pending-bake record, if it has one, for the next rebake. A bake that
# create_bake_vm refused before `qm create` has no VM, and once the cluster
# inventory confirms that, its record goes, as cleanup_rebake drops its own.
# After an SSH drop every log write fails (EIO on the hung-up tty, or SIGPIPE
# through a pipe). Neither errexit nor a second SIGHUP may stop the destroy.
cleanup_bake() {
    local cfg name
    set +e
    trap '' HUP PIPE
    if ! cfg=$(qm_host config "$TEMPLATE_ID" 2>/dev/null); then
        if vm_confirmed_absent "$TEMPLATE_ID"; then
            forget_setup_bake
            return 0
        fi
        log_error "Could not read config for VM $TEMPLATE_ID; leaving it"
        return 0
    fi
    name=$(printf '%s\n' "$cfg" | awk '/^name:/{print $2; exit}')
    if [[ "$name" != "ubuntu-cloud-template" ]]; then
        log_error "Refusing to destroy VM $TEMPLATE_ID (${name:-unnamed}); it is not the template bake VM"
        return 0
    fi
    if template_is_converted "$TEMPLATE_ID"; then
        log_warn "VM $TEMPLATE_ID is already a template; leaving it"
        return 0
    fi
    log_warn "Baking failed, cleaning up template VM..."
    qm_host stop "$TEMPLATE_ID" --timeout 30 2>/dev/null || true
    if ! qm_host destroy "$TEMPLATE_ID"; then
        log_error "Could not destroy VM $TEMPLATE_ID. Remove it by hand: qm stop $TEMPLATE_ID; qm destroy $TEMPLATE_ID"
        return 0
    fi
    forget_setup_bake
}

# Bake VM $TEMPLATE_ID. With LIVE_TEMPLATE_ID set, that template keeps serving
# clones until this one is a finished template. Then, as after a rebake,
# TEMPLATE_ID moves here and the old template is retired once no linked clone
# depends on it.
bake_setup_template() {
    # While a live template exists the daily rebake runs. Without its lock it
    # could start a second bake and switch TEMPLATE_ID as well. Hold the lock
    # until TEMPLATE_ID, the retired list and the baked-version record name the
    # new template, as perform_bake does: a rebake in between acts on the old
    # TEMPLATE_ID or record, and can leak or destroy the new template.
    exec 199>"$REBAKE_LOCK_FILE"
    if ! flock -n 199; then
        log_error "A template rebake is running. Run setup again after it finishes."
        return 1
    fi
    if [[ -n "$LIVE_TEMPLATE_ID" ]]; then
        log_info "Template $LIVE_TEMPLATE_ID keeps serving clones until VM $TEMPLATE_ID is a finished template"
    fi

    # Checksum mismatch deletes the cached image and returns before qm create.
    # Simple commands, not `|| exit`: `||` disables errexit inside the callee.
    prepare_cloud_image

    if [[ -n "$LIVE_TEMPLATE_ID" ]] && ! record_setup_bake; then
        return 1
    fi
    # Armed before create_bake_vm, whose checks can refuse before `qm create`,
    # so that cleanup_bake also drops the record of a VM that never existed.
    trap cleanup_bake EXIT
    log_info "Creating VM template..."
    create_bake_vm "$TEMPLATE_ID"

    bake_and_publish_vm "$TEMPLATE_ID"
    # qm template exits 0 even when it did not convert the disk.
    if ! template_is_converted "$TEMPLATE_ID"; then
        log_error "VM $TEMPLATE_ID is not a finished template after qm template"
        return 1
    fi
    trap - EXIT

    if [[ -n "$LIVE_TEMPLATE_ID" ]]; then
        if ! set_conf_assignment "$CONFIG_FILE" TEMPLATE_ID "$TEMPLATE_ID"; then
            # Its pending-bake record stays, so the next rebake publishes it.
            log_error "Template $TEMPLATE_ID is ready, but TEMPLATE_ID still names $LIVE_TEMPLATE_ID"
            log_error "Run setup again and enter Template VM ID $TEMPLATE_ID"
            return 1
        fi
        if ! remember_retired_template "$LIVE_TEMPLATE_ID"; then
            log_warn "Could not record template $LIVE_TEMPLATE_ID for retirement; destroy it once no runner uses it"
        fi
        log_info "TEMPLATE_ID is now $TEMPLATE_ID. Running clones stay on $LIVE_TEMPLATE_ID until their next reclone."
    fi
    forget_setup_bake
    if ! commit_baked_version "$BAKE_RUNNER_VERSION" "$TEMPLATE_ID"; then
        log_warn "Template was created but the baked runner version was not recorded"
    fi
    exec 199>&-
    log_info "Template created successfully (tools baked in)"
}

# Tests source this file for the functions above.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

require_root "setup"

echo "========================================"
echo "  GitHub Actions Runner Setup Wizard"
echo "========================================"
echo ""

# Check we're on Proxmox
if ! command -v qm &> /dev/null; then
    log_error "This script must be run on a Proxmox host"
    exit 1
fi

if ! command -v pvesm &> /dev/null; then
    log_error "pvesm command not found. Is this a Proxmox host?"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_info "Installing jq (required for pool watcher)..."
    apt-get install -y jq > /dev/null 2>&1 || {
        log_error "Failed to install jq. Install it manually: apt-get install jq"
        exit 1
    }
fi

# Check if template file exists
if [[ ! -f "$REPO_DIR/templates/runner-user-data.yaml" ]]; then
    log_error "templates/runner-user-data.yaml not found in $REPO_DIR"
    exit 1
fi

load_setup_prefills
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Saved settings are prefilled for editing. Enter keeps the shown value."
    echo "Clear the input (Ctrl-U), then Enter, to use the default in brackets."
    echo ""
fi

# Detect available bridges
echo "Available network bridges:"
BRIDGES=$(ip -br link | grep -E '^vmbr' | awk '{print $1}' || true)
if [[ -z "$BRIDGES" ]]; then
    log_warn "No bridges found (vmbr*). Using default vmbr0."
else
    # Indents every line, which ${var//} cannot do.
    # shellcheck disable=SC2001
    echo "$BRIDGES" | sed 's/^/  /'
fi
prompt_setup_value NETWORK_BRIDGE "Network bridge" vmbr0

# Validate bridge exists
if ! ip link show "$NETWORK_BRIDGE" &> /dev/null; then
    log_error "Bridge '$NETWORK_BRIDGE' does not exist"
    exit 1
fi

# VLAN tag (optional)
prompt_setup_value VLAN_TAG "VLAN tag (empty for none)" ""
if [[ -n "$VLAN_TAG" ]]; then
    if [[ ! "$VLAN_TAG" =~ ^[0-9]+$ ]] || [[ "$VLAN_TAG" -lt 1 || "$VLAN_TAG" -gt 4094 ]]; then
        log_error "VLAN tag must be a number between 1 and 4094"
        exit 1
    fi
fi

# Detect storage
echo ""
echo "Available storage pools:"
template_storages | awk '{print "  " $1 " (" $2 ")"}' || true
prompt_setup_value VM_STORAGE "Storage for VMs" local-zfs

# Validate storage exists and can hold a template and its linked clones
if ! check_vm_storage "$VM_STORAGE"; then
    exit 1
fi

prompt_setup_value TEMPLATE_ID "Template VM ID" 9000

# Validate before computing the minimum VMID default from this answer.
if [[ ! "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
    log_error "Template ID must be a number"
    exit 1
fi
if [[ "$TEMPLATE_ID" -lt 100 || "$TEMPLATE_ID" -gt 999999999 ]]; then
    log_error "Template ID must be between 100 and 999999999"
    exit 1
fi
if ! plan_template; then
    exit 1
fi

# Minimum VM ID for runners (0 = use Proxmox default)
DEFAULT_MIN_VMID=$((TEMPLATE_ID + 1))
prompt_setup_value MIN_VMID "Minimum VM ID for runners (0 = auto)" "$DEFAULT_MIN_VMID"
if [[ ! "$MIN_VMID" =~ ^[0-9]+$ ]]; then
    log_error "Minimum VM ID must be a non-negative number"
    exit 1
fi
if [[ "$MIN_VMID" -ne 0 && "$MIN_VMID" -lt 100 ]]; then
    log_error "Minimum VM ID must be at least 100"
    exit 1
fi

# Memory ballooning (0 = disabled)
prompt_setup_value BALLOON "Memory balloon, MB (0 = disabled)" 0
if [[ ! "$BALLOON" =~ ^[0-9]+$ ]]; then
    log_error "Balloon must be a non-negative number"
    exit 1
fi

# DNS nameservers for runner VMs (space-separated). "dhcp" stores an empty
# value, which keeps the servers DHCP offers.
prompt_dns_servers "1.1.1.1 8.8.8.8"
for ns in $DNS_SERVERS; do
    if [[ ! "$ns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! ("$ns" =~ ^[0-9a-fA-F:]+$ && "$ns" =~ :) ]]; then
        log_error "Invalid nameserver: $ns (must be an IPv4 or IPv6 address)"
        exit 1
    fi
done

# Docker registry mirror for Supabase images (optional, e.g., local Zot cache)
# Leave empty to disable — runners will pull directly from public.ecr.aws.
echo ""
echo "Docker mirror: a local OCI registry (e.g., http://lxc-ip:5000 Zot) that caches"
echo "Supabase public.ecr.aws images. HTTP mirrors are routed through Supabase's image"
echo "registry override; HTTPS mirrors also configure containerd pull-through hosts."
prompt_setup_value DOCKER_MIRROR_URL "Supabase Docker mirror URL (empty to disable)" ""
if [[ -n "$DOCKER_MIRROR_URL" ]]; then
    while [[ "$DOCKER_MIRROR_URL" == */ ]]; do
        DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL%/}"
    done
    if [[ ! "$DOCKER_MIRROR_URL" =~ ^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]+)?$ ]]; then
        log_error "Docker mirror URL must be scheme://host[:port], for example http://10.20.1.19:8080"
        exit 1
    fi
fi

# Confirm
echo ""
echo "Infrastructure configuration:"
echo "  Network Bridge: $NETWORK_BRIDGE"
echo "  VLAN Tag:       ${VLAN_TAG:-none}"
echo "  VM Storage:     $VM_STORAGE"
echo "  Template ID:    $TEMPLATE_ID"
echo "  Min VM ID:      $([ "${MIN_VMID:-0}" -eq 0 ] && echo "auto" || echo "$MIN_VMID")"
echo "  Balloon:        ${BALLOON:-0} MB ($([ "${BALLOON:-0}" -eq 0 ] && echo "disabled" || echo "enabled"))"
echo "  DNS Servers:    ${DNS_SERVERS:-DHCP only}"
echo "  Docker Mirror:  ${DOCKER_MIRROR_URL:-none}"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 0

# Install to /opt and create symlink
echo ""
log_info "[1/5] Installing to $INSTALL_DIR..."
if [[ "$REPO_DIR" != "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    cp -r "$REPO_DIR"/* "$INSTALL_DIR/"
    cp -r "$REPO_DIR"/.gitignore "$INSTALL_DIR/" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/runner" "$INSTALL_DIR/lib/"*.sh
    log_info "Copied files to $INSTALL_DIR"
else
    log_info "Already running from $INSTALL_DIR"
fi

# Create single symlink in /usr/local/bin
log_info "Creating symlink in /usr/local/bin..."
ln -sf "$INSTALL_DIR/runner" /usr/local/bin/runner
log_info "Command available: runner"

# Enable snippets on local storage
log_info "[2/5] Enabling snippets storage..."
if ! enable_local_snippets; then
    exit 1
fi
mkdir -p "$SNIPPETS_DIR"

# Install hookscript for auto-destroy on VM shutdown
log_info "Installing runner hookscript..."
cp "$INSTALL_DIR/templates/runner-hookscript.sh" "$SNIPPETS_DIR/runner-hookscript.sh"
chmod 755 "$SNIPPETS_DIR/runner-hookscript.sh"

# Save infra config
log_info "[3/5] Saving configuration..."
write_infra_config

prune_pat_snippets

# plan_template accepted the VM at TEMPLATE_ID only if it is a finished template.
if [[ "$TEMPLATE_READY" == 1 ]]; then
    log_info "[4/5] Template VM $TEMPLATE_ID already exists. Skipping creation."
    log_warn "To recreate: qm destroy $TEMPLATE_ID && runner setup"
    warn_template_storage
    if [[ ! -f "$BAKED_VERSION_FILE" ]]; then
        log_warn "No baked runner version is recorded. The daily rebake will bake once."
    fi
else
    log_info "[4/5] Creating baked Ubuntu cloud template..."
    bake_setup_template
fi

log_info "[5/5] Installing pool watcher and rebake timers..."
cp "$INSTALL_DIR/templates/github-runner-watch.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-watch.timer" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-rebake.service" /etc/systemd/system/
cp "$INSTALL_DIR/templates/github-runner-rebake.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now github-runner-watch.timer 2>/dev/null || true
systemctl enable --now github-runner-rebake.timer 2>/dev/null || true
log_info "Pool watcher timer installed (30s interval)"
log_info "Template rebake timer installed (daily)"

echo ""
echo "========================================"
echo "  Infrastructure setup complete!"
echo "========================================"
echo ""

# Add first org if none configured
mapfile -t existing_orgs < <(list_orgs)
if [[ ${#existing_orgs[@]} -eq 0 ]]; then
    echo "Now let's add your first GitHub organization."
    echo ""
    exec "$LIB_DIR/add-org.sh"
else
    echo "Existing orgs: ${existing_orgs[*]}"
    echo ""
    echo "To add another org:  runner add-org"
    echo "To list orgs:        runner list-orgs"
    echo ""
    warn_pat_snippet_vms
fi
