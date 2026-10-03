#!/usr/bin/env bash
# The host picks the actions/runner release for a bake and renders it into the
# guest snippet. The guest must make no GitHub API call, and must still refuse
# a Runner.Listener that reports another version.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-runner-version: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bake-runner-version: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by the bake functions
{
    INSTALL_DIR=$root
    SNIPPETS_DIR=$state/snippets
    NETWORK_BRIDGE=vmbr0
    VM_STORAGE=local-zfs
    DOCKER_MIRROR_URL=""
}
mkdir -p "$SNIPPETS_DIR"

mock_release='{"tag_name":"v2.330.0","published_at":"2026-09-30T00:00:00Z"}'
curl() {
    printf '%s\n' "$*" >> "$state/host-curl.log"
    [[ -n "$mock_release" ]] || return 22
    printf '%s\n' "$mock_release"
}
qm() {
    printf '%s\n' "$*" >> "$state/qm.log"
    [[ "$1" == create ]]
}
pvesm() {
    case "$1" in
        list) printf 'Volid Format Type Size VMID\n' ;;
        status)
            printf 'Name Type Status Total Used Available %%\n'
            printf '%s zfspool active 1000000000 100000000 900000000 10.00%%\n' "$VM_STORAGE"
            ;;
        *) return 1 ;;
    esac
}

create_vm() {
    rm -f "$state/host-curl.log" "$state/qm.log"
    touch "$state/host-curl.log" "$state/qm.log"
    create_rc=0
    create_bake_vm 9001 2>"$state/log" || create_rc=$?
}

# setup has not read the release: create_bake_vm reads it once, on the host.
LATEST_RUNNER_VERSION=""
create_vm
[[ "$create_rc" == 0 ]] || fail "create_bake_vm failed: $(cat "$state/log")"
[[ "$LATEST_RUNNER_VERSION" == 2.330.0 ]] || fail "the host did not resolve the release: '$LATEST_RUNNER_VERSION'"
[[ $(grep -c 'api.github.com/repos/actions/runner/releases/latest' "$state/host-curl.log") -eq 1 ]] \
    || fail "the host did not read the release exactly once"
grep -q '^create 9001 ' "$state/qm.log" || fail "the bake VM was not created"

# rebake_main already read it: no second lookup.
LATEST_RUNNER_VERSION=2.329.0
create_vm
[[ "$create_rc" == 0 ]] || fail "create_bake_vm failed with a resolved version: $(cat "$state/log")"
[[ ! -s "$state/host-curl.log" ]] || fail "the host read the release again: $(cat "$state/host-curl.log")"
[[ "$LATEST_RUNNER_VERSION" == 2.329.0 ]] || fail "the resolved version changed: $LATEST_RUNNER_VERSION"

# No usable release: no VM.
LATEST_RUNNER_VERSION=""
mock_release=""
create_vm
[[ "$create_rc" != 0 ]] || fail "a bake VM was created without a runner release"
[[ ! -s "$state/qm.log" ]] || fail "qm ran without a runner release: $(cat "$state/qm.log")"
grep -q 'Could not read the latest actions/runner release' "$state/log" || fail "the lookup failure was not reported"
LATEST_RUNNER_VERSION=""
mock_release='{"tag_name":"v2.330.0-rc.1","published_at":null}'
create_vm
[[ "$create_rc" != 0 && ! -s "$state/qm.log" ]] || fail "a bake VM was created for a non-X.Y.Z release"

# The rendered snippet carries the version and still parses.
snippet=$SNIPPETS_DIR/template-setup.yaml
LATEST_RUNNER_VERSION=""
if render_template_setup_snippet 2>/dev/null; then fail "rendered a snippet without a runner version"; fi
LATEST_RUNNER_VERSION=2.329.0
render_template_setup_snippet || fail "render_template_setup_snippet failed"
grep -qx '      RUNNER_VERSION="2.329.0"' "$snippet" || fail "the snippet does not pin RUNNER_VERSION=2.329.0"
if grep -q '{{' "$snippet"; then fail "the snippet kept a placeholder: $(grep '{{' "$snippet")"; fi
if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$snippet" || fail "the rendered snippet does not parse"
elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$snippet" || fail "the rendered snippet does not parse"
fi
if grep -q 'api\.github\.com' "$root/templates/template-setup.yaml"; then
    fail "template-setup.yaml calls the GitHub API from the guest"
fi

# Run the guest's runner step from a snippet: the script head (helpers and exit
# handling) plus step 11, with the runner home and markers moved under $state.
extract_script() {
    awk '
        /^  - path: \/opt\/setup-template\.sh$/ { file = 1; next }
        file && /^    content: \|$/ { block = 1; next }
        block && /^      / { print substr($0, 7); next }
        block && /^[[:space:]]*$/ { print ""; next }
        block { exit }
    ' "$1" | sed -e "s#/home/runner/actions-runner#$state/actions-runner#g" \
        -e "s#/opt/\.template-setup-#$state/opt/.template-setup-#g"
}
runner_step() {
    local script
    script=$(extract_script "$1")
    awk '/^log "=== Template Setup: Installing Tools ===\"$/ { exit } { print }' <<< "$script"
    awk '/^log "\[11\/12\]/ { on = 1 } /^log "\[12\/12\]/ { exit } on { print }' <<< "$script"
}
mkdir -p "$state/bin" "$state/opt"
mock() {
    printf '#!/bin/sh\n%s\n' "$2" > "$state/bin/$1"
    chmod +x "$state/bin/$1"
}
# shellcheck disable=SC2016 # the mock bodies expand when the mocks run
{
    mock curl 'echo "$*" >> "$MOCK_DIR/curl.log"
out=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
[ -z "$out" ] || printf tarball > "$out"'
    mock tar 'mkdir -p bin
printf "#!/bin/sh\nexit 0\n" > bin/installdependencies.sh
printf "#!/bin/sh\necho %s\n" "$MOCK_LISTENER_VERSION" > bin/Runner.Listener
chmod +x bin/installdependencies.sh bin/Runner.Listener'
    mock sudo '[ "$1" != -u ] || shift 2
exec "$@"'
    mock chown 'exit 0'
    mock sleep 'exit 0'
    mock systemctl 'exit 0'
}
run_runner_step() {
    rm -rf "$state/actions-runner" "$state/opt/.template-setup-failed"
    : > "$state/curl.log"
    step_rc=0
    PATH="$state/bin:$PATH" MOCK_DIR=$state MOCK_LISTENER_VERSION=$2 \
        "$BASH" "$1" > "$state/out" 2>&1 || step_rc=$?
}

runner_step "$snippet" > "$state/step.sh"
grep -q 'Downloading GitHub Actions runner' "$state/step.sh" || fail "could not extract the runner step"
run_runner_step "$state/step.sh" 2.329.0
[[ "$step_rc" == 0 ]] || fail "the runner step failed: $(tail -n 3 "$state/out")"
grep -q 'releases/download/v2.329.0/actions-runner-linux-x64-2.329.0.tar.gz' "$state/curl.log" \
    || fail "the guest did not download the host's release: $(cat "$state/curl.log")"
if grep -q 'api\.github\.com' "$state/curl.log"; then fail "the guest called the GitHub API"; fi

run_runner_step "$state/step.sh" 2.330.0
[[ "$step_rc" != 0 ]] || fail "the guest accepted a Runner.Listener of another version"
grep -q 'Runner.Listener version 2.330.0 does not match downloaded 2.329.0' "$state/out" \
    || fail "the version mismatch was not reported"
[[ -e "$state/opt/.template-setup-failed" ]] || fail "the version mismatch left no failure marker"

# An unrendered template fails before downloading anything.
runner_step "$root/templates/template-setup.yaml" > "$state/raw-step.sh"
run_runner_step "$state/raw-step.sh" 2.329.0
[[ "$step_rc" != 0 ]] || fail "the guest ran with an unrendered runner version"
grep -q 'Runner version from the host is not X.Y.Z' "$state/out" || fail "the bad version was not reported"
[[ ! -s "$state/curl.log" ]] || fail "the guest downloaded with a bad version: $(cat "$state/curl.log")"

printf 'bake-runner-version: ok\n'
