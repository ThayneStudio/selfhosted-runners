#!/bin/bash
# Detect whether a rebake is needed: digest compare, weekly floor, memo
# override, and detect-fail tracking (spec 11.2, 11.3).
#
# Library: functions only at source time. Tests load_lib detect.sh.
# bake.sh sources this after defining compute_template_digest. When tests
# load detect.sh first, we pull bake.sh in for those digest helpers.
#
# GEN_* fields are loaded via gen_read in this shell; SC2030/SC2031/SC2034
# are the same false positives as in bake.sh / generations.sh.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

if [[ -n "${RUNNER_DETECT_LOADED:-}" ]]; then
    return 0
fi
RUNNER_DETECT_LOADED=1

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=generations.sh
source "$LIB_DIR/generations.sh"
if ! declare -F compute_template_digest >/dev/null 2>&1; then
    # bake.sh sources this file. The next directive stops the linter
    # following this reverse edge (cycle).
    # shellcheck source=/dev/null
    source "$LIB_DIR/bake.sh"
fi

# ASSUMPTION: python3 is present on pve, Ubuntu CI, and macOS test hosts.
# BSD date has no -d; GNU date -d is not portable. Proven by
# "detect_age_days is 10 for a stamp 10 days before gen_now".
iso_to_epoch() {
    local ts="${1:-}"
    [[ -n "$ts" ]] || return 1
    python3 -c 'import sys,datetime; s=sys.argv[1]; print(int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$ts"
}

# Integer days since <iso8601> UTC, using gen_now as "now".
detect_age_days() {
    local ts="${1:-}" now epoch_then epoch_now
    [[ -n "$ts" ]] || return 1
    now=$(gen_now)
    epoch_now=$(iso_to_epoch "$now") || return 1
    epoch_then=$(iso_to_epoch "$ts") || return 1
    printf '%s\n' $(( (epoch_now - epoch_then) / 86400 ))
}

# True when the in-scope GEN_CREATED_AT is at or past REBAKE_MAX_AGE_DAYS.
detect_past_floor() {
    local age max
    max="${REBAKE_MAX_AGE_DAYS:-7}"
    [[ "$max" =~ ^[0-9]+$ ]] || return 1
    [[ -n "${GEN_CREATED_AT:-}" ]] || return 1
    age=$(detect_age_days "$GEN_CREATED_AT") || return 1
    (( age >= max ))
}

# Record a consecutive detect-fail. first_fail is sticky; notify warn once
# after DETECT_FAIL_WARN_HOURS and set warned= so maintain does not spam.
# Proven by "first GitHub API failure logs and does not notify; floor still
# applies" and "consecutive detect failure past DETECT_FAIL_WARN_HOURS
# notifies warn once".
detect_note_failure() {
    local now first warned epoch_now epoch_first age_h warn_after line

    now=$(gen_now)
    first=""
    warned=""
    if [[ -f "$DETECT_FAIL_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                first_fail=*) first="${line#first_fail=}" ;;
                warned=*) warned="${line#warned=}" ;;
            esac
        done < "$DETECT_FAIL_FILE"
    fi
    [[ -n "$first" ]] || first="$now"

    warn_after="${DETECT_FAIL_WARN_HOURS:-24}"
    if epoch_now=$(iso_to_epoch "$now") && epoch_first=$(iso_to_epoch "$first"); then
        age_h=$(( (epoch_now - epoch_first) / 3600 ))
        if [[ "$warn_after" =~ ^[0-9]+$ ]] && (( age_h >= warn_after )) && [[ -z "$warned" ]]; then
            notify warn detect.failed \
                "Template digest detection has failed for ${age_h}h" \
                "API or SHA256SUMS fetch failed; weekly floor still applies"
            warned="$now"
        fi
    fi

    # Best-effort: a tracking-file write must not skip the weekly floor.
    ensure_state_dir "$(dirname "$DETECT_FAIL_FILE")" || return 0
    {
        printf 'first_fail=%s\n' "$first"
        [[ -n "$warned" ]] && printf 'warned=%s\n' "$warned"
    } > "$DETECT_FAIL_FILE" || return 0
    chmod 600 "$DETECT_FAIL_FILE" 2>/dev/null || true
    return 0
}

# stdout: `yes <reason>` or `no <reason>`. Exit 0 for a completed decision.
# Reasons: digest-changed, unknown-digest, weekly-floor, up-to-date,
# memoed-digest, rebake-disabled.
detect_should_bake() {
    local digest=""

    apply_generation_defaults

    if [[ "${REBAKE_ENABLED:-true}" == "false" ]]; then
        printf 'no rebake-disabled\n'
        return 0
    fi

    if digest=$(compute_template_digest) && [[ -n "$digest" ]]; then
        rm -f "$DETECT_FAIL_FILE"

        # Memo overrides floor. Proven by "memoed digest does not trigger
        # even past the floor".
        if digest_is_memoed "$digest"; then
            printf 'no memoed-digest\n'
            return 0
        fi

        # Compare against the clone pointer, not gen_list active (lowest VMID).
        # A promote-before-demote crash leaves two actives; TEMPLATE_ID is the
        # generation the fleet clones. No record → unknown-digest.
        if [[ -z "${TEMPLATE_ID:-}" ]] || ! gen_exists "$TEMPLATE_ID"; then
            printf 'yes unknown-digest\n'
            return 0
        fi
        gen_read "$TEMPLATE_ID" || return 1

        if [[ -z "${GEN_TEMPLATE_DIGEST:-}" || "$GEN_TEMPLATE_DIGEST" == "unknown" ]]; then
            printf 'yes unknown-digest\n'
            return 0
        fi

        if [[ "$GEN_TEMPLATE_DIGEST" != "$digest" ]]; then
            printf 'yes digest-changed\n'
            return 0
        fi

        if detect_past_floor; then
            printf 'yes weekly-floor\n'
            return 0
        fi

        printf 'no up-to-date\n'
        return 0
    fi

    # Never claim digest-changed when compute_template_digest fails.
    # Proven by "first GitHub API failure logs and does not notify; floor
    # still applies" and "API failure on a fresh generation is not
    # digest-changed".
    log_warn "Failed to compute template digest; not treating as digest-changed"
    detect_note_failure

    if [[ -n "${TEMPLATE_ID:-}" ]] && gen_exists "$TEMPLATE_ID"; then
        gen_read "$TEMPLATE_ID" || return 1
        if detect_past_floor; then
            printf 'yes weekly-floor\n'
            return 0
        fi
    fi
    printf 'no up-to-date\n'
    return 0
}
