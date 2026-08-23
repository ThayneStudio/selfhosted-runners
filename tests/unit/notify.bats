#!/usr/bin/env bats
# Unit tests for lib/notify.sh.
#
# curl, sleep and logger are stubbed on PATH. The curl stub records its argv,
# the body it was handed on stdin, and the contents of the --config file it was
# pointed at, which is what lets these tests assert both what was sent and what
# never appeared in argv.

setup() {
    NOTIFY_TEST_DIR="$(mktemp -d)"
    NOTIFY_LIB="$BATS_TEST_DIRNAME/../../lib/notify.sh"
    export NOTIFY_TEST_DIR NOTIFY_LIB
    export CURL_ARGV="$NOTIFY_TEST_DIR/argv"
    export CURL_BODY="$NOTIFY_TEST_DIR/body"
    export CURL_CONFIG="$NOTIFY_TEST_DIR/config"
    export CURL_CALLS="$NOTIFY_TEST_DIR/calls"
    export LOGGER_LINES="$NOTIFY_TEST_DIR/logger"
    export CURL_EXIT=0

    mkdir -p "$NOTIFY_TEST_DIR/bin"

    cat > "$NOTIFY_TEST_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_ARGV"
config_path="" prev=""
for arg in "$@"; do
    [[ "$prev" == "--config" ]] && config_path="$arg"
    prev="$arg"
done
[[ -n "$config_path" ]] && cat "$config_path" >> "$CURL_CONFIG"
cat >> "$CURL_BODY"
echo call >> "$CURL_CALLS"
exit "${CURL_EXIT:-0}"
STUB

    # Retry backoff would otherwise add three real seconds to every
    # delivery-failure test.
    cat > "$NOTIFY_TEST_DIR/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

    cat > "$NOTIFY_TEST_DIR/bin/logger" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOGGER_LINES"
STUB

    chmod +x "$NOTIFY_TEST_DIR/bin/curl" "$NOTIFY_TEST_DIR/bin/sleep" \
        "$NOTIFY_TEST_DIR/bin/logger"
    PATH="$NOTIFY_TEST_DIR/bin:$PATH"

    # Point the lazy config loader at a file that does not exist so the tests
    # never read the host's real /etc/github-runners.conf.
    CONFIG_FILE="$NOTIFY_TEST_DIR/absent.conf"

    # shellcheck source=../../lib/notify.sh
    source "$NOTIFY_LIB"
}

teardown() {
    rm -rf "$NOTIFY_TEST_DIR"
}

# --- redaction ---------------------------------------------------------------

@test "redact_secrets masks a classic PAT shape it has never seen" {
    run redact_secrets "gh api said: Bad credentials for ghp_AbCdEf0123456789AbCdEf0123456789AbCd"
    [ "$status" -eq 0 ]
    [[ "$output" != *"ghp_"* ]]
    [[ "$output" == *"[REDACTED]"* ]]
    [[ "$output" == *"Bad credentials"* ]]
}

@test "redact_secrets masks a fine-grained PAT shape" {
    run redact_secrets "token github_pat_11AAAAAAA0aAaAaAaAaAaA_bBbBbBbBbBbBbBbBbBbBbBbBbBbB expired"
    [ "$status" -eq 0 ]
    [[ "$output" != *"github_pat_"* ]]
    [[ "$output" == *"expired"* ]]
}

@test "redact_secrets masks the configured PATs verbatim, whatever shape they are" {
    GITHUB_PAT="not-token-shaped-at-all"
    CANARY_PAT="canary-secret-value"
    run redact_secrets "org acme rejected not-token-shaped-at-all and canary-secret-value"
    [ "$status" -eq 0 ]
    [[ "$output" != *"not-token-shaped-at-all"* ]]
    [[ "$output" != *"canary-secret-value"* ]]
    [[ "$output" == *"org acme rejected"* ]]
}

@test "redact_secrets masks the webhook URL" {
    NOTIFY_WEBHOOK_URL="https://hooks.slack.com/services/T00/B00/xxxxSECRETxxxx"
    run redact_secrets "POST $NOTIFY_WEBHOOK_URL returned 500"
    [ "$status" -eq 0 ]
    [[ "$output" != *"SECRET"* ]]
    [[ "$output" != *"hooks.slack.com"* ]]
    [[ "$output" == *"returned 500"* ]]
}

@test "redact_secrets masks credentials embedded in a URL" {
    run redact_secrets "fatal: https://x-access-token:ghp_AbCdEf0123456789AbCdEf0123456789AbCd@github.com/acme/x"
    [ "$status" -eq 0 ]
    [[ "$output" != *"ghp_"* ]]
    [[ "$output" == *"github.com/acme/x"* ]]
}

@test "redact_secrets leaves checksums and SHAs intact" {
    local sha1="da39a3ee5e6b4b0d3255bfef95601890afd80709"
    local sha256="5fa5b05e2d4b1c6d8c2f9a1e0b7d3c4a5e6f708192a3b4c5d6e7f8091a2b3c4d"
    run redact_secrets "expected $sha256 got $sha1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$sha256"* ]]
    [[ "$output" == *"$sha1"* ]]
}

# --- gating ------------------------------------------------------------------

@test "notify is a silent no-op when no webhook is configured" {
    NOTIFY_WEBHOOK_URL=""
    run notify error clone.failed "re-clone failed" "org=acme"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -f "$CURL_CALLS" ]
}

@test "notify is a silent no-op when the config file does not exist" {
    unset NOTIFY_WEBHOOK_URL
    run notify error clone.failed "re-clone failed" "org=acme"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -f "$CURL_CALLS" ]
}

@test "a warn is delivered under the default minimum severity" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    run notify warn clone.failed "watcher could not fill 2 runner slot(s)" "slots: runner-1 runner-2"
    [ "$status" -eq 0 ]
    [ -f "$CURL_BODY" ]
    [ "$(jq -r '.severity' "$CURL_BODY")" = "warn" ]
    [ "$(jq -r '.event' "$CURL_BODY")" = "clone.failed" ]
    [ "$(jq -r '.detail' "$CURL_BODY")" = "slots: runner-1 runner-2" ]
    [ "$(jq -r '.generation' "$CURL_BODY")" = "null" ]
    [[ "$(jq -r '.text' "$CURL_BODY")" == *"watcher could not fill 2 runner slot(s)"* ]]
    [[ "$(jq -r '.text' "$CURL_BODY")" == "[$(jq -r '.host' "$CURL_BODY")]"* ]]
    grep -qx -- "--max-time" "$CURL_ARGV"
    grep -qx -- "10" "$CURL_ARGV"
}

@test "NOTIFY_MIN_SEVERITY=error suppresses a warn" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_MIN_SEVERITY="error"
    run notify warn clone.failed "watcher could not fill a slot" ""
    [ "$status" -eq 0 ]
    [ ! -f "$CURL_CALLS" ]
}

@test "NOTIFY_MIN_SEVERITY=error still delivers an error" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_MIN_SEVERITY="error"
    run notify error clone.failed "re-clone failed" ""
    [ "$status" -eq 0 ]
    [ "$(jq -r '.severity' "$CURL_BODY")" = "error" ]
}

@test "NOTIFY_MIN_SEVERITY=info delivers an info" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_MIN_SEVERITY="info"
    run notify info generation.promoted "generation 8 promoted" ""
    [ "$status" -eq 0 ]
    [ "$(jq -r '.severity' "$CURL_BODY")" = "info" ]
}

@test "an unrecognized severity is delivered rather than dropped" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_MIN_SEVERITY="error"
    run notify wanr clone.failed "typo in the severity" ""
    [ "$status" -eq 0 ]
    [ "$(jq -r '.severity' "$CURL_BODY")" = "error" ]
}

@test "NOTIFY_GENERATION rides along as a number" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_GENERATION=8
    run notify error bake.failed "bake failed for generation 8" "checksum mismatch"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.generation' "$CURL_BODY")" = "8" ]
}

@test "text format sends the text field alone" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_FORMAT="text"
    run notify error clone.failed "re-clone failed" "org=acme"
    [ "$status" -eq 0 ]
    [[ "$(cat "$CURL_BODY")" == *"] re-clone failed" ]]
    run jq . "$CURL_BODY"
    [ "$status" -ne 0 ]
}

# --- secrets never leave ------------------------------------------------------

@test "a PAT in the detail string never reaches the payload" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    GITHUB_PAT="ghp_AbCdEf0123456789AbCdEf0123456789AbCd"
    run notify error clone.failed "registration rejected" \
        "curl said: Bad credentials for $GITHUB_PAT (org=acme)"
    [ "$status" -eq 0 ]
    run cat "$CURL_BODY"
    [[ "$output" != *"ghp_"* ]]
    [[ "$output" != *"AbCdEf"* ]]
    [[ "$output" == *"Bad credentials"* ]]
}

@test "the webhook URL reaches curl through a config file, never argv or the payload" {
    NOTIFY_WEBHOOK_URL="https://hooks.slack.com/services/T00/B00/xxxxSECRETxxxx"
    run notify error clone.failed "re-clone failed" "posting to $NOTIFY_WEBHOOK_URL"
    [ "$status" -eq 0 ]
    run cat "$CURL_ARGV"
    [[ "$output" != *"SECRET"* ]]
    [[ "$output" != *"hooks.slack.com"* ]]
    run cat "$CURL_BODY"
    [[ "$output" != *"SECRET"* ]]
    [[ "$output" != *"hooks.slack.com"* ]]
    grep -q 'xxxxSECRETxxxx' "$CURL_CONFIG"
}

@test "a delivery failure is logged without leaking the webhook URL" {
    NOTIFY_WEBHOOK_URL="https://hooks.slack.com/services/T00/B00/xxxxSECRETxxxx"
    CURL_EXIT=7
    run notify error clone.failed "re-clone failed" "org=acme"
    [ "$status" -eq 0 ]
    [[ "$output" == *"delivery failed"* ]]
    [[ "$output" != *"SECRET"* ]]
    [ -f "$LOGGER_LINES" ]
    run cat "$LOGGER_LINES"
    [[ "$output" != *"SECRET"* ]]
    [[ "$output" != *"hooks.slack.com"* ]]
}

# --- a failed notification never fails the caller -----------------------------

@test "an unreachable webhook is retried at most twice and then gives up" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    CURL_EXIT=7
    run notify error clone.failed "re-clone failed" "org=acme"
    [ "$status" -eq 0 ]
    [ "$(grep -c call "$CURL_CALLS")" -eq 3 ]
}

@test "an unreachable webhook does not fail a caller running under set -e" {
    cat > "$NOTIFY_TEST_DIR/caller.sh" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$NOTIFY_LIB"
notify error clone.failed "re-clone failed" "org=acme"
echo "caller survived"
CALLER
    chmod +x "$NOTIFY_TEST_DIR/caller.sh"

    export NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    export CURL_EXIT=7
    run "$NOTIFY_TEST_DIR/caller.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"caller survived"* ]]
}

@test "a missing jq does not fail a caller running under set -e" {
    cat > "$NOTIFY_TEST_DIR/caller.sh" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$NOTIFY_LIB"
notify error clone.failed "re-clone failed" "org=acme"
echo "caller survived"
CALLER
    chmod +x "$NOTIFY_TEST_DIR/caller.sh"
    printf '#!/usr/bin/env bash\nexit 127\n' > "$NOTIFY_TEST_DIR/bin/jq"
    chmod +x "$NOTIFY_TEST_DIR/bin/jq"

    export NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    run "$NOTIFY_TEST_DIR/caller.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"caller survived"* ]]
    [ ! -f "$CURL_CALLS" ]
}
