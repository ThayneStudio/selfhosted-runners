#!/bin/bash
# Non-interactive template rebake.
#
# Reads /etc/github-runners.conf and does not prompt. Bakes a second VM while
# the current template keeps serving clones, holds that VMID's reservation for
# the whole bake, and points TEMPLATE_ID at the new VM only after `qm template`
# succeeds. A failure destroys the partial VM and leaves the live template.
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

REBAKE_PUBLISHED=0
BAKE_VMID=""
LATEST_RUNNER_VERSION=""
LATEST_RUNNER_PUBLISHED_AT=""
RECORDED_RUNNER_VERSION=""
RECORDED_RUNNER_PUBLISHED_AT=""

normalize_runner_version() {
    local v="${1:-}"
    v=${v//$'\r'/}
    v=${v//$'\n'/}
    v=${v#v}
    v=${v#V}
    v=${v%%[[:space:]]*}
    printf '%s' "$v"
}

# 0 = a bake should start. 1 = the recorded release is still current.
# published_epoch is the actions/runner release time, in seconds.
rebake_needed() {
    local recorded latest published_epoch now_epoch max_age max_age_seconds
    recorded=$(normalize_runner_version "${1:-}")
    latest=$(normalize_runner_version "${2:-}")
    published_epoch="${3:-}"
    now_epoch="${4:-}"
    max_age="${5:-$REBAKE_MAX_AGE_DAYS}"

    [[ -n "$recorded" && -n "$latest" ]] || return 0
    [[ "$recorded" == "$latest" ]] || return 0
    [[ "$published_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 0
    [[ "$max_age" =~ ^[0-9]+$ ]] || return 0
    max_age_seconds=$((max_age * 86400))
    if (( now_epoch - published_epoch >= max_age_seconds )); then
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
            log_info "Baked actions/runner ${recorded} is ${REBAKE_MAX_AGE_DAYS} days old or its release date is unknown; baking"
        fi
        perform_bake
        return
    fi
    log_info "Template runner ${recorded} matches actions/runner ${latest} and is under ${REBAKE_MAX_AGE_DAYS} days old; not baking"
}

unquote_shell_literal() {
    local value="${1:-}"
    if [[ "$value" == \'*\' && "$value" != "''" ]]; then
        value=${value#\'}
        value=${value%\'}
    elif [[ "$value" == "''" ]]; then
        value=""
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
    local version="$1" published_at="$2" template_id="$3" tmp
    install -d -m 700 "$STATE_DIR"
    tmp=$(mktemp "$STATE_DIR/.baked-runner.XXXXXX")
    {
        printf 'version=%q\n' "$version"
        printf 'published_at=%q\n' "$published_at"
        printf 'template_id=%q\n' "$template_id"
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$BAKED_VERSION_FILE"
}

read_baked_record() {
    local line key value
    RECORDED_RUNNER_VERSION=""
    RECORDED_RUNNER_PUBLISHED_AT=""
    [[ -f "$BAKED_VERSION_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value=$(unquote_shell_literal "${BASH_REMATCH[2]}")
        case "$key" in
            version) RECORDED_RUNNER_VERSION="$value" ;;
            published_at) RECORDED_RUNNER_PUBLISHED_AT="$value" ;;
        esac
    done < "$BAKED_VERSION_FILE"
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
    write_baked_record "$version" "$published_at" "$template_id"
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

remember_retired_template() {
    local id="$1"
    [[ "$id" =~ ^[0-9]+$ ]] || return 0
    [[ "$id" == "$TEMPLATE_ID" ]] && return 0
    install -d -m 700 "$STATE_DIR"
    if [[ -f "$RETIRED_TEMPLATES_FILE" ]] && grep -qx "$id" "$RETIRED_TEMPLATES_FILE"; then
        return 0
    fi
    printf '%s\n' "$id" >> "$RETIRED_TEMPLATES_FILE"
    chmod 600 "$RETIRED_TEMPLATES_FILE"
}

switch_template_id() {
    local new_id="$1" old_id="$TEMPLATE_ID"
    set_conf_assignment "$CONFIG_FILE" TEMPLATE_ID "$new_id" || return 1
    TEMPLATE_ID="$new_id"
    if [[ -n "$old_id" && "$old_id" != "$new_id" ]]; then
        remember_retired_template "$old_id"
    fi
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

retire_retired_templates() {
    local id name kept_file tmp
    [[ -f "$RETIRED_TEMPLATES_FILE" ]] || return 0
    kept_file=$(mktemp)
    while IFS= read -r id || [[ -n "$id" ]]; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        if [[ "$id" == "$TEMPLATE_ID" ]]; then
            continue
        fi
        if ! qm_host status "$id" &>/dev/null; then
            continue
        fi
        if ! qm_host config "$id" 2>/dev/null | grep -q '^template: 1[[:space:]]*$'; then
            log_warn "Retired id $id is not a template; leaving it"
            printf '%s\n' "$id" >> "$kept_file"
            continue
        fi
        name=$(qm_host config "$id" 2>/dev/null | awk '/^name:/{print $2; exit}')
        if [[ "$name" != "ubuntu-cloud-template" ]]; then
            log_warn "Refusing to destroy VM $id (${name:-unnamed}); it is not a runner template"
            printf '%s\n' "$id" >> "$kept_file"
            continue
        fi
        if template_has_linked_clones "$id"; then
            log_info "Template $id still has linked clones; leaving it in place"
            printf '%s\n' "$id" >> "$kept_file"
            continue
        fi
        log_info "No linked clones depend on template $id; destroying it"
        if ! qm_host destroy "$id" --purge; then
            log_warn "Failed to destroy template $id; leaving it in place"
            printf '%s\n' "$id" >> "$kept_file"
        fi
    done < "$RETIRED_TEMPLATES_FILE"
    if [[ -s "$kept_file" ]]; then
        tmp=$(mktemp "$STATE_DIR/.retired.XXXXXX")
        chmod 600 "$tmp"
        cat "$kept_file" > "$tmp"
        mv -f "$tmp" "$RETIRED_TEMPLATES_FILE"
    else
        rm -f "$RETIRED_TEMPLATES_FILE"
    fi
    rm -f "$kept_file"
}

cleanup_rebake() {
    local rc=$? name cfg
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
                elif printf '%s\n' "$cfg" | grep -q '^template: 1[[:space:]]*$'; then
                    # qm template can finish before REBAKE_PUBLISHED is set. Keep
                    # the pending files so the next run can switch TEMPLATE_ID.
                    # A signal can also leave $? at 0; the oneshot must not
                    # report success while the new template is still unpublished.
                    log_warn "Rebake VM $BAKE_VMID is already a template; leaving it for the next run to publish"
                    if [[ "$rc" -eq 0 ]]; then
                        rc=1
                    fi
                else
                    log_warn "Rebake failed; destroying partial VM $BAKE_VMID and leaving template ${TEMPLATE_ID} unchanged"
                    qm_host stop "$BAKE_VMID" --timeout 30 2>/dev/null || true
                    if qm_host destroy "$BAKE_VMID" --purge; then
                        rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
                    else
                        log_error "Could not destroy partial VM $BAKE_VMID; it stays recorded in $PENDING_BAKE_FILE"
                    fi
                fi
            fi
        else
            rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
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
        rm -f "$PENDING_BAKE_FILE" "$PENDING_VERSION_FILE"
        return 0
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
    if printf '%s\n' "$cfg" | grep -q '^template: 1[[:space:]]*$'; then
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
        log_error "Pending bake id $id is the live template VM and is not a template; leaving it"
        return 1
    fi
    log_warn "Destroying incomplete rebake VM $id"
    qm_host stop "$id" --timeout 30 2>/dev/null || true
    if qm_host destroy "$id" --purge; then
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
    trap cleanup_rebake EXIT INT TERM
    log_info "Baking replacement template on VMID $new_vmid (live template $old_template keeps serving clones)"
    create_bake_vm "$new_vmid"
    BAKE_WRITE_PENDING_VERSION=1
    bake_and_publish_vm "$new_vmid"
    # qm template succeeded. From here the partial-VM trap must not destroy it.
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
    if [[ -f /etc/systemd/system/github-runner-rebake.service ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl start --no-block github-runner-rebake.service
        log_info "Follow it with: journalctl -u github-runner-rebake.service -f"
        exit 0
    fi
    if ! command -v setsid >/dev/null 2>&1; then
        log_error "setsid is not available and github-runner-rebake.service is not installed"
        log_error "Install the unit, or run 'runner rebake --foreground' inside tmux"
        exit 1
    fi
    touch /var/log/github-runner-rebake.log
    chmod 600 /var/log/github-runner-rebake.log
    # setsid -f returns after forking, so this shell can exit without a job
    # left in the SSH session. A dead tty plus set -e would otherwise fire the
    # destroy trap on the next log write.
    if ! REBAKE_DETACHED=1 setsid -f "$REPO_DIR/runner" rebake >>/var/log/github-runner-rebake.log 2>&1 </dev/null; then
        log_error "Could not detach the rebake (setsid -f failed)"
        log_error "Run 'runner rebake --foreground' inside tmux"
        exit 1
    fi
    log_info "Rebake started. Log: /var/log/github-runner-rebake.log"
    exit 0
}

rebake_main() {
    local published_epoch="" now_epoch
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
    if [[ -n "$LATEST_RUNNER_PUBLISHED_AT" ]]; then
        published_epoch=$(date -u -d "$LATEST_RUNNER_PUBLISHED_AT" +%s 2>/dev/null || true)
    fi
    # Versions match, so the date stored at bake time is that same release.
    if [[ -z "$published_epoch" && "$RECORDED_RUNNER_VERSION" == "$LATEST_RUNNER_VERSION" && -n "$RECORDED_RUNNER_PUBLISHED_AT" ]]; then
        published_epoch=$(date -u -d "$RECORDED_RUNNER_PUBLISHED_AT" +%s 2>/dev/null || true)
    fi
    now_epoch=$(date -u +%s)
    rebake_apply_decision "$RECORDED_RUNNER_VERSION" "$LATEST_RUNNER_VERSION" "$published_epoch" "$now_epoch"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rebake_main "$@"
fi
