#!/usr/bin/env bash
# The host reads the latest actions/runner release before every bake decision.
# The REST API allows 60 unauthenticated requests an hour per address, and
# curl does not retry its 403, so a rate-limited midnight failed the nightly
# rebake (and setup's bake). When the API fails, the version must come from
# github.com's releases/latest redirect, and only as a valid X.Y.Z.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bakerebake2-release-fallback: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bakerebake2-release-fallback: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

api_url=https://api.github.com/repos/actions/runner/releases/latest
page_url=https://github.com/actions/runner/releases/latest
# $mock_api is the API's JSON, or "fail" for curl -f's exit 22 on a 403 or 429.
# $mock_location is where github.com redirects, or "fail".
mock_api=fail
mock_location=https://github.com/actions/runner/releases/tag/v2.337.0
curl() {
    local arg url="" write="" follow=0
    printf '%s\n' "$*" >> "$state/curl.log"
    while [[ $# -gt 0 ]]; do
        arg=$1
        shift
        case "$arg" in
            -w) write=$1; shift ;;
            -o|--retry|--max-time) shift ;;
            --location) follow=1 ;;
            --*) ;;
            # -L alone or in a cluster such as -sfL.
            -*L*) follow=1 ;;
            https://*) url=$arg ;;
        esac
    done
    case "$url" in
        "$api_url")
            [[ "$mock_api" != fail ]] || return 22
            printf '%s\n' "$mock_api"
            ;;
        "$page_url")
            [[ "$mock_location" != fail ]] || return 22
            # Like curl: %{redirect_url} is empty once a redirect was followed.
            if [[ "$write" == '%{redirect_url}' && "$follow" == 0 ]]; then
                printf '%s' "$mock_location"
            fi
            ;;
        *) return 6 ;;
    esac
}
lookup() {
    : > "$state/curl.log"
    LATEST_RUNNER_VERSION=stale
    LATEST_RUNNER_PUBLISHED_AT=stale
    lookup_rc=0
    fetch_latest_runner_release 2>"$state/log" || lookup_rc=$?
}

# The API answers: the redirect is not needed.
mock_api='{"tag_name":"v2.336.0","published_at":"2026-07-01T00:00:00Z"}'
lookup
[[ "$lookup_rc" == 0 && "$LATEST_RUNNER_VERSION" == 2.336.0 ]] || fail "the API answer was not used: $LATEST_RUNNER_VERSION"
[[ "$LATEST_RUNNER_PUBLISHED_AT" == 2026-07-01T00:00:00Z ]] || fail "published_at was not kept"
if grep -q "$page_url" "$state/curl.log"; then fail "github.com was asked although the API answered"; fi

# Rate limited (curl -f exits 22 on the 403): the redirect names the release.
mock_api=fail
lookup
[[ "$lookup_rc" == 0 ]] || fail "a rate-limited API failed the lookup: $(cat "$state/log")"
[[ "$LATEST_RUNNER_VERSION" == 2.337.0 ]] || fail "the redirect's version was not used: $LATEST_RUNNER_VERSION"
[[ -z "$LATEST_RUNNER_PUBLISHED_AT" ]] || fail "the redirect left published_at '$LATEST_RUNNER_PUBLISHED_AT'"
grep -q 'reading it from github.com instead' "$state/log" || fail "the fallback was not logged"
# An API answer without a release (a rate-limit message) falls back too.
mock_api='{"message":"API rate limit exceeded for 203.0.113.7."}'
lookup
[[ "$lookup_rc" == 0 && "$LATEST_RUNNER_VERSION" == 2.337.0 ]] || fail "an API error body did not fall back: $LATEST_RUNNER_VERSION"
mock_location=https://github.com/actions/runner/releases/tag/2.337.1
lookup
[[ "$lookup_rc" == 0 && "$LATEST_RUNNER_VERSION" == 2.337.1 ]] || fail "a tag without v was not read: $LATEST_RUNNER_VERSION"

# Anything but a release tag on github.com is no answer.
mock_api=fail
for location in fail "" \
    https://github.com/actions/runner/releases/tag/v2.338.0-rc.1 \
    https://github.com/actions/runner/releases \
    https://github.com/login \
    'https://github.com/actions/runner/releases/tag/v2.337.0?x=1' \
    https://example.com/actions/runner/releases/tag/v2.337.0; do
    mock_location=$location
    lookup
    [[ "$lookup_rc" != 0 ]] || fail "redirect '$location' was read as release $LATEST_RUNNER_VERSION"
done

# The nightly rebake decides on the redirect's release instead of exiting.
# shellcheck disable=SC2034 # read by the sourced rebake functions
{
    STATE_DIR=$state/lib
    BAKED_VERSION_FILE=$STATE_DIR/baked-runner-version
    RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
    PENDING_BAKE_FILE=$STATE_DIR/pending-bake
    PENDING_VERSION_FILE=$STATE_DIR/pending-version
    REBAKE_LOCK_FILE=$state/rebake.lock
    CONFIG_FILE=$state/github-runners.conf
}
mkdir -p "$STATE_DIR"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=9000\n' > "$CONFIG_FILE"
printf 'version=2.336.0\ntemplate_id=9000\nbaked_at=%s\n' "$(date -u +%s)" > "$BAKED_VERSION_FILE"
require_root() { :; }
flock() { :; }
qm() {
    case "$1" in
        status) [[ "$2" == 9000 ]] ;;
        config) printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 1\n' ;;
        *) return 1 ;;
    esac
}
perform_bake() { printf 'baked with %s\n' "$LATEST_RUNNER_VERSION" > "$state/baked"; }
mock_api=fail
mock_location=https://github.com/actions/runner/releases/tag/v2.337.0
set +e
(set -e; rebake_main --foreground) 2>"$state/log"
rebake_rc=$?
set -e
[[ "$rebake_rc" == 0 ]] || fail "the rebake failed with a rate-limited API: $(cat "$state/log")"
[[ "$(cat "$state/baked" 2>/dev/null)" == "baked with 2.337.0" ]] \
    || fail "the rebake did not bake the redirect's release 2.337.0: $(cat "$state/log")"

printf 'bakerebake2-release-fallback: ok\n'
