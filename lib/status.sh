#!/bin/bash
# Fleet health overview: generations, runner version vs upstream, 30-day
# window, last bake, per-org pool fill, drain, last notification.
#
# Library: functions only at source time. Tests load_lib status.sh and call
# status_main. When executed as the CLI (`BASH_SOURCE == $0`), require_root,
# load config if present, then status_main. Do not require_root at source time.
#
# Read-only: never writes config, VMs, or generation records, and never
# notifies. Drift notifications belong to issue #12. Non-zero exit when
# something needs attention so this can be used as a check.
#
# GEN_* fields are loaded via gen_read in this shell.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_STATUS_LOADED:-}" ]]; then
    return 0
fi
RUNNER_STATUS_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=generations.sh
source "$LIB_DIR/generations.sh"

# GitHub refuses jobs on a runner more than this many days after a newer
# actions/runner release. Display-only here; the drift alarm owns notify.
STATUS_DRIFT_WINDOW_DAYS=30

_status_fetch_upstream() {
    local json tag="" published=""
    _STATUS_UPSTREAM_VERSION=""
    _STATUS_UPSTREAM_PUBLISHED=""
    json=$(curl -sf --retry 3 --max-time 20 \
        https://api.github.com/repos/actions/runner/releases/latest) || return 1
    if [[ "$json" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        tag="${BASH_REMATCH[1]}"
        tag="${tag#v}"
    fi
    if [[ "$json" =~ \"published_at\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        published="${BASH_REMATCH[1]}"
    fi
    [[ -n "$tag" ]] || return 1
    _STATUS_UPSTREAM_VERSION="$tag"
    _STATUS_UPSTREAM_PUBLISHED="$published"
    return 0
}

status_print_version() {
    local active_ver="" days_left age

    echo "Runner version:"
    if [[ -z "${TEMPLATE_ID:-}" ]] || ! gen_exists "$TEMPLATE_ID"; then
        echo "  active:    (no generation records)"
        echo "  upstream:  -"
        echo "  window:    -"
        return 0
    fi
    gen_read "$TEMPLATE_ID" || return 1
    active_ver="${GEN_RUNNER_VERSION:-unknown}"
    [[ -n "$active_ver" ]] || active_ver="unknown"
    echo "  active:    $active_ver"

    if ! _status_fetch_upstream; then
        echo "  upstream:  unknown"
        echo "  window:    unknown"
        STATUS_ATTENTION=1
        return 0
    fi
    echo "  upstream:  $_STATUS_UPSTREAM_VERSION"

    if [[ "$active_ver" == "$_STATUS_UPSTREAM_VERSION" ]]; then
        echo "  window:    n/a (on latest)"
        return 0
    fi

    STATUS_ATTENTION=1
    if [[ -n "${_STATUS_UPSTREAM_PUBLISHED:-}" ]] && \
        age=$(gen_age_days "$_STATUS_UPSTREAM_PUBLISHED"); then
        days_left=$(( STATUS_DRIFT_WINDOW_DAYS - age ))
        if (( days_left < 0 )); then
            echo "  window:    overdue by $(( -days_left ))d (30-day)  [drift]"
        else
            echo "  window:    ${days_left}d left (30-day)  [drift]"
        fi
    else
        echo "  window:    unknown  [drift]"
    fi
}

status_print_last_bake() {
    local list vmid best_vmid="" best_ts=""

    list=$(gen_list) || return 1
    if [[ -z "$list" ]]; then
        echo "Last bake: none"
        return 0
    fi
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        gen_read "$vmid" || return 1
        if [[ -n "${GEN_CREATED_AT:-}" ]]; then
            if [[ -z "$best_ts" || "$GEN_CREATED_AT" > "$best_ts" ]]; then
                best_ts="$GEN_CREATED_AT"
                best_vmid="$vmid"
            fi
        fi
    done <<< "$list"
    if [[ -z "$best_vmid" ]]; then
        echo "Last bake: unknown"
        return 0
    fi
    gen_read "$best_vmid" || return 1
    echo "Last bake: generation ${GEN_ID:-?} ${GEN_STATE:-unknown} at ${GEN_CREATED_AT:-unknown}"
    if [[ "${GEN_STATE:-}" == "failed" ]]; then
        [[ -z "${GEN_FAILED_REASON:-}" ]] || echo "  reason: $GEN_FAILED_REASON"
        STATUS_ATTENTION=1
    fi
}

status_print_pool_fill() {
    local org expected actual vmid line
    local -a orgs=()
    local -A actuals=() exclude=()

    echo "Pool fill:"
    mapfile -t orgs < <(list_orgs)
    if [[ ${#orgs[@]} -eq 0 ]]; then
        echo "  (no organizations)"
        return 0
    fi

    [[ -n "${TEMPLATE_ID:-}" ]] && exclude["$TEMPLATE_ID"]=1
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        exclude["$vmid"]=1
    done < <(gen_list)

    while read -r line; do
        [[ -z "$line" ]] && continue
        vmid=$(awk '{print $1}' <<< "$line")
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        [[ -n "${exclude[$vmid]:-}" ]] && continue
        org=$(get_vm_org "$vmid")
        [[ "$org" != "unknown" ]] || continue
        actuals["$org"]=$(( ${actuals[$org]:-0} + 1 ))
    done < <(qm list 2>/dev/null | tail -n +2 || true)

    printf "  %-20s %8s %8s\n" "ORG" "EXPECTED" "ACTUAL"
    for org in "${orgs[@]}"; do
        expected=$(grep '^RUNNER_COUNT=' "$ORG_CONFIG_DIR/${org}.conf" 2>/dev/null \
            | head -1 | sed 's/^RUNNER_COUNT=//' | tr -d '"' || true)
        [[ "$expected" =~ ^[0-9]+$ ]] || expected=0
        actual="${actuals[$org]:-0}"
        printf "  %-20s %8s %8s" "$org" "$expected" "$actual"
        if (( actual < expected )); then
            printf "  [under]"
            STATUS_ATTENTION=1
        fi
        printf "\n"
    done
}

status_print_drain() {
    if pool_is_draining; then
        echo "Drain: active"
        STATUS_ATTENTION=1
    else
        echo "Drain: inactive"
    fi
}

status_print_last_notify() {
    if [[ -n "${LAST_NOTIFY_FILE:-}" && -f "$LAST_NOTIFY_FILE" ]]; then
        echo "Last notification: $(< "$LAST_NOTIFY_FILE")"
    else
        echo "Last notification: none"
    fi
}

status_main() {
    STATUS_ATTENTION=0

    echo ""
    echo "=== Generations ==="
    generations_print_table || return 1
    echo ""
    status_print_version || return 1
    echo ""
    status_print_last_bake || return 1
    echo ""
    status_print_pool_fill || return 1
    echo ""
    status_print_drain
    status_print_last_notify
    echo ""
    if [[ "$STATUS_ATTENTION" -eq 0 ]]; then
        echo "Status: OK"
    else
        echo "Status: ATTENTION"
    fi
    echo ""
    return "$STATUS_ATTENTION"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root status
    if [[ -f "$CONFIG_FILE" ]]; then
        load_infra_config
    else
        apply_generation_defaults
    fi
    status_main "$@"
fi
