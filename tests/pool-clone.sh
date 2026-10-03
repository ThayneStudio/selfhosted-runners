#!/usr/bin/env bash
# clone_runner must configure a clone so the pool can always recycle it:
# a guest reboot has to exit QEMU (post-stop, then reclone) instead of
# resetting in place with no runner, and the clone must name its org from
# the very first config write, before --cicustom exists.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool-clone: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'pool-clone: %s\n' "$1" >&2; exit 1; }
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

: > "$calls"
vmid=$(clone_runner runner-1 acme) || fail "clone_runner failed"
[[ "$vmid" == 9001 ]] || fail "unexpected VMID: $vmid"

reboot_line=$(grep -n '^set 9001 --reboot 0$' "$calls" | cut -d: -f1) || fail "reboot was not disabled on the clone"
start_line=$(grep -n '^start 9001$' "$calls" | cut -d: -f1) || fail "the clone was not started"
(( reboot_line < start_line )) || fail "reboot was disabled only after the clone started"
grep -qx 'clone 9000 9001 --name runner-1 --description selfhosted-runners org=acme' "$calls" \
    || fail "qm clone did not write the ownership marker with the name: $(grep '^clone' "$calls")"

# The marker also records whether the VM is one of the org's slots, so the
# pool can retire it when RUNNER_COUNT or RUNNER_PREFIX change.
kind_of_clone() {
    : > "$calls"
    clone_runner "$1" acme > /dev/null || fail "clone_runner $1 failed"
    sed -n 's/^clone 9000 9001 --name [^ ]* --description //p' "$calls"
}
RUNNER_PREFIX=runner
RUNNER_COUNT=2
[[ "$(kind_of_clone runner-2)" == "selfhosted-runners org=acme kind=slot" ]] || fail "a configured slot was not marked as a slot"
[[ "$(kind_of_clone runner-3)" == "selfhosted-runners org=acme kind=extra" ]] || fail "a name past RUNNER_COUNT was marked as a slot"
[[ "$(kind_of_clone runner-01)" == "selfhosted-runners org=acme kind=extra" ]] || fail "runner-01 was marked as slot runner-1"
[[ "$(kind_of_clone build-box)" == "selfhosted-runners org=acme kind=extra" ]] || fail "a manual runner was marked as a slot"
RUNNER_COUNT=garbled
[[ "$(kind_of_clone runner-1)" == "selfhosted-runners org=acme" ]] || fail "a kind was guessed without a readable RUNNER_COUNT"
unset RUNNER_PREFIX RUNNER_COUNT

# CLONE_MINT_CONFLICT tells the backoff whether the previous runner of the
# name was still registered (it never finished a job).
deregister_runner() { :; }
fetch_jit_config() {
    if [[ -e "$state/stale-runner" ]]; then
        rm -f "$state/stale-runner"
        return 2
    fi
    printf 'Zm9v\n'
}
conflict=$(clone_runner runner-1 acme > /dev/null; printf '%s' "$CLONE_MINT_CONFLICT")
[[ "$conflict" == 0 ]] || fail "a clean mint reported a conflict"
: > "$state/stale-runner"
conflict=$(clone_runner runner-1 acme > /dev/null; printf '%s' "$CLONE_MINT_CONFLICT")
[[ "$conflict" == 1 ]] || fail "a mint that found the name still registered reported no conflict"

[[ "$(slot_number runner-12 runner)" == 12 ]] || fail "slot_number missed runner-12"
[[ "$(slot_number my.pool-3 my.pool)" == 3 ]] || fail "slot_number missed a prefix with a dot"
for name in runner-0 runner-01 runner-x runner- runner ci-runner-1 myxpool-3; do
    prefix=runner
    [[ "$name" == myxpool-3 ]] && prefix=my.pool
    if slot_number "$name" "$prefix" > /dev/null; then
        fail "slot_number accepted $name for prefix $prefix"
    fi
done

# get_vm_org: snippets first, then the clone-time marker. A clone killed
# between qm clone and --cicustom has only the marker.
vm_config=""
qm() { [[ "$1" == config ]] && printf '%s\n' "$vm_config"; }
org_of() {
    vm_config="$1"
    get_vm_org 9001
}
[[ "$(org_of $'name: runner-1\ndescription: selfhosted-runners org=acme\nscsi0: local-zfs:base-9000-disk-0/vm-9001-disk-0')" == acme ]] \
    || fail "a clone with only the marker is not managed"
[[ "$(org_of $'name: runner-1\ndescription: selfhosted-runners org=acme%0Aoperator note')" == acme ]] \
    || fail "an edited description lost the marker"
[[ "$(org_of $'cicustom: user=local:snippets/runner-9001-user-beta.yaml,meta=local:snippets/runner-9001-meta.yaml\ndescription: selfhosted-runners org=acme')" == beta ]] \
    || fail "the marker overrode the cicustom snippet"
[[ "$(org_of $'cicustom: user=local:snippets/runner-user-data-legacy.yaml')" == legacy ]] \
    || fail "legacy per-org snippets are no longer recognised"
[[ "$(org_of $'name: runner-1\ndescription: my own runner-1 VM')" == unknown ]] \
    || fail "a foreign VM with a description was treated as managed"
[[ "$(org_of $'name: runner-1')" == unknown ]] || fail "an unmarked VM was treated as managed"
[[ "$(org_of '')" == unknown ]] || fail "an unreadable config was treated as managed"

printf 'pool-clone: ok\n'
