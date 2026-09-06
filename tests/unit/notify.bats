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

    # Point the lazy config loader and the org-PAT reader at paths that do not
    # exist, so running this suite on a real Proxmox host never reads the
    # host's own /etc/github-runners.conf or /etc/github-runners.d/*.conf.
    CONFIG_FILE="$NOTIFY_TEST_DIR/absent.conf"
    ORG_CONFIG_DIR="$NOTIFY_TEST_DIR/absent.d"

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

# --- last-notify recording (issue #16, `runner status`) --------------------

@test "notify records the redacted last severity/event/message for status to read" {
    RUNNER_STATE_DIR="$NOTIFY_TEST_DIR/state"
    LAST_NOTIFY_FILE="$RUNNER_STATE_DIR/last-notify"
    GITHUB_PAT="ghp_AbCdEf0123456789AbCdEf0123456789AbCd"
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"

    run notify warn drift.warning "PAT $GITHUB_PAT is expiring" "fleet=2.334.0"
    [ "$status" -eq 0 ]

    [ -f "$LAST_NOTIFY_FILE" ]
    run cat "$LAST_NOTIFY_FILE"
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ warn\ drift\.warning\ PAT\ \[REDACTED\]\ is\ expiring$ ]]
}

@test "notify never records anything when LAST_NOTIFY_FILE is unset" {
    unset LAST_NOTIFY_FILE
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"

    run notify warn drift.warning "behind upstream" "fleet=2.334.0"
    [ "$status" -eq 0 ]
    [ -f "$CURL_BODY" ]
}

@test "a failure to record the last notification does not fail notify" {
    RUNNER_STATE_DIR="$NOTIFY_TEST_DIR/state"
    # A regular file sits where the directory needs to be, so mkdir -p fails.
    : > "$NOTIFY_TEST_DIR/blocked"
    LAST_NOTIFY_FILE="$NOTIFY_TEST_DIR/blocked/last-notify"
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"

    run notify warn clone.failed "watcher could not fill 1 runner slot" ""
    [ "$status" -eq 0 ]
    [ -f "$CURL_BODY" ]
    [ ! -e "$NOTIFY_TEST_DIR/blocked/last-notify" ]
}

@test "notify with no arguments at all does nothing and returns 0" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    run notify
    [ "$status" -eq 0 ]
    [ ! -f "$CURL_CALLS" ]
    [[ "$output" == *"no event name or message"* ]]
}

@test "a caller under set -u survives notify with missing arguments" {
    cat > "$NOTIFY_TEST_DIR/caller.sh" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$NOTIFY_LIB"
notify
notify error clone.failed "no detail argument"
echo "caller survived"
CALLER
    chmod +x "$NOTIFY_TEST_DIR/caller.sh"

    export NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
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

# --- credential shapes that arrive inside somebody else's error text ----------

@test "redact_secrets masks a base64 Basic credential" {
    run redact_secrets "> Authorization: Basic eC1hY2Nlc3MtdG9rZW46Z2hwX0FiQ2RFZjAxMjM0NTY3ODk="
    [ "$status" -eq 0 ]
    [[ "$output" != *"eC1hY2Nlc3Mt"* ]]
    [[ "$output" == *"Basic [REDACTED]"* ]]
}

@test "redact_secrets matches auth keywords case-insensitively and with a colon" {
    local legacy="da39a3ee5e6b4b0d3255bfef95601890afd80709"
    run redact_secrets "Authorization: TOKEN $legacy / bearer $legacy / token:$legacy"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$legacy"* ]]
}

@test "redact_secrets masks netrc and curl -u credentials" {
    local legacy="da39a3ee5e6b4b0d3255bfef95601890afd80709"
    run redact_secrets "machine github.com login x password $legacy"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$legacy"* ]]

    run redact_secrets "curl -u x-access-token:$legacy https://api.github.com"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$legacy"* ]]
}

@test "redact_secrets masks a token query parameter" {
    local legacy="da39a3ee5e6b4b0d3255bfef95601890afd80709"
    run redact_secrets "GET /orgs/acme/runners?access_token=$legacy returned 401"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$legacy"* ]]
    [[ "$output" == *"returned 401"* ]]
}

@test "redact_secrets masks org PATs that were never in the caller's scope" {
    # watch.sh notifies from its parent shell, which never sourced an org
    # config, so the exact-value pass has to read the PATs itself.
    mkdir -p "$NOTIFY_TEST_DIR/orgs"
    printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_acme0123456789acme0123456789acme01"\n' \
        > "$NOTIFY_TEST_DIR/orgs/acme.conf"
    printf 'GITHUB_ORG="beta"\nGITHUB_PAT="not-token-shaped-beta-pat"\n' \
        > "$NOTIFY_TEST_DIR/orgs/beta.conf"
    ORG_CONFIG_DIR="$NOTIFY_TEST_DIR/orgs"
    unset GITHUB_PAT CANARY_PAT

    run redact_secrets "watcher failed: not-token-shaped-beta-pat was rejected"
    [ "$status" -eq 0 ]
    [[ "$output" != *"not-token-shaped-beta-pat"* ]]
    [[ "$output" == *"was rejected"* ]]
}

@test "redact_secrets withholds the field when sed fails instead of blanking it" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$NOTIFY_TEST_DIR/bin/sed"
    chmod +x "$NOTIFY_TEST_DIR/bin/sed"

    run redact_secrets "expected 5fa5b05e got deadbeef"
    [ "$status" -eq 0 ]
    [ "$output" = "[REDACTION FAILED - content withheld]" ]

    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    run notify error bake.failed "bake failed for generation 8" "raw guest output"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.detail' "$CURL_BODY")" = "[REDACTION FAILED - content withheld]" ]
}

# --- misconfiguration fails open, and says so --------------------------------

@test "an unrecognized NOTIFY_MIN_SEVERITY fails open and says so" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_MIN_SEVERITY="debug"
    run notify info generation.promoted "generation 8 promoted" ""
    [ "$status" -eq 0 ]
    [ "$(jq -r '.severity' "$CURL_BODY")" = "info" ]
    [[ "$output" == *"unknown NOTIFY_MIN_SEVERITY"* ]]
}

@test "NOTIFY_MIN_SEVERITY tolerates stray whitespace and case" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_MIN_SEVERITY=" ERROR "
    run notify warn clone.failed "one flaky slot" ""
    [ "$status" -eq 0 ]
    [ ! -f "$CURL_CALLS" ]
    [[ "$output" != *"unknown NOTIFY_MIN_SEVERITY"* ]]
}

@test "an unknown NOTIFY_FORMAT falls back to slack and says so" {
    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_FORMAT="xml"
    run notify error clone.failed "re-clone failed" ""
    [ "$status" -eq 0 ]
    [ "$(jq -r '.event' "$CURL_BODY")" = "clone.failed" ]
    [[ "$output" == *"unknown NOTIFY_FORMAT"* ]]
}

@test "a config with NOTIFY_ settings but no URL warns that alerting is off" {
    printf 'NOTIFY_MIN_SEVERITY="error"\nNOTIFY_FORMAT="slack"\n' \
        > "$NOTIFY_TEST_DIR/half.conf"
    CONFIG_FILE="$NOTIFY_TEST_DIR/half.conf"
    unset NOTIFY_WEBHOOK_URL
    run notify error clone.failed "re-clone failed" ""
    [ "$status" -eq 0 ]
    [ ! -f "$CURL_CALLS" ]
    [[ "$output" == *"no NOTIFY_WEBHOOK_URL"* ]]
}

@test "a config that never opted in stays completely silent" {
    printf 'NETWORK_BRIDGE="vmbr0"\nTEMPLATE_ID="9000"\n' > "$NOTIFY_TEST_DIR/plain.conf"
    CONFIG_FILE="$NOTIFY_TEST_DIR/plain.conf"
    unset NOTIFY_WEBHOOK_URL
    run notify error clone.failed "re-clone failed" ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -f "$CURL_CALLS" ]
}

# --- call sites ---------------------------------------------------------------

@test "the watch.sh aggregation block sends one notification, scaled to the damage" {
    # Runs the real block out of lib/watch.sh rather than a copy, so a reworded
    # block fails here instead of quietly drifting out of test coverage.
    local block
    block=$(awk 'index($0, "if [[ -s \"$FAILED_SLOTS\" ]]; then") {f=1}
                 f {print}
                 f && $0 == "fi" {exit}' "$BATS_TEST_DIRNAME/../../lib/watch.sh")
    [ -n "$block" ]

    NOTIFY_WEBHOOK_URL="https://example.invalid/hook"
    NOTIFY_MIN_SEVERITY="info"
    TEMPLATE_ID=9000
    FAILED_SLOTS="$NOTIFY_TEST_DIR/failed"
    MISSING=("runner-1 acme" "runner-2 acme" "runner-3 acme")

    # Two of three: one flaky clone, the next tick retries it.
    printf 'runner-1\nrunner-2\n' > "$FAILED_SLOTS"
    eval "$block"
    [ "$(grep -c severity "$CURL_BODY")" -eq 1 ]
    [ "$(jq -r '.severity' "$CURL_BODY")" = "warn" ]
    [[ "$(jq -r '.text' "$CURL_BODY")" == *"2 of 3 runner slot(s)"* ]]
    [[ "$(jq -r '.detail' "$CURL_BODY")" == "slots: runner-1 runner-2 (template 9000)" ]]

    # All three: pool-wide, has to page through NOTIFY_MIN_SEVERITY=error.
    : > "$CURL_BODY"
    printf 'runner-1\nrunner-2\nrunner-3\n' > "$FAILED_SLOTS"
    eval "$block"
    [ "$(grep -c severity "$CURL_BODY")" -eq 1 ]
    [ "$(jq -r '.severity' "$CURL_BODY")" = "error" ]
}

@test "common.sh degrades to silence when notify.sh is missing" {
    # install.sh untars file by file, so common.sh exists before notify.sh does.
    mkdir -p "$NOTIFY_TEST_DIR/lib"
    cp "$BATS_TEST_DIRNAME/../../lib/common.sh" "$NOTIFY_TEST_DIR/lib/common.sh"

    cat > "$NOTIFY_TEST_DIR/caller.sh" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$LIB_UNDER_TEST/common.sh"
notify error clone.failed "re-clone failed" "org=acme"
printf 'redaction: %s\n' "$(redact_secrets "ghp_AbCdEf0123456789AbCdEf0123456789AbCd")"
echo "caller survived"
CALLER
    chmod +x "$NOTIFY_TEST_DIR/caller.sh"

    export LIB_UNDER_TEST="$NOTIFY_TEST_DIR/lib"
    run "$NOTIFY_TEST_DIR/caller.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"caller survived"* ]]
    [[ "$output" == *"redaction: [REDACTION UNAVAILABLE]"* ]]
    [ ! -f "$CURL_CALLS" ]

    # The hookscript's own form. A source that fails here short-circuits the
    # && and reads as "not draining", which re-clones during maintenance.
    run bash -c '. "$LIB_UNDER_TEST/common.sh" && declare -F pool_is_draining >/dev/null && echo "drain check reachable"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"drain check reachable"* ]]
}

@test "common.sh degrades to silence when notify.sh is half-written" {
    mkdir -p "$NOTIFY_TEST_DIR/lib"
    cp "$BATS_TEST_DIRNAME/../../lib/common.sh" "$NOTIFY_TEST_DIR/lib/common.sh"
    # Cut the file at an opening brace: an unterminated function, which is what
    # a half-extracted tarball member looks like to `source`.
    sed -n '1,/^redact_secrets() {$/p' "$NOTIFY_LIB" > "$NOTIFY_TEST_DIR/lib/notify.sh"

    cat > "$NOTIFY_TEST_DIR/caller.sh" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$LIB_UNDER_TEST/common.sh" 2>/dev/null
notify error clone.failed "re-clone failed" "org=acme"
echo "caller survived"
CALLER
    chmod +x "$NOTIFY_TEST_DIR/caller.sh"

    export LIB_UNDER_TEST="$NOTIFY_TEST_DIR/lib"
    run "$NOTIFY_TEST_DIR/caller.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"caller survived"* ]]
    [ ! -f "$CURL_CALLS" ]

    run bash -c '. "$LIB_UNDER_TEST/common.sh" 2>/dev/null && declare -F pool_is_draining >/dev/null && echo "drain check reachable"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"drain check reachable"* ]]
}
