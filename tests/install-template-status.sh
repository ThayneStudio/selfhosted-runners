#!/usr/bin/env bash
# install.sh used to say setup need not be run again whenever the conf file
# existed. A failed first bake still leaves that file, and TEMPLATE_ID is not
# a finished template. The closing line has to say so, and it must not claim
# success when qm is missing or the check cannot be made.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'install-template-status: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'install-template-status: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
calls=$state/calls
: > "$calls"

func=$(awk '
    /^report_install_template\(\)/ { show = 1 }
    show { print }
    show && /^}$/ { exit }
' "$root/install.sh")
[[ -n "$func" ]] || fail "install.sh no longer defines report_install_template"
printf '%s\n' "$func" > "$state/report.sh"
# shellcheck source=/dev/null
source "$state/report.sh"

INSTALL_DIR=$root
TEMPLATE_ID=9000
qm_mode=converted

qm() {
    printf 'qm %s\n' "$*" >> "$calls"
    case "$1" in
        config)
            case "$qm_mode" in
                converted)
                    printf 'name: ubuntu-cloud-template\nide2: local:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1\n' "$2" "$2"
                    ;;
                unfinished)
                    printf 'name: ubuntu-cloud-template\nide2: local:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:vm-%s-disk-0,size=30G\n' "$2" "$2"
                    ;;
                flagged)
                    printf 'name: ubuntu-cloud-template\nide2: local:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:vm-%s-disk-0,size=30G\ntemplate: 1\n' "$2" "$2"
                    ;;
                runner)
                    printf 'name: runner-1\nscsi0: local-zfs:vm-%s-disk-0,size=30G\n' "$2"
                    ;;
                missing)
                    printf "Configuration file 'nodes/pve/qemu-server/%s.conf' does not exist\n" "$2" >&2
                    return 2
                    ;;
                broken)
                    printf 'connection refused\n' >&2
                    return 1
                    ;;
                *) fail "unknown qm mode $qm_mode" ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

say() {
    qm_mode=$1
    if [[ "${2-}" == unset ]]; then
        unset TEMPLATE_ID
    else
        TEMPLATE_ID=${2:-9000}
    fi
    : > "$calls"
    report_install_template > "$state/out" 2>"$state/err" || fail "report_install_template failed: $(cat "$state/err") $(cat "$state/out")"
}
done_line='Done. No need to re-run setup.'
refuses_done() {
    if grep -qF "$done_line" "$state/out"; then
        fail "$1 claimed setup was finished: $(cat "$state/out")"
    fi
}

say converted
[[ "$(cat "$state/out")" == "$done_line" ]] || fail "a finished template was not accepted: $(cat "$state/out")"

say unfinished
refuses_done "an unfinished bake"
grep -qF 'unfinished template bake' "$state/out" || fail "an unfinished bake was not described: $(cat "$state/out")"
grep -qF 'qm stop 9000; qm destroy 9000' "$state/out" || fail "an unfinished bake did not say how to remove it: $(cat "$state/out")"
grep -qF 'runner setup' "$state/out" || fail "an unfinished bake did not say to run setup"

say flagged
refuses_done "a template flag over an unconverted disk"
grep -qF 'unfinished template bake' "$state/out" || fail "template: 1 alone was treated as finished: $(cat "$state/out")"
grep -qF 'runner setup' "$state/out" || fail "an unconverted disk did not say to run setup"

say runner
refuses_done "a runner VM"
grep -qF 'not a finished template' "$state/out" || fail "a runner VM was not refused: $(cat "$state/out")"
grep -qF 'runner setup' "$state/out" || fail "a runner VM did not say to run setup"
if grep -qF 'qm destroy' "$state/out"; then
    fail "a runner VM was told to be destroyed: $(cat "$state/out")"
fi

say missing
refuses_done "a missing VM"
grep -qF 'does not exist' "$state/out" || fail "a missing template was not reported: $(cat "$state/out")"
grep -qF 'runner setup' "$state/out" || fail "a missing template did not say to run setup"
if grep -qF 'qm destroy' "$state/out"; then
    fail "a missing VM was told to be destroyed: $(cat "$state/out")"
fi

say broken
refuses_done "an unreadable qm"
grep -qF 'Could not check whether template VM 9000 is a finished template.' "$state/out" \
    || fail "an unreadable qm claimed a result: $(cat "$state/out")"
if grep -qF 'runner setup' "$state/out"; then
    fail "an unreadable qm told the operator setup was the diagnosis: $(cat "$state/out")"
fi

say converted unset
refuses_done "an unset TEMPLATE_ID"
grep -qF 'runner setup' "$state/out" || fail "an unset TEMPLATE_ID did not say to run setup: $(cat "$state/out")"
if grep -qF 'Could not check' "$state/out"; then
    fail "an unset TEMPLATE_ID was treated as an unavailable check: $(cat "$state/out")"
fi

INSTALL_DIR=$state/empty
mkdir -p "$INSTALL_DIR"
say converted 9000
refuses_done "a missing bake library"
grep -qF 'Could not check whether template VM 9000 is a finished template' "$state/out" \
    || fail "a missing bake library claimed a result: $(cat "$state/out")"
INSTALL_DIR=$root

mkdir -p "$state/bin"
(
    PATH=$state/bin
    hash -r
    unset -f qm
    # shellcheck disable=SC2034 # report_install_template reads it
    TEMPLATE_ID=9000
    INSTALL_DIR=$root
    report_install_template > "$state/out" 2>"$state/err" || fail "the no-qm report failed: $(cat "$state/err")"
)
grep -qF 'Could not check whether template VM 9000 is a finished template: qm is not available.' "$state/out" \
    || fail "a missing qm claimed a result: $(cat "$state/out")"
if grep -qF "$done_line" "$state/out"; then
    fail "a missing qm said setup was done: $(cat "$state/out")"
fi

printf 'install-template-status: ok\n'
