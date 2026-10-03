#!/usr/bin/env bash
# The host's bake poll must see the guest's completion marker even when qm
# prints warnings on stderr, and must fail at once, without converting, when
# the guest reports a failed setup or stops.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-poll: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bake-poll: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by the bake functions
{
    INSTALL_DIR=$root
    SNIPPETS_DIR=$state/snippets
    VM_STORAGE=local-zfs
    LATEST_RUNNER_VERSION=2.329.0
    BAKE_TIMEOUT=600
}
mkdir -p "$SNIPPETS_DIR"
guest=$state/guest
calls=$state/calls

sleep() { :; }
mock_stderr=""
mock_stopped=0
mock_converted=0
# Every qm call prints $mock_stderr on stderr first, like a Perl locale warning.
qm() {
    [[ -z "$mock_stderr" ]] || printf '%s\n' "$mock_stderr" >&2
    printf '%s\n' "$*" >> "$calls"
    case "$1" in
        importdisk) printf "unused0: successfully imported disk 'local-zfs:vm-9001-disk-0'\n" ;;
        config)
            printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-9001-cloudinit,media=cdrom\n'
            if [[ "$mock_converted" == 1 ]]; then
                printf 'scsi0: local-zfs:base-9001-disk-0,size=30G\ntemplate: 1\n'
            else
                printf 'scsi0: local-zfs:vm-9001-disk-0,size=30G\n'
            fi
            ;;
        status)
            if [[ "$mock_stopped" == 1 ]]; then
                printf 'status: stopped\n'
            else
                printf 'status: running\n'
            fi
            ;;
        shutdown) mock_stopped=1 ;;
        template) mock_converted=1 ;;
        guest) guest_exec "$@" ;;
        set|resize|start) return 0 ;;
        *) return 1 ;;
    esac
}
# qm guest exec <vmid> -- <command...>, run against $guest as the guest's root
# filesystem. Prints the JSON qm prints.
guest_exec() {
    local -a cmd=()
    local arg out rc=0
    shift 3
    [[ "${1:-}" != -- ]] || shift
    for arg in "$@"; do
        arg=${arg//\/opt\//$guest/opt/}
        arg=${arg//\/var\/log\//$guest/var/log/}
        cmd+=("$arg")
    done
    out=$("${cmd[@]}" 2>/dev/null) || rc=$?
    jq -nc --argjson rc "$rc" --arg out "$out" '{exitcode: $rc, exited: 1, "out-data": $out}'
}

new_guest() {
    rm -rf "$guest"
    mkdir -p "$guest/opt" "$guest/var/log"
    printf '2.329.0\n' > "$guest/opt/.baked-runner-version"
}
run_bake() {
    : > "$calls"
    mock_stopped=0
    mock_converted=0
    bake_rc=0
    bake_and_publish_vm 9001 2>"$state/log" || bake_rc=$?
}

# A finished guest converts.
new_guest
touch "$guest/opt/.template-setup-complete"
run_bake
[[ "$bake_rc" == 0 ]] || fail "a finished bake failed: $(tail -n 3 "$state/log")"
grep -q '^template 9001$' "$calls" || fail "a finished bake was not converted"

# The same guest, with a locale warning on every qm call's stderr.
mock_stderr=$'perl: warning: Setting locale failed.\nperl: warning: Please check that your locale settings:\n\tLC_ALL = (unset),\n\tLC_CTYPE = "UTF-8",\n\tLANG = "en_US.UTF-8"\n    are supported and installed on your system.\nperl: warning: Falling back to the standard locale ("C").'
run_bake
[[ "$bake_rc" == 0 ]] || fail "a qm warning on stderr hid the completion marker: $(tail -n 3 "$state/log")"
grep -q '^template 9001$' "$calls" || fail "a finished bake with qm warnings was not converted"
[[ "$BAKE_RUNNER_VERSION" == 2.329.0 ]] || fail "baked version was not read: $BAKE_RUNNER_VERSION"
mock_stderr=""

# A guest whose setup failed writes its failure marker and keeps running. The
# first poll must fail the bake and show the guest log, not wait BAKE_TIMEOUT.
new_guest
printf 'rc=1\n' > "$guest/opt/.template-setup-failed"
printf '[2026-10-02 00:10:00] ERROR: All 3 attempts failed for: apt-get update\n' \
    > "$guest/var/log/template-setup.log"
run_bake
[[ "$bake_rc" != 0 ]] || fail "a failed guest setup was converted"
grep -q 'Template setup failed inside the guest' "$state/log" || fail "the guest failure was not reported"
grep -q 'All 3 attempts failed for: apt-get update' "$state/log" || fail "the guest log tail was not shown"
if grep -q 'timed out' "$state/log"; then fail "a failed guest setup waited for BAKE_TIMEOUT"; fi
polls=$(grep -c 'template-setup-complete' "$calls" || true)
[[ "$polls" -eq 1 ]] || fail "the host polled $polls times after the guest failed"
if grep -q '^template ' "$calls"; then fail "qm template ran on a failed bake"; fi

# A guest that fails before its agent runs powers off; that fails the bake too.
new_guest
mock_stopped=1
: > "$calls"
bake_rc=0
bake_and_publish_vm 9001 2>"$state/log" || bake_rc=$?
[[ "$bake_rc" != 0 ]] || fail "a stopped bake VM was converted"
grep -q 'stopped before setup completion was confirmed (status: stopped)' "$state/log" \
    || fail "a stopped bake VM was not reported"
if grep -q '^template ' "$calls"; then fail "qm template ran on a stopped bake VM"; fi

printf 'bake-poll: ok\n'
