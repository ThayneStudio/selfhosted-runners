#!/usr/bin/env bash
# The watcher must reclaim a runner VM that nothing else will recycle: one
# left stopped (host crash or reboot, pool drain, killed reclone, a clone cut
# off before --cicustom), one still running far past its lifetime, and one
# started again after its single boot. It must leave alone anything locked,
# held by another process, or not carrying this tool's marks.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool-reclaim: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# watch.sh sources these too; naming them lets shellcheck follow them.
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
# shellcheck source=../lib/watch.sh
source "$root/lib/watch.sh"
fail() { printf 'pool-reclaim: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

CONFIG_FILE=$state/github-runners.conf
ORG_CONFIG_DIR=$state/orgs
SNIPPETS_DIR=$state/snippets
POOL_DRAIN_FILE=$state/drain
LEGACY_POOL_DRAIN_FILE=$state/legacy-drain
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
SLOT_STATE_DIR=$state/slots
SLOT_LOCK_PREFIX=$state/slot
mkdir -p "$ORG_CONFIG_DIR" "$SNIPPETS_DIR" "$state/vm"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=9000\n' > "$CONFIG_FILE"
printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="runner"\nRUNNER_COUNT="2"\n' > "$ORG_CONFIG_DIR/acme.conf"
actions=$state/actions

clock=2000000
date() {
    if [[ "${1:-}" == "+%s" ]]; then
        printf '%s\n' "$clock"
    else
        command date "$@"
    fi
}

# vm <vmid> <name> <status> [key=value ...]: uptime, lock, org (cicustom),
# marker (clone-time description), meta=1 (meta snippet), born (its mtime,
# by default the clock when vm runs).
vm() {
    local dir="$state/vm/$1" kv
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/name"
    printf '%s\n' "$3" > "$dir/status"
    printf '0\n' > "$dir/uptime"
    printf '%s\n' "$clock" > "$dir/born"
    shift 3
    for kv in "$@"; do
        if [[ "$kv" == meta=1 ]]; then
            : > "$SNIPPETS_DIR/runner-${dir##*/}-meta.yaml"
        else
            printf '%s\n' "${kv#*=}" > "$dir/${kv%%=*}"
        fi
    done
}
field() { cat "$state/vm/$1/$2" 2>/dev/null || true; }
gone() { [[ ! -d "$state/vm/$1" ]]; }
pvesh() {
    [[ "$*" == "get /nodes/localhost/qemu --output-format json" ]] || return 1
    local d id sep=""
    printf '['
    for d in "$state"/vm/*; do
        [[ -d "$d" ]] || continue
        id=${d##*/}
        printf '%s{"vmid":%s,"name":"%s","status":"%s","uptime":%s' "$sep" "$id" "$(field "$id" name)" \
            "$(field "$id" status)" "$(field "$id" uptime)"
        [[ -z "$(field "$id" lock)" ]] || printf ',"lock":"%s"' "$(field "$id" lock)"
        [[ -z "$(field "$id" template)" ]] || printf ',"template":1'
        printf '}'
        sep=","
    done
    printf ']\n'
}
qm() {
    local id="${2:-}"
    case "$1" in
        config)
            if [[ "$id" == 9000 ]]; then
                printf 'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local-zfs:base-9000-disk-0,size=30G\n'
                return 0
            fi
            gone "$id" && return 2
            printf 'name: %s\n' "$(field "$id" name)"
            [[ -z "$(field "$id" marker)" ]] || printf 'description: %s\n' "$(field "$id" marker)"
            [[ -z "$(field "$id" org)" ]] || printf 'cicustom: user=local:snippets/runner-%s-user-%s.yaml,meta=local:snippets/runner-%s-meta.yaml\n' \
                "$id" "$(field "$id" org)" "$id"
            [[ -z "$(field "$id" lock)" ]] || printf 'lock: %s\n' "$(field "$id" lock)"
            [[ -z "$(field "$id" template)" ]] || printf 'template: 1\n'
            ;;
        status)
            gone "$id" && return 2
            printf 'status: %s\nuptime: %s\n' "$(field "$id" status)" "$(field "$id" uptime)"
            ;;
        stop)
            printf 'stop %s\n' "$id" >> "$actions"
            printf 'stopped\n' > "$state/vm/$id/status"
            printf '0\n' > "$state/vm/$id/uptime"
            ;;
        destroy)
            printf 'destroy %s\n' "${*:2}" >> "$actions"
            if [[ "$(field "$id" status)" != stopped ]]; then
                printf 'VM %s is running - destroy failed\n' "$id" >&2
                return 2
            fi
            rm -rf "$state/vm/$id"
            ;;
        list)
            printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
            local d
            for d in "$state"/vm/*; do
                [[ -d "$d" ]] || continue
                printf '%10s %-20s %-10s 8192 30.00 0\n' "${d##*/}" "$(field "${d##*/}" name)" "$(field "${d##*/}" status)"
            done
            ;;
        *) return 1 ;;
    esac
}
file_mtime() {
    local id="${1##*/runner-}"
    [[ -e "$1" ]] || return 1
    id=${id%-meta.yaml}
    if [[ -n "$(field "$id" born)" ]]; then
        field "$id" born
    else
        printf '%s\n' "$clock"
    fi
}
# Another process (a reclone) holds the slot lock of $busy_lock. Workers run
# one at a time in that case, so the last slot lock opened is theirs.
busy_lock=""
slot_lock_file() {
    printf '%s\n' "$1" > "$state/last-slot-lock"
    printf '%s/slot-%s.lock\n' "$state" "$1"
}
flock() {
    if [[ -n "$busy_lock" && "$*" == "-n 200" && "$(cat "$state/last-slot-lock")" == "$busy_lock" ]]; then
        return 1
    fi
}
sleep() { :; }
logger() { :; }
require_root() { :; }
cleanup_runner_orphan_volumes() { :; }
clone_runner() { printf 'clone %s %s\n' "$1" "$2" >> "$actions"; }

tick() {
    : > "$actions"
    set +e
    ( set -e; watch_main ) > "$state/out" 2>&1
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "watch_main failed (rc=$rc): $(tail -n 5 "$state/out")"
}
reset_vms() {
    rm -rf "$state/vm" "$SNIPPETS_DIR" "$SLOT_STATE_DIR"
    mkdir -p "$state/vm" "$SNIPPETS_DIR"
}
did() { grep -qx "$1" "$actions"; }
# A runner on its first boot, so the slot it holds is neither missing nor dead.
healthy() { vm "$1" "$2" running org=acme meta=1 uptime=100 born=$((clock - 100)); }
did_nothing() { [[ ! -s "$actions" ]] || fail "$1: $(tr '\n' ' ' < "$actions")"; }

# R1-2: after a power loss every runner is stopped and keeps its slot name.
# Nothing fires post-stop, so the watcher reclaims them after a grace period
# that lets an in-flight reclone go first.
vm 9001 runner-1 stopped org=acme marker='selfhosted-runners org=acme kind=slot' meta=1
vm 9002 runner-2 stopped org=acme marker='selfhosted-runners org=acme kind=slot' meta=1
vm 9000 ubuntu-cloud-template stopped template=1
tick
did_nothing "stopped VMs were reclaimed without a grace period"
clock=$((clock + 30))
tick
did_nothing "stopped VMs were reclaimed inside the grace period"
clock=$((clock + 31))
tick
for id in 9001 9002; do
    did "destroy $id" || fail "stopped VM $id was not reclaimed: $(tr '\n' ' ' < "$actions")"
done
did "clone runner-1 acme" || fail "slot runner-1 was not refilled"
did "clone runner-2 acme" || fail "slot runner-2 was not refilled"
grep -q 'destroy.*--purge' "$actions" && fail "the reclaim passed --purge"
[[ -d "$state/vm/9000" ]] || fail "the template was touched"

# A reclone already holds the slot: the watcher keeps out of its way.
reset_vms
healthy 9002 runner-2
vm 9001 runner-1 stopped org=acme meta=1
tick
clock=$((clock + 61))
busy_lock=runner-1
tick
busy_lock=""
did_nothing "a VM whose slot lock was held was reclaimed"

# A stop-mode backup holds the lock: wait, then reclaim once it is gone.
reset_vms
healthy 9002 runner-2
vm 9001 runner-1 stopped org=acme meta=1 lock=backup
tick
grep -q 'runner-1 (VMID 9001) is stopped and locked (backup)' "$state/out" || fail "a locked stopped VM was not reported"
clock=$((clock + 120))
tick
did_nothing "a locked VM was reclaimed"
grep -q 'stopped and locked' "$state/out" && fail "a locked VM was reported on every tick"
# The worker checks again: vzdump can lock the VM after the scan.
: > "$actions"
( reclaim_runner_vm 9001 runner-1 stopped ) > "$state/out" 2>&1 || true
did_nothing "a worker reclaimed a VM that was locked after the scan"
printf '\n' > "$state/vm/9001/lock"
tick
did "destroy 9001" || fail "the VM was not reclaimed once its lock was gone"

# R2-4: a clone killed between qm clone and --cicustom has only its name and
# the clone-time marker, which names its VMID.
reset_vms
healthy 9002 runner-2
vm 9001 runner-1 stopped marker='selfhosted-runners org=acme kind=slot vmid=9001'
tick
clock=$((clock + 61))
tick
did "destroy 9001" || fail "a half-configured clone was not reclaimed: $(tr '\n' ' ' < "$actions")"
did "clone runner-1 acme" || fail "the slot of a half-configured clone was not refilled"

# A stopped VM that only shares a slot name is not ours: report it, keep it.
reset_vms
healthy 9002 runner-2
vm 9001 runner-1 stopped
tick
clock=$((clock + 61))
tick
did_nothing "a VM without this tool's marks was touched"
grep -q 'runner-1 (VMID 9001) is stopped but carries no selfhosted-runners snippet or marker' "$state/out" \
    || fail "an unmarked VM holding a slot name was not reported"

# A VM that reused the VMID of a runner removed with plain `qm destroy`
# (snippets left behind) is not ours, and holds no slot: not even reported.
reset_vms
healthy 9001 runner-1
healthy 9002 runner-2
vm 9003 builder running meta=1 uptime=300 born=$((clock - 7200))
vm 9004 scratch stopped meta=1
tick
clock=$((clock + 61))
tick
did_nothing "a foreign VM with a leftover runner snippet was touched"
grep -q 'carries no selfhosted-runners' "$state/out" && fail "a foreign VM outside the slot names was reported"

# Surplus slots that died are destroyed and not refilled.
reset_vms
vm 9003 runner-3 stopped org=acme marker='selfhosted-runners org=acme kind=slot' meta=1
vm 9001 runner-1 running org=acme meta=1 uptime=100
vm 9002 runner-2 running org=acme meta=1 uptime=100
tick
clock=$((clock + 61))
tick
did "destroy 9003" || fail "a dead surplus slot was not reclaimed"
grep -q '^clone' "$actions" && fail "a surplus slot was refilled"

# R1-10: a VM still running long after the guest's own shutdown.
reset_vms
vm 9001 runner-1 running org=acme meta=1 uptime=$((12 * 3600)) born=$((clock - 12 * 3600))
vm 9002 runner-2 running org=acme meta=1 uptime=$((13 * 3600)) born=$((clock - 13 * 3600))
tick
[[ "$(cat "$actions")" == $'stop 9002\ndestroy 9002\nclone runner-2 acme' ]] \
    || fail "an overdue VM was not stopped and recycled: $(tr '\n' ' ' < "$actions")"
[[ -d "$state/vm/9001" ]] || fail "a VM inside its lifetime was reclaimed"

# R2-3: vzdump started the VM again after a stop-mode backup (or `qm reboot`):
# it is running with no runner. It is reclaimed once vzdump unlocks it.
reset_vms
vm 9001 runner-1 running org=acme meta=1 uptime=300 born=$((clock - 7200)) lock=backup
vm 9002 runner-2 running org=acme meta=1 uptime=7195 born=$((clock - 7200))
tick
did_nothing "a VM was reclaimed while vzdump held it"
grep -q 'Reclaiming' "$state/out" && fail "a VM that vzdump held was scheduled for reclaim"
printf '\n' > "$state/vm/9001/lock"
tick
[[ "$(cat "$actions")" == $'stop 9001\ndestroy 9001\nclone runner-1 acme' ]] \
    || fail "a restarted VM was not recycled: $(tr '\n' ' ' < "$actions")"
[[ -d "$state/vm/9002" ]] || fail "a VM on its first boot was reclaimed"

# Nothing is reclaimed during a pool drain.
reset_vms
healthy 9002 runner-2
vm 9001 runner-1 stopped org=acme meta=1
tick
clock=$((clock + 61))
: > "$POOL_DRAIN_FILE"
tick
did_nothing "a VM was reclaimed during a pool drain"
# A drain can also start while a worker is already on its way.
( reclaim_runner_vm 9001 runner-1 stopped ) > "$state/out" 2>&1 || true
did_nothing "a worker reclaimed a VM after the pool drain started"
rm -f "$POOL_DRAIN_FILE"

printf 'pool-reclaim: ok\n'
