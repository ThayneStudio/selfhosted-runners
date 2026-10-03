#!/usr/bin/env bash
# A guest that never runs a job must be held even when it takes more than two
# minutes to die: a slow or contended boot, or register-runner.sh waiting
# out a lossy network (about 210 s) before GitHub refuses it. The next mint
# still finds that runner registered, which tells it from a short job, so
# such deaths count toward the hold. Counting only deaths under 120 s let a
# slot loop at about 30 boots and 117 PAT calls an hour.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool2-death-window: bash 4+ is required\n' >&2
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
fail() { printf 'pool2-death-window: %s\n' "$1" >&2; exit 1; }
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
# When the slot's current VM was cloned (its meta snippet's mtime).
born=$clock
file_mtime() { [[ -e "$1" ]] && printf '%s\n' "$born"; }
# The slot's VM, powered off and waiting for its reclone.
dead_vm() {
    mkdir -p "$state/vm/9001"
    printf 'runner-1\n' > "$state/vm/9001/name"
    : > "$SNIPPETS_DIR/runner-9001-meta.yaml"
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
            printf 'name: %s\ncicustom: user=local:snippets/runner-%s-user-acme.yaml\n' "$(cat "$dir/name")" "$2"
            ;;
        status)
            [[ -d "$dir" ]] || return 2
            printf 'status: stopped\n'
            ;;
        destroy)
            printf 'destroy %s\n' "$2" >> "$actions"
            rm -rf "$dir"
            ;;
        list)
            printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
            [[ ! -d "$state/vm/9001" ]] || printf '%10s %-20s %-10s 8192 30.00 0\n' 9001 runner-1 stopped
            ;;
        *) return 1 ;;
    esac
}
pvesh() {
    [[ "$*" == "get /nodes/localhost/qemu --output-format json" ]] || return 1
    if [[ -d "$state/vm/9001" ]]; then
        printf '[{"vmid":9001,"name":"runner-1","status":"stopped","uptime":0}]\n'
    else
        printf '[]\n'
    fi
}
flock() { :; }
sleep() { :; }
logger() { printf '%s\n' "$*" >> "$state/logger"; }
require_root() { :; }
cleanup_runner_orphan_volumes() { :; }
# 1: the mint found the previous runner of this name still registered, so it
# never finished a job. 0: GitHub had removed it after its job.
mint_conflict=1
clone_runner() {
    printf 'clone %s\n' "$1" >> "$actions"
    CLONE_MINT_CONFLICT=$mint_conflict
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
# die_after <seconds>: the slot's VM powers off that long after its clone,
# and the hookscript's reclone handles it.
die_after() {
    clock=$((born + $1))
    dead_vm
    run reclone_main 9001
    [[ "$(clones)" -eq 0 ]] || born=$clock
}
fresh_slot() {
    rm -rf "$SLOT_STATE_DIR" "$state/vm/9001"
    : > "$state/logger"
    born=$clock
}

# Refused after a slow boot (125 s), and after the guest's network wait
# (about 210 s) on top of the boot.
for lifetime in 125 300; do
    fresh_slot
    die_after "$lifetime"
    [[ "$(cat "$actions")" == $'destroy 9001\nclone runner-1' ]] \
        || fail "${lifetime}s: the first death was not recloned: $(tr '\n' ' ' < "$actions")"
    die_after "$lifetime"
    [[ "$(clones)" -eq 1 ]] || fail "${lifetime}s: the second death was not recloned"
    die_after "$lifetime"
    [[ "$(cat "$actions")" == "destroy 9001" ]] \
        || fail "${lifetime}s: three deaths in a row without a job were recloned: $(tr '\n' ' ' < "$actions")"
    grep -q 'runner-1 died within 600s of its clone 3 times in a row; holding the slot for 30s' "$state/logger" \
        || fail "${lifetime}s: the hold was not logged"
done

# Short jobs end VMs just as soon, but their runners left GitHub, so the
# next mint has no conflict and the slot is never held.
fresh_slot
mint_conflict=0
for _ in 1 2 3 4 5; do
    die_after 125
    [[ "$(clones)" -eq 1 ]] || fail "a stream of short jobs held the slot"
done
mint_conflict=1

# A VM that outlived the window (it waited for a job) clears the count.
fresh_slot
die_after 300
die_after 300
die_after 900
die_after 300
die_after 300
[[ "$(clones)" -eq 1 ]] || fail "the count survived a VM that outlived the window"

# One hour of a slot whose guest is refused 125 s after every clone. The
# watcher refills a held slot on its 30 s ticks once the hold ends. Every
# third death holds the slot, twice as long each time.
fresh_slot
end=$((clock + 3600))
boots=0
vm_up=1
while (( clock < end )); do
    if (( vm_up )); then
        die_after 125
        if [[ "$(clones)" -eq 1 ]]; then
            boots=$((boots + 1))
        else
            vm_up=0
        fi
    else
        clock=$((clock + 30))
        run watch_main
        if [[ "$(clones)" -eq 1 ]]; then
            born=$clock
            boots=$((boots + 1))
            vm_up=1
        fi
    fi
done
(( boots <= 20 )) || fail "a slot refused 125 s after every clone booted $boots VMs in an hour"

printf 'pool2-death-window: ok\n'
