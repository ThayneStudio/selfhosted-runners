#!/usr/bin/env bash
# Lowering RUNNER_COUNT or changing RUNNER_PREFIX must shrink the pool: a VM
# that was one of the org's slots and no longer is one is destroyed after its
# job and not re-cloned. Extra runners from `runner create` keep recycling.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool-retire: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# reclone.sh sources these too; naming them lets shellcheck follow them.
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
# shellcheck source=../lib/reclone.sh
source "$root/lib/reclone.sh"
fail() { printf 'pool-retire: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

CONFIG_FILE=$state/github-runners.conf
ORG_CONFIG_DIR=$state/orgs
SNIPPETS_DIR=$state/snippets
POOL_DRAIN_FILE=$state/drain
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
SLOT_STATE_DIR=$state/slots
SLOT_LOCK_PREFIX=$state/slot
mkdir -p "$ORG_CONFIG_DIR" "$SNIPPETS_DIR" "$state/vm"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=9000\n' > "$CONFIG_FILE"
actions=$state/actions

org_conf() {
    printf 'GITHUB_ORG="%s"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="%s"\nRUNNER_COUNT="%s"\n' "$1" "$2" "$3" \
        > "$ORG_CONFIG_DIR/$1.conf"
}
# make_vm <name> <org> [kind]: a stopped VM 9001 cloned as <kind> (none: an
# older clone that recorded no kind).
make_vm() {
    mkdir -p "$state/vm/9001"
    printf '%s\n' "$1" > "$state/vm/9001/name"
    printf '%s\n' "$2" > "$state/vm/9001/org"
    printf 'selfhosted-runners org=%s%s\n' "$2" "${3:+ kind=$3}" > "$state/vm/9001/description"
}
qm() {
    local dir="$state/vm/${2:-none}"
    case "$1" in
        config)
            if [[ "$2" == 9000 ]]; then
                printf 'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local-zfs:base-9000-disk-0,size=30G\n'
                return 0
            fi
            [[ -d "$dir" ]] || return 2
            printf 'name: %s\n' "$(cat "$dir/name")"
            printf 'description: %s\n' "$(cat "$dir/description")"
            printf 'cicustom: user=local:snippets/runner-%s-user-%s.yaml\n' "$2" "$(cat "$dir/org")"
            ;;
        status) [[ -d "$dir" ]] && printf 'status: stopped\n' ;;
        destroy)
            printf 'destroy %s\n' "$2" >> "$actions"
            rm -rf "$dir"
            ;;
        list) printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n' ;;
        *) return 1 ;;
    esac
}
flock() { :; }
sleep() { :; }
logger() { :; }
clone_runner() { printf 'clone %s %s\n' "$1" "$2" >> "$actions"; }

# expect <recloned|retired> <case>
expect() {
    : > "$actions"
    set +e
    ( set -e; reclone_main 9001 ) > "$state/out" 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$2: reclone failed (rc=$rc): $(tail -n 3 "$state/out")"
    grep -qx 'destroy 9001' "$actions" || fail "$2: the old VM was not destroyed"
    case "$1" in
        recloned) grep -q '^clone ' "$actions" || fail "$2: was not re-cloned" ;;
        retired)
            if grep -q '^clone ' "$actions"; then
                fail "$2: was re-cloned: $(grep '^clone ' "$actions")"
            fi
            grep -q 'not re-cloning' "$state/out" || fail "$2: the retirement was not logged"
            ;;
    esac
}

org_conf acme runner 2
make_vm runner-2 acme slot
expect recloned "a configured slot"

# RUNNER_COUNT lowered from 2 to 1.
org_conf acme runner 1
make_vm runner-2 acme slot
expect retired "a slot past the lowered RUNNER_COUNT"

# RUNNER_PREFIX changed from runner to ci.
org_conf acme ci 2
make_vm runner-1 acme slot
expect retired "a slot of the old prefix"

# Extra runners from `runner create` recycle until `runner destroy`, even
# when their name looks like a slot past the count.
org_conf acme runner 2
make_vm build-box acme extra
expect recloned "an extra runner"
make_vm runner-5 acme extra
expect recloned "an extra runner named like a surplus slot"

# Clones from before the kind was recorded: a <prefix>-N past the count
# retires, any other name recycles.
org_conf acme runner 1
make_vm runner-2 acme
expect retired "an unmarked slot past the count"
make_vm runner-01 acme
expect recloned "an unmarked manual runner-01"
make_vm runner-1 acme
expect recloned "an unmarked configured slot"

# A count that cannot be read must not retire anything.
org_conf acme runner ''
make_vm runner-2 acme slot
expect recloned "a slot while RUNNER_COUNT is unreadable"

# Another org took over the old prefix: its watcher must get the slot.
org_conf acme ci 2
org_conf beta runner 2
make_vm runner-1 acme extra
expect retired "a name that is now another org's slot"
rm -f "$ORG_CONFIG_DIR/beta.conf"

# The org was removed: destroy, do not re-clone, do not fail.
make_vm runner-1 gone slot
expect retired "a VM of a removed org"

printf 'pool-retire: ok\n'
