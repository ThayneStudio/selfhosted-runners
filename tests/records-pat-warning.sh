#!/usr/bin/env bash
# install.sh and setup.sh remove the per-org snippets that embedded the org
# PAT before clones got single-use JIT configs. VMs cloned from them keep the
# PAT on their cloud-init drive until they are destroyed, so both warn while
# any such VM exists: also on a run after one that removed the snippets and
# failed before it warned. Clones made with JIT configs hold no PAT, so a
# host with only those gets no warning.
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
PVE_NODES_DIR=$state/nodes

# Every host has the hookscript and a JIT clone with per-VM snippets, which
# hold no PAT. A host upgraded from before JIT configs also has the per-org
# snippets and VMs cloned from them; "pruned" is that host after a run that
# removed the snippets and then failed before it warned.
seed() {
    rm -rf "$SNIPPETS_DIR" "$PVE_NODES_DIR"
    mkdir -p "$SNIPPETS_DIR" "$PVE_NODES_DIR/pve1/qemu-server"
    : > "$SNIPPETS_DIR/runner-hookscript.sh"
    : > "$SNIPPETS_DIR/runner-101-user-acme.yaml"
    printf 'name: runner-1\ncicustom: user=local:snippets/runner-101-user-acme.yaml,meta=local:snippets/runner-101-meta.yaml\n' \
        > "$PVE_NODES_DIR/pve1/qemu-server/101.conf"
    if [[ "$1" == pre-jit ]]; then
        printf 'GITHUB_PAT=ghp_test\n' > "$SNIPPETS_DIR/runner-user-data-acme.yaml"
        printf 'GITHUB_PAT=ghp_test\n' > "$SNIPPETS_DIR/runner-user-data-beta.yaml"
    fi
    if [[ "$1" == pre-jit || "$1" == pruned ]]; then
        printf 'name: runner-2\ncicustom: user=local:snippets/runner-user-data-acme.yaml,meta=local:snippets/runner-102-meta.yaml\n' \
            > "$PVE_NODES_DIR/pve1/qemu-server/102.conf"
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
    seen && /^[[:space:]]*else$/ { exit }
    seen { print }
' "$root/install.sh")
grep -qF 'runner-user-data-' <<< "$block" || fail "install.sh no longer prunes the per-org PAT snippets"
# These lines run on this machine, so they may name no host path. The
# directories come in as variables, the same ones install.sh defaults.
if grep -nE '(^|[^[:alnum:]_.-])/(etc|opt|usr|var|run|srv|root|home)/' <<< "${block//"$state"/}" >&2; then
    fail "the install.sh lines under test name host paths"
fi
run_install() {
    SNIPPETS_DIR="$SNIPPETS_DIR" PVE_NODES_DIR="$PVE_NODES_DIR" \
        "$BASH" -euo pipefail -c "$block" > "$state/out" 2>&1 ||
        fail "install.sh's closing lines failed: $(cat "$state/out")"
}

seed pre-jit
run_install
check_pruned install.sh
grep -qF 'Removed obsolete per-org PAT snippets' "$state/out" || fail "install.sh did not report the pruned snippets"
grep -qF 'cloned from the old per-org snippets still have the org PAT' "$state/out" ||
    fail "install.sh did not warn that VMs cloned from the PAT snippets hold the PAT: $(cat "$state/out")"
[[ "$(tail -n 1 "$state/out")" == '  runner stop && runner start' ]] ||
    fail "install.sh's output does not end with the recycle command: $(cat "$state/out")"

seed pruned
run_install
grep -qF 'cloned from the old per-org snippets still have the org PAT' "$state/out" ||
    fail "install.sh did not warn after an earlier run had removed the snippets: $(cat "$state/out")"

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
grep -qF 'cloned from the old per-org snippets still have the org PAT' "$state/log" ||
    fail "setup did not warn that VMs cloned from the PAT snippets hold the PAT: $(cat "$state/log")"
grep -qF 'runner stop && runner start' "$state/log" || fail "setup's warning did not say how to recycle the pool"

seed pruned
prune_pat_snippets 2> "$state/log"
warn_pat_snippet_vms > /dev/null 2> "$state/log"
grep -qF '1 runner VM(s) cloned from the old per-org snippets still have the org PAT' "$state/log" ||
    fail "setup did not warn after an earlier run had removed the snippets: $(cat "$state/log")"

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
