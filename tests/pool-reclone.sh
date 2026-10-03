#!/usr/bin/env bash
# reclone.sh must leave a VM it cannot recycle yet exactly as it is. vzdump
# locks a VM for a stop-mode backup and then starts it again, and that start
# needs the VM's snippets: deleting them first left a VM that could never
# start or be backed up again.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool-reclone: bash 4+ is required\n' >&2
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
fail() { printf 'pool-reclone: %s\n' "$1" >&2; exit 1; }
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
printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="runner"\nRUNNER_COUNT="2"\n' > "$ORG_CONFIG_DIR/acme.conf"
actions=$state/actions

# VMs live in files: qm runs inside command substitutions, which cannot
# change shell variables.
make_vm() {
    local vmid="$1" name="$2" status="$3" lock="${4:-}"
    mkdir -p "$state/vm/$vmid"
    printf '%s\n' "$name" > "$state/vm/$vmid/name"
    printf '%s\n' "$status" > "$state/vm/$vmid/status"
    printf '%s\n' "$lock" > "$state/vm/$vmid/lock"
    : > "$SNIPPETS_DIR/runner-$vmid-meta.yaml"
    : > "$SNIPPETS_DIR/runner-$vmid-user-acme.yaml"
}
destroy_rc=0
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
            printf 'cicustom: user=local:snippets/runner-%s-user-acme.yaml,meta=local:snippets/runner-%s-meta.yaml\n' "$2" "$2"
            [[ -z "$(cat "$dir/lock")" ]] || printf 'lock: %s\n' "$(cat "$dir/lock")"
            ;;
        status)
            [[ -d "$dir" ]] || return 2
            printf 'status: %s\n' "$(cat "$dir/status")"
            ;;
        destroy)
            printf 'destroy %s\n' "${*:2}" >> "$actions"
            if [[ "$destroy_rc" != 0 ]]; then
                printf "VM is locked (backup)\n" >&2
                return "$destroy_rc"
            fi
            rm -rf "$dir"
            ;;
        list)
            printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
            local d
            for d in "$state"/vm/*; do
                [[ -d "$d" ]] || continue
                printf '%10s %-20s %-10s 8192 30.00 0\n' "${d##*/}" "$(cat "$d/name")" "$(cat "$d/status")"
            done
            ;;
        *) return 1 ;;
    esac
}
on_flock=""
flock() { [[ -z "$on_flock" ]] || eval "$on_flock"; }
sleep() { :; }
logger() { printf '%s\n' "$*" >> "$state/logger"; }
clone_runner() { printf 'clone %s %s\n' "$1" "$2" >> "$actions"; }

run_reclone() {
    : > "$actions"
    set +e
    ( set -e; reclone_main "$@" ) >> "$state/out" 2>&1
    rc=$?
    set -e
}
snippets_left() { compgen -G "$SNIPPETS_DIR/runner-$1-*.yaml" > /dev/null; }

# vzdump locked the VM for a stop-mode backup and shut it down: post-stop
# fired, but the VM is not dead. Nothing may be touched.
make_vm 9001 runner-1 stopped backup
run_reclone 9001
[[ $rc -eq 0 ]] || fail "a locked VM made reclone fail (rc=$rc)"
[[ ! -s "$actions" ]] || fail "a locked VM was acted on: $(cat "$actions")"
snippets_left 9001 || fail "the snippets of a locked VM were deleted"

# vzdump (or `qm reboot`) started the VM again before reclone ran.
make_vm 9001 runner-1 running
run_reclone 9001
[[ $rc -eq 0 && ! -s "$actions" ]] || fail "a running VM was acted on: $(cat "$actions")"
snippets_left 9001 || fail "the snippets of a running VM were deleted"

# The watcher recycled this VMID while reclone waited for the slot lock.
make_vm 9001 runner-1 stopped
on_flock="printf 'runner-2\n' > '$state/vm/9001/name'"
run_reclone 9001
on_flock=""
[[ $rc -eq 0 && ! -s "$actions" ]] || fail "a VM renamed under the slot lock was acted on: $(cat "$actions")"

# A destroy that keeps failing must leave the snippets for the next attempt.
make_vm 9001 runner-1 stopped
destroy_rc=2
run_reclone 9001
destroy_rc=0
[[ $rc -ne 0 ]] || fail "reclone reported success after the destroy failed"
[[ "$(grep -c '^destroy 9001' "$actions")" -eq 3 ]] || fail "the destroy was not retried: $(cat "$actions")"
snippets_left 9001 || fail "the snippets were deleted although the VM still exists"
grep -q '^clone' "$actions" && fail "a replacement was cloned while the old VM still exists"

# The normal path: destroy (without --purge), then the snippets, then refill.
make_vm 9001 runner-1 stopped
run_reclone 9001
[[ $rc -eq 0 ]] || fail "a plain reclone failed (rc=$rc): $(tail -n 5 "$state/out")"
[[ "$(cat "$actions")" == $'destroy 9001\nclone runner-1 acme' ]] || fail "unexpected reclone actions: $(cat "$actions")"
snippets_left 9001 && fail "the snippets of a destroyed VM were kept"

printf 'pool-reclone: ok\n'
