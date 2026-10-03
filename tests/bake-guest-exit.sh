#!/usr/bin/env bash
# The bake guest's setup script must leave /opt/.template-setup-failed whenever
# it exits non-zero, so the host fails the bake at once, and must power the VM
# off when qemu-guest-agent is not running to report that marker. A successful
# exit leaves neither.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-guest-exit: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
yaml=$root/templates/template-setup.yaml
fail() { printf 'bake-guest-exit: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$yaml" \
        || fail "template-setup.yaml does not parse"
elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$yaml" || fail "template-setup.yaml does not parse"
else
    printf 'bake-guest-exit: no PyYAML or ruby; skipping the YAML parse check\n' >&2
fi

# The script cloud-init writes to /opt/setup-template.sh, with its markers
# moved under $state/opt and its apt settings under $state/apt.conf.d.
awk '
    /^  - path: \/opt\/setup-template\.sh$/ { file = 1; next }
    file && /^    content: \|$/ { block = 1; next }
    block && /^      / { print substr($0, 7); next }
    block && /^[[:space:]]*$/ { print ""; next }
    block { exit }
' "$yaml" | sed -e "s#/opt/\.template-setup-#$state/opt/.template-setup-#g" \
    -e "s#/etc/apt/apt\.conf\.d/#$state/apt.conf.d/#g" > "$state/setup-template.sh"
grep -q '^set -euo pipefail$' "$state/setup-template.sh" || fail "could not extract setup-template.sh"
"$BASH" -n "$state/setup-template.sh" || fail "setup-template.sh has a syntax error"
mkdir -p "$state/opt" "$state/bin" "$state/apt.conf.d"

mock() {
    printf '#!/bin/sh\n%s\n' "$2" > "$state/bin/$1"
    chmod +x "$state/bin/$1"
}
# shellcheck disable=SC2016 # the mock bodies expand when the mocks run
{
    mock systemctl 'echo "$*" >> "$MOCK_DIR/systemctl.log"
case "$1" in
    is-active) [ -e "$MOCK_DIR/agent-active" ] ;;
    *) exit 0 ;;
esac'
    mock df 'printf "Filesystem 1G-blocks Used Available Use%% Mounted on\n/dev/sda1 30G 2G %sG 7%% /\n" "$MOCK_FREE_GB"'
    mock curl 'exit 0'
    mock sleep 'exit 0'
    mock apt-get 'case "$*" in *"$MOCK_APT_FAIL"*) exit 100 ;; esac'
}

run_setup() {
    rm -f "$state/opt/.template-setup-failed" "$state/systemctl.log"
    : > "$state/systemctl.log"
    setup_rc=0
    PATH="$state/bin:$PATH" MOCK_DIR=$state "$BASH" "$1" > "$state/out" 2>&1 || setup_rc=$?
}
expect_failure_marker() {
    [[ "$setup_rc" == "$2" ]] || fail "$1: exited $setup_rc, expected $2"
    [[ "$(cat "$state/opt/.template-setup-failed" 2>/dev/null)" == "rc=$2" ]] \
        || fail "$1: no failure marker with rc=$2"
    grep -q "Template setup failed with exit code $2" "$state/out" || fail "$1: the failure was not logged"
}

# Fails before step 2 installs the agent: the host cannot read the marker, so
# the guest powers off.
export MOCK_FREE_GB=2 MOCK_APT_FAIL=no-such-apt-call
rm -f "$state/agent-active"
run_setup "$state/setup-template.sh"
expect_failure_marker "disk space check" 1
grep -qx -- '--no-block poweroff' "$state/systemctl.log" || fail "a failure without the agent did not power off"

# Fails after the agent runs (errexit on a failed retry): the marker is enough,
# and the VM keeps running so the host can read the guest log.
export MOCK_FREE_GB=28 MOCK_APT_FAIL=upgrade
touch "$state/agent-active"
run_setup "$state/setup-template.sh"
expect_failure_marker "apt-get upgrade" 1
grep -q 'All 3 attempts failed for: apt-get upgrade' "$state/out" || fail "the run did not reach apt-get upgrade"
if grep -q poweroff "$state/systemctl.log"; then fail "a failure with the agent running powered off"; fi

# The same handler on the success path and on a plain failing command: run the
# script's helpers and exit handling, everything before its first step.
awk '/^log "=== Template Setup: Installing Tools ===\"$/ { exit } { print }' \
    "$state/setup-template.sh" > "$state/head.sh"
grep -q '^trap [[:alnum:]_]* EXIT$' "$state/head.sh" || fail "setup-template.sh sets no top-level EXIT trap"
{ cat "$state/head.sh"; printf 'log "setup finished"\n'; } > "$state/ok.sh"
run_setup "$state/ok.sh"
[[ "$setup_rc" == 0 ]] || fail "a successful run exited $setup_rc"
[[ ! -e "$state/opt/.template-setup-failed" ]] || fail "a successful run wrote the failure marker"
[[ ! -s "$state/systemctl.log" ]] || fail "a successful run called systemctl: $(cat "$state/systemctl.log")"

rm -f "$state/agent-active"
{ cat "$state/head.sh"; printf 'false\nlog "unreached"\n'; } > "$state/false.sh"
run_setup "$state/false.sh"
expect_failure_marker "plain failing command" 1
if grep -q unreached "$state/out"; then fail "errexit did not stop the script"; fi

printf 'bake-guest-exit: ok\n'
