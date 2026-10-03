#!/usr/bin/env bash
# A slot that keeps failing must back off instead of minting a JIT runner on
# every 30-second tick. Failed clones (watcher or reclone) and VMs that die
# right after boot (reclone) share one per-slot hold that both honour.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool-backoff: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# The entry scripts source these too; naming them lets shellcheck follow them.
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
# shellcheck source=../lib/reclone.sh
source "$root/lib/reclone.sh"
# shellcheck source=../lib/watch.sh
source "$root/lib/watch.sh"
fail() { printf 'pool-backoff: %s\n' "$1" >&2; exit 1; }
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
printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="runner"\nRUNNER_COUNT="1"\n' > "$ORG_CONFIG_DIR/acme.conf"
actions=$state/actions

clock=1000000
date() {
    if [[ "${1:-}" == "+%s" ]]; then
        printf '%s\n' "$clock"
    else
        command date "$@"
    fi
}
born=$clock
file_mtime() { [[ -e "$1" ]] && printf '%s\n' "$born"; }
make_vm() {
    mkdir -p "$state/vm/$1"
    printf '%s\n' "$2" > "$state/vm/$1/name"
    printf 'stopped\n' > "$state/vm/$1/status"
    : > "$SNIPPETS_DIR/runner-$1-meta.yaml"
}
qm() {
    local dir="$state/vm/${2:-none}"
    case "$1" in
        config)
            if [[ "$2" == 9000 ]]; then
                printf 'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local-zfs:%s,size=30G\n' "$template_disk"
                return 0
            fi
            [[ -d "$dir" ]] || return 2
            printf 'name: %s\ncicustom: user=local:snippets/runner-%s-user-acme.yaml\n' "$(cat "$dir/name")" "$2"
            ;;
        status)
            [[ -d "$dir" ]] || return 2
            printf 'status: %s\n' "$(cat "$dir/status")"
            ;;
        destroy)
            printf 'destroy %s\n' "$2" >> "$actions"
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
pvesh() {
    [[ "$*" == "get /nodes/localhost/qemu --output-format json" ]] || return 1
    local d sep=""
    printf '['
    for d in "$state"/vm/*; do
        [[ -d "$d" ]] || continue
        printf '%s{"vmid":%s,"name":"%s","status":"%s","uptime":0}' "$sep" "${d##*/}" "$(cat "$d/name")" "$(cat "$d/status")"
        sep=","
    done
    printf ']\n'
}
template_disk=base-9000-disk-0
flock() { :; }
sleep() { :; }
logger() { printf '%s\n' "$*" >> "$state/logger"; }
require_root() { :; }
cleanup_runner_orphan_volumes() { :; }
clone_rc=0
# 1: the mint found the previous runner of this name still registered (it
# never finished a job). 0: GitHub had already removed it after its job.
mint_conflict=1
clone_runner() {
    printf 'clone %s\n' "$1" >> "$actions"
    CLONE_MINT_CONFLICT=$mint_conflict
    return "$clone_rc"
}

run() {
    : > "$actions"
    set +e
    ( set -e; "$@" ) > "$state/out" 2>&1
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$* failed (rc=$rc): $(tail -n 5 "$state/out")"
}
clones() { grep -c '^clone' "$actions" || true; }

[[ "$(for n in 1 2 3 4 5 6 7 8; do slot_backoff_seconds "$n"; done | tr '\n' ' ')" == "30 60 120 240 480 960 1800 1800 " ]] \
    || fail "unexpected backoff steps"

# R1-18: a clone that fails every time (full storage, broken template) is
# retried on a doubling hold, not on every tick.
clone_rc=1
run watch_main
[[ "$(clones)" -eq 1 ]] || fail "the first tick did not try the missing slot"
clock=$((clock + 29))
run watch_main
[[ "$(clones)" -eq 0 ]] || fail "a failed slot was retried on the next tick"
grep -q 'Filling' "$state/out" && fail "the watcher counted a held slot as missing"
# The worker checks again under the slot lock: the hold can start between
# the watcher's scan and the worker.
run fill_runner_slot runner-1 acme
[[ "$(clones)" -eq 0 ]] || fail "a worker cloned a held slot"
clock=$((clock + 2))
run watch_main
[[ "$(clones)" -eq 1 ]] || fail "the slot was not retried once its hold ended"
clock=$((clock + 59))
run watch_main
[[ "$(clones)" -eq 0 ]] || fail "the second hold did not double"
clock=$((clock + 2))
clone_rc=0
run watch_main
[[ "$(clones)" -eq 1 ]] || fail "the slot was not retried after the doubled hold"
[[ ! -e "$SLOT_STATE_DIR/slot-runner-1" ]] || fail "a successful clone did not clear the backoff"

# R2-11: VMs that die right after boot. reclone.sh must hold the slot, and the
# watcher must not refill it within 30 s as it used to.
die_fast() {
    make_vm 9001 runner-1
    born=$((clock - 60))
    run reclone_main 9001
}
die_fast
[[ "$(cat "$actions")" == $'destroy 9001\nclone runner-1' ]] || fail "first fast death was not recloned: $(cat "$actions")"
die_fast
[[ "$(clones)" -eq 1 ]] || fail "second fast death was not recloned"
die_fast
[[ "$(cat "$actions")" == "destroy 9001" ]] || fail "third fast death in a row was recloned: $(cat "$actions")"
grep -q 'runner-1 died within 120s of its clone 3 times in a row; holding the slot for 30s' "$state/logger" \
    || fail "the hold was not logged"
clock=$((clock + 25))
run watch_main
[[ "$(clones)" -eq 0 ]] || fail "the watcher refilled a held slot"
clock=$((clock + 6))
run watch_main
[[ "$(clones)" -eq 1 ]] || fail "the watcher did not refill the slot after its hold"

# The next run of fast deaths holds twice as long.
die_fast
die_fast
die_fast
[[ "$(clones)" -eq 0 ]] || fail "the second run of fast deaths was recloned"
clock=$((clock + 59))
run watch_main
[[ "$(clones)" -eq 0 ]] || fail "the second hold did not double"
clock=$((clock + 2))
run watch_main
[[ "$(clones)" -eq 1 ]] || fail "the slot was not refilled after the doubled hold"

# A VM that lived past the threshold ran a job: the slot is healthy again.
make_vm 9001 runner-1
born=$((clock - 600))
run reclone_main 9001
[[ "$(clones)" -eq 1 ]] || fail "a long-lived VM was not recloned"
[[ ! -e "$SLOT_STATE_DIR/slot-runner-1" ]] || fail "a long-lived VM did not clear the backoff"
die_fast
die_fast
[[ "$(clones)" -eq 1 ]] || fail "the fast-death count survived a healthy VM"

# Without its meta snippet a VM's lifetime is unknown and counts nothing.
make_vm 9001 runner-1
rm -f "$SNIPPETS_DIR/runner-9001-meta.yaml"
run reclone_main 9001
[[ "$(clones)" -eq 1 ]] || fail "a VM with an unknown lifetime was held"

# A short job also ends its VM within 120 s of the clone. That runner
# finished a job, so GitHub no longer lists it and the next mint has no
# conflict: a stream of short jobs must never hold the slot.
rm -rf "$SLOT_STATE_DIR"
mint_conflict=0
for _ in 1 2 3 4 5; do
    die_fast
    [[ "$(clones)" -eq 1 ]] || fail "a stream of short jobs held the slot"
done
mint_conflict=1

# A template whose disks were never converted (an interrupted `qm template`)
# fails every clone after the JIT mint. The watcher must not even try.
rm -rf "$state/vm"/* "$SLOT_STATE_DIR"
template_disk=vm-9000-disk-0
run watch_main
[[ "$(clones)" -eq 0 ]] || fail "the watcher cloned from an unconverted template"
template_disk=base-9000-disk-0
run watch_main
[[ "$(clones)" -eq 1 ]] || fail "the watcher did not clone from a converted template"

printf 'pool-backoff: ok\n'
