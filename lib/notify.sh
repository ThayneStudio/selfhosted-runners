#!/bin/bash
# Operator notifications over a webhook.
#
#   notify <severity> <event> <message> [detail]
#
#     severity  info | warn | error — anything below NOTIFY_MIN_SEVERITY drops
#     event     dotted name, e.g. clone.failed
#     message   one-line human summary
#     detail    optional longer context
#
# Config keys in /etc/github-runners.conf:
#
#     NOTIFY_WEBHOOK_URL   unset or empty disables notifications entirely
#     NOTIFY_MIN_SEVERITY  info|warn|error, default warn
#     NOTIFY_FORMAT        slack|text, default slack
#
# The payload is shaped for a Slack incoming webhook. Slack ignores keys it
# does not know, so the same body serves a generic consumer that wants the
# structured fields; NOTIFY_FORMAT=text sends the "text" field alone for
# ntfy-style consumers that want a plain body.
#
# Two invariants this file exists to hold:
#
#   1. A notification never fails its caller. This is called from VM lifecycle
#      paths, so a webhook that is down, slow, wrong, or absent has to be
#      indistinguishable from one that was never configured.
#   2. No secret reaches a payload or a log line. Notification details get
#      assembled next to PAT-using code, so everything leaving this file goes
#      through redact_secrets first.
#
# Sourced by common.sh. Deliberately does not set shell options: it inherits
# the caller's, and notify() is written to survive `set -e`.

# Strip anything credential-shaped out of text that is about to leave the host
# or land in a log. Two layers: the exact values of the secrets this platform
# holds, then the shapes a credential takes when it arrives embedded in
# somebody else's error message — a GitHub API body, a git remote, a curl error.
#
# Bare 40-hex strings are deliberately left alone. Legacy GitHub tokens had
# that shape, but so do git SHAs and sha1 checksums, which is most of what a
# bake or drift detail is made of. A legacy-shaped PAT this platform actually
# holds is still caught by the exact-value pass.
redact_secrets() {
    local text="${1-}" secret

    for secret in "${GITHUB_PAT:-}" "${CANARY_PAT:-}" "${NOTIFY_WEBHOOK_URL:-}"; do
        [[ -n "$secret" ]] || continue
        text="${text//"$secret"/[REDACTED]}"
    done

    [[ -n "$text" ]] || return 0

    printf '%s' "$text" | sed -E \
        -e 's/gh[pousr]_[A-Za-z0-9]{16,}/[REDACTED]/g' \
        -e 's/github_pat_[A-Za-z0-9_]{16,}/[REDACTED]/g' \
        -e 's#https?://hooks\.slack\.com/[^[:space:]"]*#[REDACTED]#g' \
        -e 's#(://)[^/[:space:]@]+:[^/[:space:]@]+@#\1[REDACTED]@#g' \
        -e 's/(^|[[:space:]])((token|Bearer)[[:space:]]+)[A-Za-z0-9._~+=-]{12,}/\1\2[REDACTED]/g'
}

# Severity as a comparable number. -1 means "not a severity we recognize".
_notify_rank() {
    local level
    level=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')
    case "$level" in
        info)  printf '0' ;;
        warn)  printf '1' ;;
        error) printf '2' ;;
        *)     printf -- '-1' ;;
    esac
}

# Notification problems go where the platform's other failures go, redacted.
# reclone.sh runs detached from the Proxmox task with its stderr discarded, so
# journald is the only place its notification failures can be read back.
_notify_log() {
    local msg
    msg=$(redact_secrets "${1-}")
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$msg"
    else
        printf '[WARN] %s\n' "$msg" >&2
    fi
    if command -v logger >/dev/null 2>&1; then
        logger -t github-runner "$msg" || true
    fi
    return 0
}

# watch.sh and reclone.sh reach notify through load_infra_config, which has
# already sourced the config. Anything that has not — a hookscript, a future
# timer unit — still gets working notifications: read the NOTIFY_* keys back
# out of a subshell so the rest of the config file stays out of the caller's
# scope. Assigning NOTIFY_WEBHOOK_URL (even to empty) is what caches this.
_notify_load_config() {
    [[ -z "${NOTIFY_WEBHOOK_URL+set}" ]] || return 0

    local conf="${CONFIG_FILE:-/etc/github-runners.conf}"
    if [[ ! -r "$conf" ]]; then
        NOTIFY_WEBHOOK_URL=""
        return 0
    fi

    local loaded url min fmt
    loaded=$(
        # shellcheck source=/dev/null
        source "$conf" >/dev/null 2>&1 || true
        printf '%s\n%s\n%s\n' \
            "${NOTIFY_WEBHOOK_URL:-}" "${NOTIFY_MIN_SEVERITY:-}" "${NOTIFY_FORMAT:-}"
    ) || loaded=$'\n\n'

    { read -r url; read -r min; read -r fmt; } <<< "$loaded"
    NOTIFY_WEBHOOK_URL="$url"
    [[ -n "${NOTIFY_MIN_SEVERITY+set}" ]] || NOTIFY_MIN_SEVERITY="$min"
    [[ -n "${NOTIFY_FORMAT+set}" ]] || NOTIFY_FORMAT="$fmt"
    return 0
}

# Render the request body. Fails only if jq cannot build the JSON, which is
# treated as "do not send" rather than "send something unescaped".
_notify_body() {
    local severity="$1" event="$2" host="$3" text="$4" detail="$5"

    case "${NOTIFY_FORMAT:-slack}" in
        text)
            printf '%s' "$text"
            return 0
            ;;
        slack) ;;
        *)
            _notify_log "notify: unknown NOTIFY_FORMAT '${NOTIFY_FORMAT}', sending slack format"
            ;;
    esac

    # generation is part of the documented payload shape, so the key is always
    # present; it stays null until a caller exports NOTIFY_GENERATION.
    local generation="null"
    [[ "${NOTIFY_GENERATION:-}" =~ ^[0-9]+$ ]] && generation="$NOTIFY_GENERATION"

    jq -cn \
        --arg text "$text" \
        --arg severity "$severity" \
        --arg event "$event" \
        --arg host "$host" \
        --argjson generation "$generation" \
        --arg detail "$detail" \
        '{text: $text, severity: $severity, event: $event, host: $host,
          generation: $generation, detail: $detail}'
}

# curl config syntax quotes the value; backslash and double quote are the only
# characters inside it that need escaping.
_notify_curl_config() {
    local url="${NOTIFY_WEBHOOK_URL:-}"
    url="${url//\\/\\\\}"
    url="${url//\"/\\\"}"
    printf 'url = "%s"\n' "$url"
}

# The webhook URL is itself a secret, so it reaches curl through a config file
# on a process-substitution fd rather than argv — the same discipline
# deregister_runner uses for a PAT. The body goes in on stdin for the same
# reason.
#
# Worst case is one attempt plus two retries at 10s each plus 3s of backoff, so
# a black-holed webhook can hold the caller for ~33s and no longer.
_notify_post() {
    local body="$1" content_type="application/json"
    [[ "${NOTIFY_FORMAT:-slack}" != "text" ]] || content_type="text/plain"

    local attempt delay=1
    for attempt in 1 2 3; do
        if printf '%s' "$body" | curl -sS -f -X POST \
            --max-time 10 \
            -H "Content-Type: $content_type" \
            --config <(_notify_curl_config) \
            --data-binary @- >/dev/null 2>&1
        then
            return 0
        fi
        [[ "$attempt" -lt 3 ]] || break
        sleep "$delay" || true
        delay=$((delay * 2))
    done
    return 1
}

_notify_dispatch() {
    local severity="${1-}" event="${2-}" message="${3-}" detail="${4-}"

    _notify_load_config

    # The unconfigured host is the normal case: no work, no log line, no delay.
    [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]] || return 0

    if [[ -z "$event" || -z "$message" ]]; then
        _notify_log "notify: dropping a notification with no event name or message"
        return 0
    fi

    local rank min_rank
    rank=$(_notify_rank "$severity")
    if [[ "$rank" -lt 0 ]]; then
        # A typo in a severity must not be able to silence an alert, so an
        # unrecognized one is treated as the loudest.
        _notify_log "notify: unknown severity '$severity' for '$event', treating as error"
        severity="error"
        rank=2
    fi
    min_rank=$(_notify_rank "${NOTIFY_MIN_SEVERITY:-warn}")
    [[ "$min_rank" -ge 0 ]] || min_rank=1
    [[ "$rank" -ge "$min_rank" ]] || return 0

    local host body
    host=$(hostname -s 2>/dev/null) || host=""
    [[ -n "$host" ]] || host="${HOSTNAME:-unknown}"

    event=$(redact_secrets "$event")
    message=$(redact_secrets "$message")
    detail=$(redact_secrets "$detail")

    body=$(_notify_body "$severity" "$event" "$host" "[$host] $message" "$detail") || {
        _notify_log "notify: could not build a payload for '$event'"
        return 0
    }

    _notify_post "$body" || _notify_log "notify: webhook delivery failed for '$event'"
    return 0
}

# The only entry point. Calling the real work in a tested context disarms the
# caller's `set -e` for everything underneath it, so nothing in this file —
# a missing jq, an unreachable webhook, a malformed config — can abort a
# runner lifecycle operation.
notify() {
    _notify_dispatch "$@" || true
    return 0
}
