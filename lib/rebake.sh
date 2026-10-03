#!/bin/bash
# Non-interactive template rebake.
#
# Reads /etc/github-runners.conf and does not prompt. Bakes a second VM while
# the current template keeps serving clones, holds that VMID's reservation for
# the whole bake, and points TEMPLATE_ID at the new VM only after `qm template`
# has converted its disks to base volumes. A failure destroys the partial VM
# and leaves the live template.
set -euo pipefail

REBAKE_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=common.sh
source "$REBAKE_LIB_DIR/common.sh"
# shellcheck source=bake.sh
source "$REBAKE_LIB_DIR/bake.sh"

REBAKE_MAX_AGE_DAYS=21
STATE_DIR="/var/lib/github-runners"
BAKED_VERSION_FILE="$STATE_DIR/baked-runner-version"
RETIRED_TEMPLATES_FILE="$STATE_DIR/retired-templates"
PENDING_BAKE_FILE="$STATE_DIR/pending-bake"
PENDING_VERSION_FILE="$STATE_DIR/pending-version"
REBAKE_LOCK_FILE="/run/lock/github-runner-rebake.lock"
REBAKE_UNIT_FILE="/etc/systemd/system/github-runner-rebake.service"
REBAKE_LOG_FILE="/var/log/github-runner-rebake.log"

REBAKE_PUBLISHED=0
BAKE_VMID=""
LATEST_RUNNER_VERSION=""
LATEST_RUNNER_PUBLISHED_AT=""
RECORDED_RUNNER_VERSION=""
RECORDED_RUNNER_PUBLISHED_AT=""
RECORDED_TEMPLATE_ID=""
RECORDED_BAKED_AT=""
RECORDED_DOCKER_MIRROR_URL=""
RECORDED_DOCKER_MIRROR_KNOWN=0

normalize_runner_version() {
    local v="${1:-}"
    v=${v//$'\r'/}
    v=${v//$'\n'/}
    v=${v#v}
    v=${v#V}
    v=${v%%[[:space:]]*}
    printf '%s' "$v"
}

# 0 = a bake should start. 1 = the template is still current.
# baked_epoch is the last successful bake time, in seconds.
rebake_needed() {
    local recorded latest baked_epoch now_epoch max_age max_age_seconds
    recorded=$(normalize_runner_version "${1:-}")
    latest=$(normalize_runner_version "${2:-}")
    baked_epoch="${3:-}"
    now_epoch="${4:-}"
    max_age="${5:-$REBAKE_MAX_AGE_DAYS}"

    [[ -n "$recorded" && -n "$latest" ]] || return 0
    [[ "$recorded" == "$latest" ]] || return 0
    [[ "$baked_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 0
    (( baked_epoch <= now_epoch )) || return 0
    [[ "$max_age" =~ ^[0-9]+$ ]] || return 0
    max_age_seconds=$((max_age * 86400))
    if (( now_epoch - baked_epoch >= max_age_seconds )); then
        return 0
    fi
    return 1
}

# The only call site of perform_bake. "Already current" returns without it.
rebake_apply_decision() {
    local recorded latest
    recorded=$(normalize_runner_version "${1:-}")
    latest=$(normalize_runner_version "${2:-}")
    if rebake_needed "$recorded" "$latest" "${3:-}" "${4:-}" "${5:-$REBAKE_MAX_AGE_DAYS}"; then
        if [[ -z "$recorded" ]]; then
            log_info "No baked Runner.Listener version is recorded on the host; baking"
        elif [[ "$recorded" != "$latest" ]]; then
            log_info "Baked runner ${recorded} differs from actions/runner ${latest}; baking"
        else
            log_info "Template with runner ${recorded} is ${REBAKE_MAX_AGE_DAYS} days old or its bake time is unknown; baking"
        fi
        perform_bake
        return
    fi
    log_info "Template runner ${recorded} matches actions/runner ${latest} and the template is under ${REBAKE_MAX_AGE_DAYS} days old; not baking"
}

unquote_shell_literal() {
    local value="${1:-}" out="" i
    if [[ "$value" == \'*\' && "$value" != "''" ]]; then
        value=${value#\'}
        value=${value%\'}
    elif [[ "$value" == "''" ]]; then
        value=""
    elif [[ "$value" == *\\* ]]; then
        # printf %q backslash-escapes characters such as the brackets of an
        # IPv6 mirror URL. Drop each escaping backslash.
        for ((i = 0; i < ${#value}; i++)); do
            if [[ "${value:i:1}" == \\ ]]; then
                i=$((i + 1))
            fi
            out+="${value:i:1}"
        done
        value=$out
    fi
    printf '%s' "$value"
}

set_conf_assignment() {
    local file="$1" key="$2" value="$3" tmp quoted
    printf -v quoted '%q' "$value"
    tmp=$(mktemp "${file}.XXXXXX")
    # Callers invoke this under `||`, which disables errexit for the whole
    # function. A failed awk must not chmod and mv a truncated file into place.
    CONF_KEY="$key" CONF_VALUE="$quoted" awk '
        index($0, ENVIRON["CONF_KEY"] "=") == 1 {
            print ENVIRON["CONF_KEY"] "=" ENVIRON["CONF_VALUE"]
            found = 1
            next
        }
        { print }
        END {
            if (!found) {
                print ENVIRON["CONF_KEY"] "=" ENVIRON["CONF_VALUE"]
            }
        }
    ' "$file" > "$tmp" || {
        rm -f "$tmp"
        log_error "Failed to update $key in $file"
        return 1
    }
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}

write_baked_record() {
    local version="$1" published_at="$2" template_id="$3" docker_mirror_url="${4:-}" tmp baked_at
    baked_at=$(date -u +%s) || return 1
    install -d -m 700 "$STATE_DIR" || return 1
    tmp=$(mktemp "$STATE_DIR/.baked-runner.XXXXXX") || return 1
    if ! printf 'version=%q\npublished_at=%q\ntemplate_id=%q\nbaked_at=%q\ndocker_mirror_url=%q\n' \
        "$version" "$published_at" "$template_id" "$baked_at" "$docker_mirror_url" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$BAKED_VERSION_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

read_baked_record() {
    local line key value
    RECORDED_RUNNER_VERSION=""
    RECORDED_RUNNER_PUBLISHED_AT=""
    RECORDED_TEMPLATE_ID=""
    RECORDED_BAKED_AT=""
    RECORDED_DOCKER_MIRROR_URL=""
    RECORDED_DOCKER_MIRROR_KNOWN=0
    [[ -f "$BAKED_VERSION_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value=$(unquote_shell_literal "${BASH_REMATCH[2]}")
        case "$key" in
            version) RECORDED_RUNNER_VERSION="$value" ;;
            published_at)
                # Retained as metadata for callers inspecting the record.
                # shellcheck disable=SC2034
                RECORDED_RUNNER_PUBLISHED_AT="$value"
                ;;
            template_id) RECORDED_TEMPLATE_ID="$value" ;;
            baked_at) RECORDED_BAKED_AT="$value" ;;
            # Empty means baked without a mirror, so presence is tracked apart.
            docker_mirror_url)
                RECORDED_DOCKER_MIRROR_URL="$value"
                RECORDED_DOCKER_MIRROR_KNOWN=1
                ;;
        esac
    done < "$BAKED_VERSION_FILE"
}

# The record describes the template it names, baked with the Docker mirror it
# names. When the config no longer matches, the record says nothing about what
# clones get: ignore it so the decision bakes once. Fields that an older or
# hand-written record lacks are not compared.
# - TEMPLATE_ID moved off that template without a rebake (setup pointed at
#   another VM, a hand edit, setup racing a rebake).
# - DOCKER_MIRROR_URL changed. Clones rewrite daemon.json for the configured
#   mirror: a different scheme moves Docker to another image store, which
#   hides the warmed image cache, and a different host renames the warmed
#   Supabase images.
discard_stale_baked_record() {
    if [[ -n "$RECORDED_TEMPLATE_ID" && "$RECORDED_TEMPLATE_ID" != "$TEMPLATE_ID" ]]; then
        log_info "The baked-version record is for template $RECORDED_TEMPLATE_ID, not TEMPLATE_ID $TEMPLATE_ID; ignoring it"
        # Nothing listed that template for retirement when TEMPLATE_ID moved,
        # so it would leak. Retirement still checks its name and linked clones.
        if ! remember_retired_template "$RECORDED_TEMPLATE_ID"; then
            log_error "Could not queue template $RECORDED_TEMPLATE_ID for retirement; not baking"
            return 1
        fi
    elif [[ "$RECORDED_DOCKER_MIRROR_KNOWN" == 1 && "$RECORDED_DOCKER_MIRROR_URL" != "${DOCKER_MIRROR_URL:-}" ]]; then
        log_info "The template was baked with Docker mirror ${RECORDED_DOCKER_MIRROR_URL:-none}, not ${DOCKER_MIRROR_URL:-none}; ignoring the baked-version record"
    else
        return 0
    fi
    RECORDED_RUNNER_VERSION=""
    RECORDED_BAKED_AT=""
}

commit_baked_version() {
    local version published_at="" template_id json
    version=$(normalize_runner_version "${1:-}")
    template_id="${2:-}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$template_id" =~ ^[0-9]+$ ]] || return 1
    json=$(curl -sf --retry 3 --max-time 30 \
        "https://api.github.com/repos/actions/runner/releases/tags/v${version}" || true)
    if [[ -n "$json" ]]; then
        published_at=$(printf '%s\n' "$json" | jq -r '.published_at // empty' 2>/dev/null || true)
    fi
    if [[ "$published_at" == "null" ]]; then
        published_at=""
    fi
    # Every bake renders its snippet from the loaded DOCKER_MIRROR_URL. A run
    # that finishes publishing an earlier run's bake records the mirror set
    # now, which is wrong only if setup changed it while that publish was
    # pending.
    write_baked_record "$version" "$published_at" "$template_id" "${DOCKER_MIRROR_URL:-}"
}

fetch_latest_runner_release() {
    local json
    json=$(curl -sf --retry 3 --max-time 30 \
        https://api.github.com/repos/actions/runner/releases/latest) || return 1
    LATEST_RUNNER_VERSION=$(printf '%s\n' "$json" | jq -r '.tag_name // empty') || return 1
    LATEST_RUNNER_PUBLISHED_AT=$(printf '%s\n' "$json" | jq -r '.published_at // empty') || return 1
    [[ -n "$LATEST_RUNNER_VERSION" && "$LATEST_RUNNER_VERSION" != "null" ]] || return 1
    LATEST_RUNNER_VERSION=$(normalize_runner_version "$LATEST_RUNNER_VERSION")
    # jq -r already turns JSON null into an empty string. This must not be a
    # trailing `&&` command: a false test would be this function's status, and
    # rebake_main treats that as "could not read the release".
    if [[ "$LATEST_RUNNER_PUBLISHED_AT" == "null" ]]; then
        LATEST_RUNNER_PUBLISHED_AT=""
    fi
    return 0
}

# Replaces the retired list with the ids given; no ids removes it. The list is
# written beside the old one and renamed over it, so a failed write (ENOSPC)
# returns non-zero and leaves the old list as it was.
write_retired_templates() {
    local tmp
    if [[ $# -eq 0 ]]; then
        rm -f "$RETIRED_TEMPLATES_FILE"
        return
    fi
    install -d -m 700 "$STATE_DIR" || return 1
    tmp=$(mktemp "$STATE_DIR/.retired.XXXXXX") || return 1
    if ! printf '%s\n' "$@" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$RETIRED_TEMPLATES_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

# Adds template $1 to the retired list unless it is $2, the template that
# stays live (TEMPLATE_ID by default). Non-zero means it was not recorded.
remember_retired_template() {
    local id="$1" live="${2:-$TEMPLATE_ID}" entry
    local -a ids=()
    [[ "$id" =~ ^[0-9]+$ ]] || return 0
    [[ "$id" != "$live" ]] || return 0
    if [[ -f "$RETIRED_TEMPLATES_FILE" ]]; then
        while IFS= read -r entry || [[ -n "$entry" ]]; do
            [[ "$entry" =~ ^[0-9]+$ ]] || continue
            [[ "$entry" != "$id" ]] || return 0
            ids+=("$entry")
        done < "$RETIRED_TEMPLATES_FILE" || return 1
    fi
    write_retired_templates "${ids[@]}" "$id"
}

forget_retired_template() {
    local id="$1" entry
    local -a ids=()
    [[ -f "$RETIRED_TEMPLATES_FILE" ]] || return 0
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        if [[ "$entry" =~ ^[0-9]+$ && "$entry" != "$id" ]]; then
            ids+=("$entry")
        fi
    done < "$RETIRED_TEMPLATES_FILE" || return 1
    write_retired_templates "${ids[@]}"
}

switch_template_id() {
    local new_id="$1" old_id="$TEMPLATE_ID" listed=0
    # Record the old template before TEMPLATE_ID stops naming it: once the
    # config points elsewhere nothing else remembers it, and a failed write
    # after the switch (ENOSPC) leaked it for good.
    if [[ -n "$old_id" && "$old_id" != "$new_id" ]]; then
        if ! remember_retired_template "$old_id" "$new_id"; then
            log_error "Could not record template $old_id as retired; leaving TEMPLATE_ID at $old_id"
            return 1
        fi
        listed=1
    fi
    if ! set_conf_assignment "$CONFIG_FILE" TEMPLATE_ID "$new_id"; then
        # The old template stays live. retire_retired_templates skips the live
        # TEMPLATE_ID, so an entry left behind by a failed undo is harmless.
        if [[ "$listed" == 1 ]]; then
            forget_retired_template "$old_id" || log_warn "Template $old_id stays listed in $RETIRED_TEMPLATES_FILE"
        fi
        return 1
    fi
    TEMPLATE_ID="$new_id"
}

# 0 when a linked clone still depends on the template, or when that cannot be
# proven. Callers must not destroy on 0.
template_has_linked_clones() {
    local template_id="$1" vols
    if ! vols=$(list_template_linked_clone_volids "$template_id"); then
        log_warn "Could not list linked clones of template $template_id; not destroying it"
        return 0
    fi
    [[ -n "$vols" ]]
}

# A failed qm status is not proof of absence. Only a readable cluster inventory
# without this VMID lets us discard a recovery record (including other nodes).
vm_confirmed_absent() {
    local id="$1" inventory
    inventory=$(pvesh get /cluster/resources --type vm --output-format json \
        199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null) || return 1
    printf '%s\n' "$inventory" | jq -e --argjson id "$id" \
        'type == "array" and all(.[]; (.vmid | type) == "number" and .vmid != $id)' >/dev/null 2>&1
}

# 0 only when a readable cluster inventory lists this VMID as a guest that is
# not a QEMU VM (a container). A rebake VM is always QEMU, so a pending record
# for that VMID is stale: its bake VM is gone, or `qm create` never made it.
vmid_is_non_qemu_guest() {
    local id="$1" inventory
    inventory=$(pvesh get /cluster/resources --type vm --output-format json \
        199>&- 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null) || return 1
    printf '%s\n' "$inventory" | jq -e --argjson id "$id" \
        'type == "array" and any(.[]; .vmid == $id and (.type | type) == "string" and .type != "qemu")' >/dev/null 2>&1
}

retire_retired_templates() {
    local id name
    local -a kept=()
    [[ -f "$RETIRED_TEMPLATES_FILE" ]] || return 0
    while IFS= read -r id || [[ -n "$id" ]]; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        if [[ "$id" == "$TEMPLATE_ID" ]]; then
            continue
        fi
        if ! qm_host status "$id" &>/dev/null; then
            if ! vm_confirmed_absent "$id"; then
                log_warn "Could not confirm retired VM $id is absent; retaining its record"
                kept+=("$id")
            fi
            continue
        fi
        if ! qm_host config "$id" 2>/dev/null | grep -q '^template: 1[[:space:]]*$'; then
            log_warn "Retired id $id is not a template; leaving it"
            kept+=("$id")
            continue
        fi
        name=$(qm_host config "$id" 2>/dev/null | awk '/^name:/{print $2; exit}')
        if [[ "$name" != "ubuntu-cloud-template" ]]; then
            log_warn "Refusing to destroy VM $id (${name:-unnamed}); it is not a runner template"
            kept+=("$id")
            continue
        fi
        if template_has_linked_clones "$id"; then
            log_info "Template $id still has linked clones; leaving it in place"
            kept+=("$id")
            continue
        fi
        log_info "No linked clones depend on template $id; destroying it"
        # No --purge: it also deletes the VMID from backup-job include and
        # exclude lists, and that VMID is handed out again.
        if ! qm_host destroy "$id"; then
            log_warn "Failed to destroy template $id; leaving it in place"
            kept+=("$id")
        fi
    done < "$RETIRED_TEMPLATES_FILE" || {
        log_error "Could not read $RETIRED_TEMPLATES_FILE; leaving it unchanged"
        return 1
    }
    # perform_bake calls this under `||`, which disables errexit in here. A
    # failed rewrite must keep the old list, not forget a template in use.
    if ! write_retired_templates "${kept[@]}"; then
        log_error "Could not rewrite $RETIRED_TEMPLATES_FILE; leaving it unchanged"
        return 1
    fi
}

cleanup_rebake() {
    # Signal traps pass their status: $? there is the last command's, often 0.
    local rc=${1:-$?} name cfg
    trap - EXIT INT TERM
    if [[ "${REBAKE_PUBLISHED:-0}" != 1 && -n "${BAKE_VMID:-}" ]]; then
        if qm_host status "$BAKE_VMID" &>/dev/null; then
            if ! cfg=$(qm_host config "$BAKE_VMID" 2>/dev/null); then
                # Unreadable config is not proof this is a partial VM. A
                # signal can also leave $? at 0.
                log_error "Could not read config for VM $BAKE_VMID; leaving it and the pending record"
                if [[ "$rc" -eq 0 ]]; then
                    rc=1
                fi
            else
                name=$(printf '%s\n' "$cfg" | awk '/^name:/{print $2; exit}')
                if [[ "$name" != "ubuntu-cloud-template" ]]; then
                    log_error "Refusing to destroy VM $BAKE_VMID (${name:-unnamed}); it is not the rebake VM"
                elif [[ "$BAKE_VMID" == "$TEMPLATE_ID" ]]; then
                    log_error "Refusing to destroy VM $BAKE_VMID; it is the live template"
                    if [[ "$rc" -eq 0 ]]; then
                        rc=1
                    fi
                elif template_is_converted "$BAKE_VMID"; then
                    # qm template can finish before REBAKE_PUBLISHED is set. Keep
                    # the pending files so the next run can switch TEMPLATE_ID.
                    # A signal can also leave $? at 0; the oneshot must not
                    # report success while the new template is still unpublished.
                    log_warn "Rebake VM $BAKE_VMID is already a template; leaving it for the next run to publish"
                    if [[ "$rc" -eq 0 ]]; then
                        rc=1
                    fi
                else
                    # This includes `template: 1` over unconverted disks: qm
                    # template writes the flag first, and no clone can use it.
                    log_warn "Rebake failed; destroying partial VM $BAKE_VMID and leaving template ${TEMPLATE_ID} unchanged"
                    qm_host stop "$BAKE_VMID" --timeout 30 2>/dev/null || true
                    if qm_host destroy "$BAKE_VMID"; then
                        rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
                    else
                        log_error "Could not destroy partial VM $BAKE_VMID; it stays recorded in $PENDING_BAKE_FILE"
                    fi
                fi
            fi
        else
            if vm_confirmed_absent "$BAKE_VMID"; then
                rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
            elif vmid_is_non_qemu_guest "$BAKE_VMID"; then
                log_warn "VMID $BAKE_VMID belongs to a container, not the rebake VM; dropping the pending record"
                rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
            else
                log_error "Could not confirm rebake VM $BAKE_VMID is absent; retaining the pending record"
                [[ "$rc" -ne 0 ]] || rc=1
            fi
        fi
    fi
    release_vmid_reservation "${BAKE_VMID:-}"
    exit "$rc"
}

recover_pending_bake() {
    local id ver cfg name
    [[ -f "$PENDING_BAKE_FILE" ]] || return 0
    id=$(tr -d '[:space:]' < "$PENDING_BAKE_FILE")
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
        return 0
    fi
    if ! qm_host status "$id" &>/dev/null; then
        if vm_confirmed_absent "$id"; then
            rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
            return 0
        fi
        # Kept, this record would fail every later run before the release check.
        if vmid_is_non_qemu_guest "$id"; then
            log_warn "Pending bake id $id belongs to a container, not a rebake VM; dropping the stale pending record"
            rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
            return 0
        fi
        log_error "Could not confirm pending bake VM $id is absent; retaining its record"
        return 1
    fi
    if ! cfg=$(qm_host config "$id" 2>/dev/null); then
        log_error "Could not read config for pending bake VM $id; leaving it"
        return 1
    fi
    # The reservation lock dies with the process. The watcher can reuse a VMID
    # whose VM was already destroyed. Never destroy or publish that replacement.
    name=$(printf '%s\n' "$cfg" | awk '/^name:/{print $2; exit}')
    if [[ "$name" != "ubuntu-cloud-template" ]]; then
        log_error "Pending bake id $id is ${name:-unnamed}; leaving that VM and dropping the stale pending record"
        rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
        return 0
    fi
    # Never publish on `template: 1` alone: Proxmox writes it before converting
    # the disks, and a template without base volumes cannot be cloned.
    if template_is_converted "$id"; then
        if [[ "$id" != "$TEMPLATE_ID" ]]; then
            log_info "Finishing publish of template $id"
            switch_template_id "$id"
        fi
        if [[ -f "$PENDING_VERSION_FILE" ]]; then
            ver=$(sed -n 's/^version=//p' "$PENDING_VERSION_FILE" | head -1)
            ver=$(unquote_shell_literal "$ver")
            if ! commit_baked_version "$ver" "$id"; then
                log_warn "Template $id is published but its runner version was not recorded"
            fi
        fi
        rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
        return 0
    fi
    if [[ "$id" == "$TEMPLATE_ID" ]]; then
        log_error "Pending bake id $id is the live template VM and is not a converted template; leaving it"
        return 1
    fi
    # This includes `template: 1` over disks that were never converted.
    log_warn "Destroying incomplete rebake VM $id"
    qm_host stop "$id" --timeout 30 2>/dev/null || true
    if qm_host destroy "$id"; then
        rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
        return 0
    fi
    log_error "Could not destroy incomplete rebake VM $id"
    return 1
}

validate_saved_infra() {
    local ns
    local -a dns_list=()
    if [[ -n "${VLAN_TAG:-}" ]]; then
        if [[ ! "$VLAN_TAG" =~ ^[0-9]+$ ]] || (( VLAN_TAG < 1 || VLAN_TAG > 4094 )); then
            log_error "VLAN_TAG in $CONFIG_FILE is invalid"
            return 1
        fi
    fi
    if [[ -n "${DOCKER_MIRROR_URL:-}" ]]; then
        if [[ ! "$DOCKER_MIRROR_URL" =~ ^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]+)?$ ]]; then
            log_error "DOCKER_MIRROR_URL in $CONFIG_FILE is invalid"
            return 1
        fi
    fi
    if [[ ! "$TEMPLATE_ID" =~ ^[0-9]+$ ]] || (( TEMPLATE_ID < 100 || TEMPLATE_ID > 999999999 )); then
        log_error "TEMPLATE_ID in $CONFIG_FILE is invalid"
        return 1
    fi
    if [[ -n "${BALLOON:-}" && ! "$BALLOON" =~ ^[0-9]+$ ]]; then
        log_error "BALLOON in $CONFIG_FILE is invalid"
        return 1
    fi
    if [[ -n "${MIN_VMID:-}" && ! "$MIN_VMID" =~ ^[0-9]+$ ]]; then
        log_error "MIN_VMID in $CONFIG_FILE is invalid"
        return 1
    fi
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        read -ra dns_list <<< "${DNS_SERVERS}"
        for ns in "${dns_list[@]}"; do
            if [[ ! "$ns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! ("$ns" =~ ^[0-9a-fA-F:]+$ && "$ns" =~ :) ]]; then
                log_error "Invalid nameserver in $CONFIG_FILE: $ns"
                return 1
            fi
        done
    fi
}

require_live_template() {
    local cfg
    cfg=$(qm_host config "$TEMPLATE_ID" 2>/dev/null) || {
        log_error "Template VM $TEMPLATE_ID does not exist. Run 'runner setup' to create one."
        return 1
    }
    printf '%s\n' "$cfg" | grep -q '^template: 1[[:space:]]*$' || {
        log_error "VM $TEMPLATE_ID is not a template. Run 'runner setup' to create one."
        return 1
    }
    # The flag is written before qm template converts the disks.
    template_is_converted "$TEMPLATE_ID" || {
        log_error "Template $TEMPLATE_ID has disks that are not base volumes, so it cannot be cloned."
        log_error "Inspect it with 'qm config $TEMPLATE_ID'; destroy it and run 'runner setup' to bake a new one."
        return 1
    }
}

perform_bake() {
    local new_vmid old_template
    # Checksum failure deletes the cached image and returns before a VM exists.
    # Simple commands, not `|| exit`: `||` disables errexit inside the callee.
    prepare_cloud_image
    # reserve_vmid starts at MIN_VMID and walks upward. Hold fd 203 until the
    # bake ends so the 30-second watcher cannot take this VMID.
    reserve_vmid
    new_vmid=$RESERVED_VMID
    BAKE_VMID=$new_vmid
    old_template=$TEMPLATE_ID
    install -d -m 700 "$STATE_DIR"
    printf '%s\n' "$new_vmid" > "$PENDING_BAKE_FILE"
    chmod 600 "$PENDING_BAKE_FILE"
    trap cleanup_rebake EXIT
    trap 'cleanup_rebake 130' INT
    trap 'cleanup_rebake 143' TERM
    log_info "Baking replacement template on VMID $new_vmid (live template $old_template keeps serving clones)"
    create_bake_vm "$new_vmid"
    BAKE_WRITE_PENDING_VERSION=1
    bake_and_publish_vm "$new_vmid"
    # bake_and_publish_vm returns 0 only after template_is_converted accepts the
    # VM, so the switch and the record below name a template clones can use.
    # From here the partial-VM trap must not destroy it.
    REBAKE_PUBLISHED=1
    switch_template_id "$new_vmid"
    commit_baked_version "$BAKE_RUNNER_VERSION" "$new_vmid"
    rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
    release_vmid_reservation "$new_vmid"
    trap - EXIT INT TERM
    retire_retired_templates || true
    log_info "TEMPLATE_ID is now $new_vmid. Running clones stay on $old_template until their next reclone."
}

detach_rebake_from_ssh() {
    if [[ "${REBAKE_FOREGROUND:-}" == 1 || -n "${INVOCATION_ID:-}" || "${REBAKE_DETACHED:-}" == 1 ]]; then
        return 0
    fi
    log_info "Starting the rebake outside this shell so an SSH drop cannot kill it"
    # systemctl start cannot pass this shell's environment to the unit, which
    # would drop a BAKE_TIMEOUT or BAKE_MIN_FREE_GIB override (and its
    # TimeoutStartSec caps the run). setsid keeps the environment, so an
    # override goes that way.
    if [[ -z "${BAKE_TIMEOUT:-}" && -z "${BAKE_MIN_FREE_GIB:-}" && -f "$REBAKE_UNIT_FILE" ]] \
        && command -v systemctl >/dev/null 2>&1; then
        systemctl start --no-block github-runner-rebake.service
        log_info "Follow it with: journalctl -u github-runner-rebake.service -f"
        exit 0
    fi
    if ! command -v setsid >/dev/null 2>&1; then
        if [[ -n "${BAKE_TIMEOUT:-}" || -n "${BAKE_MIN_FREE_GIB:-}" ]]; then
            log_error "setsid is not available, and github-runner-rebake.service cannot take BAKE_TIMEOUT or BAKE_MIN_FREE_GIB"
            log_error "Run 'runner rebake --foreground' inside tmux"
        else
            log_error "setsid is not available and github-runner-rebake.service is not installed"
            log_error "Install the unit, or run 'runner rebake --foreground' inside tmux"
        fi
        exit 1
    fi
    touch "$REBAKE_LOG_FILE"
    chmod 600 "$REBAKE_LOG_FILE"
    # setsid -f returns after forking, so this shell can exit without a job
    # left in the SSH session. A dead tty plus set -e would otherwise fire the
    # destroy trap on the next log write.
    if ! REBAKE_DETACHED=1 setsid -f "$REPO_DIR/runner" rebake >>"$REBAKE_LOG_FILE" 2>&1 </dev/null; then
        log_error "Could not detach the rebake (setsid -f failed)"
        log_error "Run 'runner rebake --foreground' inside tmux"
        exit 1
    fi
    log_info "Rebake started. Log: $REBAKE_LOG_FILE"
    exit 0
}

rebake_main() {
    local now_epoch
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --foreground)
                REBAKE_FOREGROUND=1
                shift
                ;;
            -h|--help)
                echo "Usage: runner rebake [--foreground]"
                echo "Bake a replacement template from /etc/github-runners.conf when the"
                echo "baked actions/runner release is stale. Detaches unless --foreground."
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    require_root rebake
    # A detached rebake reports errors only in its log, after "Rebake started".
    # Refuse a bad override here, where the caller sees it.
    check_bake_timeout || exit 1
    check_bake_min_free_gib || exit 1
    detach_rebake_from_ssh
    trap '' HUP PIPE
    if ! command -v qm >/dev/null 2>&1; then
        log_error "This command must be run on a Proxmox host"
        exit 1
    fi
    load_infra_config
    validate_saved_infra
    require_live_template

    exec 199>"$REBAKE_LOCK_FILE"
    if ! flock -n 199; then
        log_info "A rebake is already running"
        exit 0
    fi

    recover_pending_bake
    retire_retired_templates
    if ! fetch_latest_runner_release; then
        log_error "Could not read the latest actions/runner release; not baking"
        exit 1
    fi
    read_baked_record
    discard_stale_baked_record
    now_epoch=$(date -u +%s)
    rebake_apply_decision "$RECORDED_RUNNER_VERSION" "$LATEST_RUNNER_VERSION" "$RECORDED_BAKED_AT" "$now_epoch"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rebake_main "$@"
fi
