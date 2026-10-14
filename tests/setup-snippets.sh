#!/usr/bin/env bash
# Enabling snippets on local storage must keep every content type it already
# has. `pvesm set --content` replaces the whole list, and a guessed list drops
# images and rootdir, which strands every guest disk on local.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup-snippets: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'setup-snippets: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
calls=$state/calls

snippet_storages=""
set_fails=0
pvesm() {
    case "$1" in
        status) printf 'Name Type Status Total Used Available %%\n%s' "$snippet_storages" ;;
        set)
            printf '%s\n' "$*" >> "$calls"
            [[ "$set_fails" == 0 ]]
            ;;
        *) return 1 ;;
    esac
}
stored_content=""
pvesh_fails=0
pvesh() {
    [[ "$*" == "get /storage/local --output-format json" && "$pvesh_fails" == 0 ]] || return 1
    if [[ -n "$stored_content" ]]; then
        printf '{"storage":"local","type":"dir","path":"/var/lib/vz","content":"%s"}\n' "$stored_content"
    else
        printf '{"storage":"local","type":"dir","path":"/var/lib/vz"}\n'
    fi
}
run() {
    : > "$calls"
    stored_content=$1
    enable_local_snippets 2>/dev/null
}

# A ZFS install's local and a no-data-volume install's local.
run iso,vztmpl,backup,import || fail "snippets could not be enabled"
[[ "$(cat "$calls")" == 'set local --content iso,vztmpl,backup,import,snippets' ]] \
    || fail "enabling snippets changed the other content types: $(cat "$calls")"
run iso,vztmpl,backup,rootdir,images,import || fail "snippets could not be enabled"
[[ "$(cat "$calls")" == 'set local --content iso,vztmpl,backup,rootdir,images,import,snippets' ]] \
    || fail "enabling snippets dropped images or rootdir: $(cat "$calls")"

# "none" cannot be combined with another content type.
run none || fail "snippets could not be enabled on local with no content types"
[[ "$(cat "$calls")" == 'set local --content snippets' ]] || fail "none was kept beside snippets"

run backup,snippets,iso || fail "local that already lists snippets failed"
[[ ! -s "$calls" ]] || fail "local that already lists snippets was changed"

# Nothing is guessed when the current list cannot be read.
if run ""; then
    fail "an unreadable content list was replaced"
fi
[[ ! -s "$calls" ]] || fail "an unreadable content list was replaced with a guess"
pvesh_fails=1
if run iso,vztmpl,backup; then
    fail "a failed pvesh read was ignored"
fi
[[ ! -s "$calls" ]] || fail "a failed pvesh read led to pvesm set"
pvesh_fails=0

set_fails=1
if run iso,vztmpl,backup; then
    fail "a failed pvesm set was ignored"
fi
set_fails=0

snippet_storages=$'local dir active 1 1 1 1%\n'
run iso || fail "local with snippets enabled failed"
[[ ! -s "$calls" ]] || fail "local with snippets enabled was changed"

main=$(awk '/^require_root "setup"$/ { seen = 1 } seen' "$root/lib/setup.sh")
grep -qF 'if ! enable_local_snippets; then' <<< "$main" || fail "setup.sh no longer enables snippets through enable_local_snippets"

printf 'setup-snippets: ok\n'
