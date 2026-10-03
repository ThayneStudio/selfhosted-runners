#!/usr/bin/env bash
# The setup bake's EXIT trap destroys a partial VM even when the SSH tty is
# gone: every log write fails then, and a second SIGHUP or a SIGPIPE can follow.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup-template: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'setup-template: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
actions=$state/actions
: > "$actions"

converted() {
    printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1' "$1" "$1"
}
baking() {
    printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:vm-%s-disk-0,size=30G' "$1" "$1"
}

declare -A vm_config=()
hup_on_stop=0
qm() {
    case "$1" in
        config)
            [[ -n "${vm_config[$2]+set}" ]] || return 2
            printf '%s\n' "${vm_config[$2]}"
            ;;
        stop|destroy)
            printf '%s\n' "$*" >> "$actions"
            # The SIGHUP the kernel sends again when the login shell exits.
            if [[ "$1" == stop && "$hup_on_stop" == 1 ]]; then
                kill -HUP "$BASHPID"
            fi
            ;;
        *) return 1 ;;
    esac
}

# --- The EXIT trap destroys a partial VM, also with a dead tty ---
TEMPLATE_ID=9100
expect_destroyed=$'stop 9100 --timeout 30\ndestroy 9100'
vm_config[9100]=$(baking 9100)
: > "$actions"
# A closed stderr fails every log write, as EIO on a hung-up SSH tty does.
( trap cleanup_bake EXIT; false ) 2>&- || true
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "errexit with a dead tty left the partial bake VM"
: > "$actions"
{ ( trap cleanup_bake EXIT; kill -HUP "$BASHPID"; sleep 5 ) 2>&-; } 2>/dev/null || true
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "SIGHUP with a dead tty left the partial bake VM"
: > "$actions"
hup_on_stop=1
{ ( trap cleanup_bake EXIT; false ) 2>&-; } 2>/dev/null || true
hup_on_stop=0
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "a second SIGHUP during qm stop skipped qm destroy"
# stderr piped to a reader that died with the session (runner setup | tee).
mkfifo "$state/fifo"
exec {fifo_rw}<>"$state/fifo"
exec {broken_pipe}>"$state/fifo"
exec {fifo_rw}<&-
: > "$actions"
{ ( trap cleanup_bake EXIT; false ) 2>&"$broken_pipe"; } 2>/dev/null || true
exec {broken_pipe}>&-
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "SIGPIPE on a log write left the partial bake VM"

for kept in converted foreign unreadable; do
    case "$kept" in
        converted) vm_config[9100]=$(converted 9100) ;;
        foreign) vm_config[9100]=$'name: runner-3\nscsi0: local-zfs:vm-9100-disk-0,size=30G' ;;
        unreadable) unset 'vm_config[9100]' ;;
    esac
    : > "$actions"
    ( trap cleanup_bake EXIT; false ) 2>/dev/null || true
    [[ ! -s "$actions" ]] || fail "cleanup touched a $kept VM"
done

printf 'setup-template: ok\n'
