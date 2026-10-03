#!/usr/bin/env bash
# clone_runner must say so when the hookscript is missing. A clone without it
# never recycles itself after its job; only the watcher reclaims it once it
# has stopped. The hookscript used to be skipped without a word.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool2-clone-hookscript: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'pool2-clone-hookscript: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

INSTALL_DIR=$root
SNIPPETS_DIR=$state/snippets
mkdir -p "$SNIPPETS_DIR"
POOL_DRAIN_FILE=$state/drain
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
VMID_LOCK_FILE=$state/vmid.lock
VMID_RESERVATION_LOCK_PREFIX=$state/reserve
CLONE_SLOT_LOCK_PREFIX=$state/clone-slot
TEMPLATE_ID=9000
VM_STORAGE=local-zfs
MIN_VMID=9001
GITHUB_ORG=acme
GITHUB_PAT=ghp_test
calls=$state/qm.calls

flock() { :; }
generate_mac() { printf '02:00:00:00:00:01\n'; }
fetch_jit_config() { printf 'Zm9v\n'; }
qm() {
    printf '%s\n' "$*" >> "$calls"
    case "$1" in
        config) printf 'name: %s\nnet0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0\n' "$clone_name" ;;
        clone) clone_name=$5 ;;
    esac
}
clone_name=""

clone() {
    : > "$calls"
    clone_runner runner-1 acme > /dev/null 2> "$state/err" || fail "clone_runner failed: $(cat "$state/err")"
    grep -qx 'start 9001' "$calls" || fail "the clone was not started"
}

clone
grep -qF "$SNIPPETS_DIR/runner-hookscript.sh is missing, so runner-1 (VMID 9001) will not auto-recycle" "$state/err" \
    || fail "a missing hookscript was not reported: $(cat "$state/err")"
grep -q -- '--hookscript' "$calls" && fail "a missing hookscript was set on the clone"

: > "$SNIPPETS_DIR/runner-hookscript.sh"
clone
grep -qx 'set 9001 --hookscript local:snippets/runner-hookscript.sh' "$calls" || fail "the hookscript was not set on the clone"
grep -q 'is missing' "$state/err" && fail "a present hookscript was reported missing"

printf 'pool2-clone-hookscript: ok\n'
