#!/bin/bash
# Drift alarm: fleet runner version vs the 30-day actions/runner window (spec 11.4).
#
# Library: functions only at source time. Tests load_lib drift.sh and call
# drift_main. When executed as the CLI (`BASH_SOURCE == $0`), require_root,
# load_infra_config, then drift_main. Do not require_root at source time.
#
# Independent of the bake pipeline: does not start a bake. GitHub API failure
# is logged and notified at warn only after DETECT_FAIL_WARN_HOURS of
# consecutive failures. Never reports clean when the check could not complete.
#
# GEN_* fields are loaded via gen_read in this shell; SC2030/SC2031/SC2034
# are the same false positives as in generations.sh.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_DRIFT_LOADED:-}" ]]; then
    return 0
fi
RUNNER_DRIFT_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=generations.sh
source "$LIB_DIR/generations.sh"

# GitHub stops assigning jobs to runners more than 30 days behind latest.
DRIFT_WINDOW_DAYS=30
DRIFT_WARN_REMAINING_DAYS=10
DRIFT_ERROR_REMAINING_DAYS=3

# Same UTC ISO parser as detect.sh. Kept here so drift does not source the
# bake pipeline. ASSUMPTION: python3 is present on pve and test hosts.
drift_iso_to_epoch() {
    local ts="${1:-}"
    [[ -n "$ts" ]] || return 1
    python3 -c 'import sys,datetime; s=sys.argv[1]; print(int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$ts"
}

drift_age_days() {
    local ts="${1:-}" now epoch_then epoch_now
    [[ -n "$ts" ]] || return 1
    now=$(gen_now)
    epoch_now=$(drift_iso_to_epoch "$now") || return 1
    epoch_then=$(drift_iso_to_epoch "$ts") || return 1
    printf '%s\n' $(( (epoch_now - epoch_then) / 86400 ))
}

drift_remaining_days() {
    local published="${1:-}" age
    age=$(drift_age_days "$published") || return 1
    printf '%s\n' $(( DRIFT_WINDOW_DAYS - age ))
}

drift_normalize_version() {
    local v="${1:-}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v#v}"
    v="${v#V}"
    printf '%s' "$v"
}

drift_version_is_valid() {
    [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)+$ ]]
}

# stdout: <version><TAB><published_at>. Fail closed on a missing field.
drift_fetch_latest() {
    local json tag published
    json=$(curl -sf --retry 3 --max-time 20 \
        https://api.github.com/repos/actions/runner/releases/latest) || return 1
    [[ -n "$json" ]] || return 1
    tag=$(printf '%s' "$json" | jq -r '.tag_name // empty') || return 1
    published=$(printf '%s' "$json" | jq -r '.published_at // empty') || return 1
    tag=$(drift_normalize_version "$tag")
    published="${published//[[:space:]]/}"
    drift_version_is_valid "$tag" || return 1
    [[ -n "$published" && "$published" != "null" ]] || return 1
    drift_iso_to_epoch "$published" >/dev/null 2>&1 || return 1
    printf '%s\t%s\n' "$tag" "$published"
}

# Record a consecutive API-fail. first_fail is sticky; notify warn once after
# DETECT_FAIL_WARN_HOURS and set warned= so the timer does not spam.
drift_note_failure() {
    local now first warned epoch_now epoch_first epoch_warn age_h warn_after line

    now=$(gen_now)
    first=""
    warned=""
    if [[ -f "$DRIFT_FAIL_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                first_fail=*) first="${line#first_fail=}" ;;
                warned=*) warned="${line#warned=}" ;;
            esac
        done < "$DRIFT_FAIL_FILE"
    fi
    warn_after="${DETECT_FAIL_WARN_HOURS:-24}"
    if ! epoch_now=$(drift_iso_to_epoch "$now"); then
        first="$now"
        warned=""
    elif ! epoch_first=$(drift_iso_to_epoch "$first") || (( epoch_first > epoch_now )); then
        # A corrupt or future timestamp must not suppress the prolonged-failure
        # warning forever. Restart the consecutive-failure window from now.
        first="$now"
        warned=""
        epoch_first="$epoch_now"
    else
        # Treat a corrupt, pre-window, or future warned marker as unwarned.
        # Otherwise arbitrary file contents could suppress every later alert.
        if [[ -n "$warned" ]] &&
            { ! epoch_warn=$(drift_iso_to_epoch "$warned") ||
              (( epoch_warn < epoch_first || epoch_warn > epoch_now )); }; then
            warned=""
        fi
        age_h=$(( (epoch_now - epoch_first) / 3600 ))
        if [[ "$warn_after" =~ ^[0-9]+$ ]] && (( age_h >= warn_after )) && [[ -z "$warned" ]]; then
            drift_notify warn drift.warning \
                "Could not fetch actions/runner latest release for ${age_h}h" \
                "consecutive API failures; drift is not reporting clean"
            warned="$now"
        fi
    fi

    ensure_state_dir "$(dirname "$DRIFT_FAIL_FILE")" || return 0
    if ! {
        printf 'first_fail=%s\n' "$first"
        [[ -n "$warned" ]] && printf 'warned=%s\n' "$warned"
    } | gen_write_file_atomic "$DRIFT_FAIL_FILE"; then
        log_warn "Failed to update drift failure state"
    fi
    return 0
}

drift_clear_failure() {
    rm -f "$DRIFT_FAIL_FILE"
}

# notify never fails the caller — even if the stubbed notify returns 1.
drift_notify() {
    local severity="$1" event="$2" message="$3" detail="${4:-}"
    if [[ "${DRIFT_FLEET_GENERATION:-}" =~ ^[0-9]+$ ]]; then
        NOTIFY_GENERATION="$DRIFT_FLEET_GENERATION" notify "$severity" "$event" "$message" "$detail" || true
    else
        notify "$severity" "$event" "$message" "$detail" || true
    fi
    return 0
}

# First running managed clone that yields a version. Never TEMPLATE_ID.
# Always prints a token (never fails the caller).
drift_probe_fleet_version() {
    local all_vms vmid vm_name status org probed

    all_vms=$(qm list 2>/dev/null </dev/null) || {
        printf 'unknown\n'
        return 0
    }
    while read -r vmid vm_name status _; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        [[ "$vmid" != "${TEMPLATE_ID:-}" ]] || continue
        [[ "$status" == "running" ]] || continue
        org=$(get_vm_org "$vmid")
        [[ "$org" != "unknown" ]] || continue
        probed=$(adopt_probe_runner_version "$vmid")
        probed=$(drift_normalize_version "$probed")
        if [[ -n "$probed" && "$probed" != "unknown" ]]; then
            printf '%s\n' "$probed"
            return 0
        fi
    done <<< "$(tail -n +2 <<< "$all_vms")"
    printf 'unknown\n'
}

# Prefer GEN_RUNNER_VERSION on the TEMPLATE_ID record (the generation the
# fleet clones). Fall back to a running clone so this works before adoption.
# Results are globals because command substitution would resolve the version in
# a subshell and discard the generation metadata needed by notifications.
drift_fleet_version() {
    local ver="" generation=""

    DRIFT_FLEET_VERSION=unknown
    DRIFT_FLEET_GENERATION=""

    if [[ -n "${TEMPLATE_ID:-}" ]] && gen_exists "$TEMPLATE_ID" && gen_read "$TEMPLATE_ID"; then
        ver=$(drift_normalize_version "${GEN_RUNNER_VERSION:-}")
        if drift_version_is_valid "$ver"; then
            generation="${GEN_ID:-}"
            DRIFT_FLEET_VERSION="$ver"
            [[ "$generation" =~ ^[0-9]+$ ]] && DRIFT_FLEET_GENERATION="$generation"
            return 0
        fi
    fi
    ver=$(drift_probe_fleet_version)
    ver=$(drift_normalize_version "$ver")
    if drift_version_is_valid "$ver"; then
        DRIFT_FLEET_VERSION="$ver"
    fi
    return 0
}

drift_print() {
    local status="$1"
    printf 'status=%s\n' "$status"
    shift
    local key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        [[ -n "$value" ]] || continue
        printf '%s=%s\n' "$key" "$value"
    done
}

drift_window_message() {
    local fleet="$1" upstream="$2" remaining="$3"
    if (( remaining < 0 )); then
        printf 'Runner %s is %s days past the 30-day window (upstream %s)' \
            "$fleet" "$(( -remaining ))" "$upstream"
    elif (( remaining == 0 )); then
        printf 'Runner %s is at the 30-day window (upstream %s)' \
            "$fleet" "$upstream"
    else
        printf 'Runner %s has %s days left in the 30-day window (upstream %s)' \
            "$fleet" "$remaining" "$upstream"
    fi
}

# Reports only. Exit 0 after a completed check, including unknown/warn/error.
drift_main() {
    local fleet="unknown" latest="" upstream="" published="" remaining=""
    local status="" reason="" message="" detail=""

    apply_generation_defaults

    drift_fleet_version
    fleet="$DRIFT_FLEET_VERSION"
    [[ -n "$fleet" ]] || fleet="unknown"

    if ! latest=$(drift_fetch_latest); then
        log_warn "Failed to fetch latest actions/runner release; not treating fleet as clean"
        drift_note_failure
        drift_print unknown "reason=api-failed" "fleet=$fleet"
        return 0
    fi
    drift_clear_failure

    upstream="${latest%%$'\t'*}"
    published="${latest#*$'\t'}"
    upstream=$(drift_normalize_version "$upstream")

    if [[ -z "$fleet" || "$fleet" == "unknown" ]]; then
        log_warn "Could not determine fleet runner version; not treating as clean"
        drift_print unknown "reason=fleet-version" "upstream=$upstream" \
            "published_at=$published"
        return 0
    fi

    if [[ "$fleet" == "$upstream" ]]; then
        remaining=$(drift_remaining_days "$published") || remaining=""
        log_info "Runner version $fleet matches upstream $upstream"
        drift_print clean "fleet=$fleet" "upstream=$upstream" \
            "published_at=$published" "days_remaining=$remaining"
        return 0
    fi

    if ! remaining=$(drift_remaining_days "$published"); then
        log_warn "Could not compute 30-day window from published_at; not treating as clean"
        drift_print unknown "reason=published_at" "fleet=$fleet" \
            "upstream=$upstream" "published_at=$published"
        return 0
    fi

    detail="fleet=${fleet} upstream=${upstream} published_at=${published} days_remaining=${remaining}"
    message=$(drift_window_message "$fleet" "$upstream" "$remaining")

    if (( remaining <= DRIFT_ERROR_REMAINING_DAYS )); then
        status=error
        log_error "$message"
        drift_notify error drift.critical "$message" "$detail"
    elif (( remaining <= DRIFT_WARN_REMAINING_DAYS )); then
        status=warn
        log_warn "$message"
        drift_notify warn drift.warning "$message" "$detail"
    else
        status=behind
        log_info "$message"
    fi

    drift_print "$status" "fleet=$fleet" "upstream=$upstream" \
        "published_at=$published" "days_remaining=$remaining"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root drift
    [[ -f "$CONFIG_FILE" ]] || exit 0
    load_infra_config
    drift_main "$@"
fi
