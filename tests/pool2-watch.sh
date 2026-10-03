#!/usr/bin/env bash
# How the watcher times and recycles dead runner VMs: a stopped VM gets one
# grace period per clone, even when its re-clone reuses the VMID and name.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool2-watch: bash 4+ is required\n' >&2
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
fail() { printf 'pool2-watch: %s\n' "$1" >&2; exit 1; }
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
marker='selfhosted-runners org=acme kind=slot'

clock=2000000
date() {
    if [[ "${1:-}" == "+%s" ]]; then
        printf '%s\n' "$clock"
    else
        command date "$@"
    fi
}

# vm <vmid> <name> <status> [key=value ...]: uptime, org (cicustom), marker
# (clone-time description), born (when it was cloned: its meta snippet's
# mtime), undeletable (qm destroy fails). Every VM gets a meta snippet.
vm() {
    local dir="$state/vm/$1" kv
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/name"
    printf '%s\n' "$3" > "$dir/status"
    printf '0\n' > "$dir/uptime"
    printf '%s\n' "$clock" > "$dir/born"
    : > "$SNIPPETS_DIR/runner-$1-meta.yaml"
    shift 3
    for kv in "$@"; do
        printf '%s\n' "${kv#*=}" > "$dir/${kv%%=*}"
    done
}
# A runner VM of slot $2 at VMID $1, cloned $3 seconds ago.
runner_vm() { vm "$1" "$2" stopped org=acme marker="$marker" born=$((clock - $3)); }
field() { cat "$state/vm/$1/$2" 2>/dev/null || true; }
gone() { [[ ! -d "$state/vm/$1" ]]; }
pvesh() {
    [[ "$*" == "get /nodes/localhost/qemu --output-format json" ]] || return 1
    local d id sep=""
    printf '['
    for d in "$state"/vm/*; do
        [[ -d "$d" ]] || continue
        id=${d##*/}
        printf '%s{"vmid":%s,"name":"%s","status":"%s","uptime":%s}' "$sep" "$id" "$(field "$id" name)" \
            "$(field "$id" status)" "$(field "$id" uptime)"
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
            [[ -z "$(field "$id" org)" ]] \
                || printf 'cicustom: user=local:snippets/runner-%s-user-%s.yaml\n' "$id" "$(field "$id" org)"
            ;;
        status)
            gone "$id" && return 2
            printf 'status: %s\nuptime: %s\n' "$(field "$id" status)" "$(field "$id" uptime)"
            ;;
        stop)
            printf 'stop %s\n' "$id" >> "$actions"
            printf 'stopped\n' > "$state/vm/$id/status"
            ;;
        destroy)
            printf 'destroy %s\n' "$id" >> "$actions"
            [[ -z "$(field "$id" undeletable)" ]] || return 2
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
    field "${id%-meta.yaml}" born
}
flock() { :; }
sleep() { :; }
logger() { printf '%s\n' "$*" >> "$state/logger"; }
require_root() { :; }
cleanup_runner_orphan_volumes() { :; }
clone_rc=0
clone_runner() {
    printf 'clone %s %s\n' "$1" "$2" >> "$actions"
    CLONE_MINT_CONFLICT=1
    return "$clone_rc"
}

tick() {
    : > "$actions"
    set +e
    ( set -e; watch_main ) > "$state/out" 2>&1
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "watch_main failed (rc=$rc): $(tail -n 5 "$state/out")"
}
reset() {
    rm -rf "$state/vm" "$SNIPPETS_DIR" "$SLOT_STATE_DIR"
    mkdir -p "$state/vm" "$SNIPPETS_DIR"
    : > "$state/logger"
}
did() { grep -qx "$1" "$actions"; }
did_nothing() { [[ ! -s "$actions" ]] || fail "$1: $(tr '\n' ' ' < "$actions")"; }

# N13: the watcher saw runner-1 stopped. Its reclone then destroyed it and
# cloned runner-1 again at the same VMID, and the new VM died at once. It
# gets its own grace period, so its own reclone (which counts the death)
# goes first.
reset
runner_vm 9001 runner-1 30
tick
did_nothing "a stopped VM was reclaimed without a grace period"
clock=$((clock + 61))
# Cloned 20 s after that sighting.
runner_vm 9001 runner-1 41
tick
did_nothing "a re-clone at the same VMID was reclaimed on its predecessor's grace period"
grep -qx "9001 runner-1 $clock" "$SLOT_STATE_DIR/watch-stopped" \
    || fail "the re-clone kept its predecessor's stopped time: $(cat "$SLOT_STATE_DIR/watch-stopped")"
clock=$((clock + 30))
tick
did_nothing "a re-clone was reclaimed inside its own grace period"
clock=$((clock + 31))
tick
did "destroy 9001" || fail "the re-clone was not reclaimed after its own grace period"

# The same VM stays stopped across ticks: its grace runs from the first
# sighting and is not restarted.
reset
runner_vm 9001 runner-1 300
tick
clock=$((clock + 30))
tick
did_nothing "a stopped VM was reclaimed inside its grace period"
clock=$((clock + 31))
tick
did "destroy 9001" || fail "a stopped VM was not reclaimed after its grace period"

# N14: after a host reboot every runner VM is stopped. The first tick records
# them, then chrony steps the clock back two hours (an RTC kept in local
# time). They are reclaimed a grace period after the step, not once the
# clock has caught up. The meta snippet, written before the step, is now in
# the future and must not restart the grace on every tick either.
reset
runner_vm 9001 runner-1 100
tick
clock=$((clock - 7200))
tick
did_nothing "a stopped VM was reclaimed at once after the clock was stepped back"
clock=$((clock + 61))
tick
did "destroy 9001" || fail "a clock stepped back stalled the reclaim of a stopped VM"

# A failure hold set before the step must not keep the slot empty for the
# size of the step on top of the hold.
reset
clone_rc=1
tick
did "clone runner-1 acme" || fail "the missing slot was not filled"
clone_rc=0
clock=$((clock - 7200))
retried=0
for _ in $(seq 0 "$((SLOT_BACKOFF_MAX / 30))"); do
    tick
    if did "clone runner-1 acme"; then
        retried=1
        break
    fi
    clock=$((clock + 30))
done
(( retried )) || fail "a hold set before the clock was stepped back kept the slot empty for 30 minutes"

# N12: nothing recycles the slot's VMs when they stop (the hookscript was
# missing at clone time, or systemd refused the reclone unit), and each one
# dies 30 s after its clone. The watcher's reclaims count those deaths as
# reclone.sh does, and the third in a row holds the slot.
reset
for n in 1 2 3; do
    runner_vm 9001 runner-1 30
    tick
    clock=$((clock + 61))
    tick
    did "destroy 9001" || fail "death $n: the stopped VM was not reclaimed"
    if (( n < 3 )) && ! did "clone runner-1 acme"; then
        fail "death $n: the slot was not refilled"
    fi
done
did "clone runner-1 acme" && fail "the slot was refilled after three fast deaths in a row"
grep -qF '[watch] runner-1 died within 600s of its clone 3 times in a row; holding the slot for 30s' "$state/logger" \
    || fail "the watcher's hold was not logged"
clock=$((clock + 25))
tick
did_nothing "a slot held by the watcher was refilled"
clock=$((clock + 6))
tick
did "clone runner-1 acme" || fail "the slot was not refilled after its hold"

# The VM died before the tick that first saw it stopped. Measured at the
# reclaim a grace period later, a VM that died 570 s after its clone would
# read as one that outlived the 600 s window.
reset
runner_vm 9001 runner-1 570
tick
clock=$((clock + 61))
tick
did "destroy 9001" || fail "a stopped VM was not reclaimed"
slot_state_load runner-1
[[ "$SLOT_RAPID" == 1 ]] || fail "a VM that died 570 s after its clone was not counted (rapid=$SLOT_RAPID)"

# A destroy that fails is retried on the next tick, and the death is
# counted once, when the VM is gone.
reset
runner_vm 9001 runner-1 30
printf '1\n' > "$state/vm/9001/undeletable"
tick
clock=$((clock + 61))
tick
did "destroy 9001" || fail "the stopped VM was not reclaimed"
grep -q 'Failed to destroy runner-1' "$state/out" || fail "the failed destroy was not reported"
rm -f "$state/vm/9001/undeletable"
clock=$((clock + 30))
tick
did "clone runner-1 acme" || fail "the slot was not refilled once the destroy succeeded"
slot_state_load runner-1
[[ "$SLOT_RAPID" == 1 ]] || fail "a death whose destroy was retried was counted $SLOT_RAPID times"

printf 'pool2-watch: ok\n'
