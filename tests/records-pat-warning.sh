#!/usr/bin/env bash
# install.sh and setup.sh remove the per-org snippets that embedded the org
# PAT before clones got single-use JIT configs. Both also warned, on every
# run, that running VMs still had the old PAT and that the pool had to be
# recycled before the next job. Clones made with JIT configs hold no PAT, so
# on those hosts the warning was false, and it put a recycle ahead of the
# template bake that the upgrade steps recycle after. The warning is given
# only by a run that removed such snippets.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'records-pat-warning: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'records-pat-warning: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
SNIPPETS_DIR=$state/snippets

# Every host has the hookscript and per-VM snippets, which hold no PAT. A host
# upgraded from before JIT configs also has the per-org snippets.
seed() {
    rm -rf "$SNIPPETS_DIR"
    mkdir -p "$SNIPPETS_DIR"
    : > "$SNIPPETS_DIR/runner-hookscript.sh"
    : > "$SNIPPETS_DIR/runner-101-user-acme.yaml"
    if [[ "$1" == pre-jit ]]; then
        printf 'GITHUB_PAT=ghp_test\n' > "$SNIPPETS_DIR/runner-user-data-acme.yaml"
        printf 'GITHUB_PAT=ghp_test\n' > "$SNIPPETS_DIR/runner-user-data-beta.yaml"
    fi
}
check_pruned() {
    if compgen -G "$SNIPPETS_DIR/runner-user-data-*.yaml" > /dev/null; then
        fail "$1 left a per-org PAT snippet"
    fi
    [[ -e "$SNIPPETS_DIR/runner-hookscript.sh" && -e "$SNIPPETS_DIR/runner-101-user-acme.yaml" ]] ||
        fail "$1 removed a snippet that holds no PAT"
}

# --- install.sh: its lines from the prune to the end of the upgrade branch ---
block=$(awk '
    /# Prune obsolete per-org snippets/ { seen = 1 }
    seen && /^else$/ { exit }
    seen { print }
' "$root/install.sh")
grep -qF 'runner-user-data-' <<< "$block" || fail "install.sh no longer prunes the per-org PAT snippets"
block=${block//\/var\/lib\/vz\/snippets/"$SNIPPETS_DIR"}
# These lines run on this machine, so they may name no other host path.
if grep -nE '(^|[^[:alnum:]_.-])/(etc|opt|usr|var|run|srv|root|home)/' <<< "${block//"$state"/}" >&2; then
    fail "the install.sh lines under test name host paths"
fi
run_install() {
    "$BASH" -euo pipefail -c "$block" > "$state/out" 2>&1 ||
        fail "install.sh's closing lines failed: $(cat "$state/out")"
}

seed pre-jit
run_install
check_pruned install.sh
grep -qF 'Removed obsolete per-org PAT snippets' "$state/out" || fail "install.sh did not report the pruned snippets"
grep -qF 'cloned from the removed snippets still have the org PAT' "$state/out" ||
    fail "install.sh did not warn that VMs cloned from the PAT snippets hold the PAT: $(cat "$state/out")"
[[ "$(tail -n 1 "$state/out")" == '  runner stop && runner start' ]] ||
    fail "install.sh's output does not end with the recycle command: $(cat "$state/out")"

seed jit
run_install
check_pruned install.sh
grep -qF 'Done. No need to re-run setup.' "$state/out" || fail "install.sh did not finish: $(cat "$state/out")"
if grep -E 'PAT|WARNING|runner stop' "$state/out" >&2; then
    fail "install.sh warned about a PAT on a host whose clones never held one"
fi

# --- setup.sh ---
seed pre-jit
prune_pat_snippets 2> "$state/log"
check_pruned setup.sh
grep -qF 'Removed obsolete per-org PAT snippets' "$state/log" || fail "setup did not report the pruned snippets"
warn_pat_snippet_vms > /dev/null 2> "$state/log"
grep -qF 'cloned from the removed snippets still have the org PAT' "$state/log" ||
    fail "setup did not warn that VMs cloned from the PAT snippets hold the PAT: $(cat "$state/log")"
grep -qF 'runner stop && runner start' "$state/log" || fail "setup's warning did not say how to recycle the pool"

seed jit
prune_pat_snippets 2> "$state/log"
check_pruned setup.sh
warn_pat_snippet_vms > "$state/out" 2>> "$state/log"
[[ ! -s "$state/log" && ! -s "$state/out" ]] ||
    fail "setup warned about a PAT on a host whose clones never held one: $(cat "$state/log")"

# The wizard prunes, and warns after its summary only through the function.
main=$(awk '/^require_root "setup"$/ { seen = 1 } seen' "$root/lib/setup.sh")
grep -qx 'prune_pat_snippets' <<< "$main" || fail "setup.sh no longer prunes the per-org PAT snippets"
grep -qx '[[:space:]]*warn_pat_snippet_vms' <<< "$main" || fail "setup.sh no longer warns about VMs that hold the PAT"
if grep -n 'PAT' <<< "$main" >&2; then
    fail "setup.sh's main body mentions the PAT outside warn_pat_snippet_vms"
fi

printf 'records-pat-warning: ok\n'
