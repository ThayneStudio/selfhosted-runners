#!/usr/bin/env bash
# Extra runners from `runner create` must come back like slots. When repeated
# fast deaths held one, the template was being rebuilt or its re-clone
# failed, reclone.sh left the name empty "for the watcher", but the watcher
# filled only the RUNNER_COUNT slots, so the extra was gone for good. The
# watcher now fills each extra recorded in /var/lib/github-runners/extras,
# with the same hold, template gate and drain as a slot.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'ownership-extras: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# watch.sh and reclone.sh source these too; naming them lets shellcheck follow them.
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
# shellcheck source=../lib/watch.sh
source "$root/lib/watch.sh"
# shellcheck source=../lib/reclone.sh
source "$root/lib/reclone.sh"
fail() { printf 'ownership-extras: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

CONFIG_FILE=$state/github-runners.conf
ORG_CONFIG_DIR=$state/orgs
SNIPPETS_DIR=$state/snippets
POOL_DRAIN_FILE=$state/drain
POOL_ACTIVITY_LOCK_FILE=$state/pool.lock
SLOT_STATE_DIR=$state/slots
SLOT_LOCK_PREFIX=$state/slot
EXTRA_RUNNERS_FILE=$state/lib/extras
EXTRA_RUNNERS_LOCK_FILE=$state/extras.lock
mkdir -p "$ORG_CONFIG_DIR" "$SNIPPETS_DIR" "$state/vm"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-lvm\nTEMPLATE_ID=9000\n' > "$CONFIG_FILE"
org_conf() {
    printf 'GITHUB_ORG="%s"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="%s"\nRUNNER_COUNT="%s"\n' "$1" "$2" "$3" \
        > "$ORG_CONFIG_DIR/$1.conf"
}
org_conf acme runner 1
actions=$state/actions
flock() { :; }

# --- The record ---
extras() { tr '\n' ' ' < "$EXTRA_RUNNERS_FILE" 2>/dev/null || true; }
record_extra_runner build-box acme || fail "an extra runner was not recorded"
[[ "$(extras)" == "build-box acme " ]] || fail "unexpected record: $(extras)"
[[ -n "$(find "$EXTRA_RUNNERS_FILE" -perm 600)" ]] || fail "the record is not mode 600"
record_extra_runner gpu-1 acme
record_extra_runner build-box beta
[[ "$(extras)" == "gpu-1 acme build-box beta " ]] || fail "a name was recorded twice: $(extras)"
extra_runner_recorded build-box beta || fail "the re-recorded extra was not found"
if extra_runner_recorded build-box acme; then fail "the old org of a re-recorded extra was kept"; fi
[[ "$(extra_runner_org gpu-1)" == acme ]] || fail "extra_runner_org did not find gpu-1"
# A line that is not "<runner name> <org>" is ignored.
printf 'bad_name acme\nok-1 acme extra-field\nok-2\n../x acme\n' >> "$EXTRA_RUNNERS_FILE"
[[ "$(list_extra_runners | tr '\n' ' ')" == "gpu-1 acme build-box beta " ]] \
    || fail "a malformed line was listed: $(list_extra_runners | tr '\n' ' ')"
forget_extra_runners gpu-1 beta
[[ "$(extra_runner_org gpu-1)" == acme ]] || fail "another org's entry of the same name was forgotten"
forget_extra_runners gpu-1 acme
forget_extra_runners "" beta
[[ ! -s "$EXTRA_RUNNERS_FILE" ]] || fail "entries were left: $(extras)"
if forget_extra_runners "" ""; then fail "an empty name and org forgot every extra runner"; fi
record_extra_runner a-1 acme
record_extra_runner b-1 beta
forget_all_extra_runners
[[ ! -e "$EXTRA_RUNNERS_FILE" ]] || fail "forgetting all extra runners left $(extras)"
# A failed write keeps the old list.
record_extra_runner a-1 acme
mv() {
    if [[ "${*: -1}" == "$EXTRA_RUNNERS_FILE" ]]; then return 1; fi
    command mv "$@"
}
if record_extra_runner b-1 acme; then fail "a failed write reported success"; fi
unset -f mv
[[ "$(extras)" == "a-1 acme " ]] || fail "a failed write changed the list: $(extras)"
compgen -G "$state/lib/.extras.*" > /dev/null && fail "a failed write left its temporary file"
forget_all_extra_runners

# --- The pool ---
clock=1000000
date() {
    if [[ "${1:-}" == "+%s" ]]; then
        printf '%s\n' "$clock"
    else
        command date "$@"
    fi
}
# Config of VM 9000; a finished template unless a test says otherwise.
template_config=$'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local-lvm:base-9000-disk-0,size=30G'
# runner_vm <vmid> <name> <status> <org> <kind> [born]: a VM as clone_runner
# makes it, with its meta snippet written at born (default: now).
runner_vm() {
    local dir="$state/vm/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/name"
    printf '%s\n' "$3" > "$dir/status"
    printf 'cicustom: user=local:snippets/runner-%s-user-%s.yaml,meta=local:snippets/runner-%s-meta.yaml\n' "$1" "$4" "$1" > "$dir/cicustom"
    printf 'selfhosted-runners org=%s kind=%s vmid=%s\n' "$4" "$5" "$1" > "$dir/desc"
    printf '%s\n' "${6:-$clock}" > "$dir/born"
    : > "$SNIPPETS_DIR/runner-$1-meta.yaml"
}
field() { cat "$state/vm/$1/$2" 2>/dev/null || true; }
pvesh() {
    [[ "$*" == "get /nodes/localhost/qemu --output-format json" ]] || return 1
    local d id sep=""
    printf '['
    for d in "$state"/vm/*; do
        [[ -d "$d" ]] || continue
        id=${d##*/}
        printf '%s{"vmid":%s,"name":"%s","status":"%s","uptime":0}' "$sep" "$id" "$(field "$id" name)" "$(field "$id" status)"
        sep=","
    done
    printf ']\n'
}
qm() {
    local id="${2:-}"
    case "$1" in
        config)
            if [[ "$id" == 9000 ]]; then
                printf '%s\n' "$template_config"
                return 0
            fi
            [[ -d "$state/vm/$id" ]] || return 2
            printf 'name: %s\n' "$(field "$id" name)"
            [[ -z "$(field "$id" desc)" ]] || printf 'description: %s\n' "$(field "$id" desc)"
            [[ -z "$(field "$id" cicustom)" ]] || field "$id" cicustom
            ;;
        status)
            [[ -d "$state/vm/$id" ]] || return 2
            printf 'status: %s\n' "$(field "$id" status)"
            [[ "${3:-}" != --verbose ]] || printf 'uptime: 0\n'
            ;;
        destroy)
            printf 'destroy %s\n' "$id" >> "$actions"
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
sleep() { :; }
logger() { printf '%s\n' "$*" >> "$state/logger"; }
require_root() { :; }
cleanup_runner_orphan_volumes() { :; }
# The real clone_runner mints a JIT runner, then clones. Each guest here
# never connects, so the name is still registered at the next mint.
clone_rc=0
clone_runner() {
    printf 'clone %s %s\n' "$1" "$2" >> "$actions"
    CLONE_MINT_CONFLICT=1
    return "$clone_rc"
}

# run <function> [args]: one reclone or watcher run, with fresh actions.
run() {
    : > "$actions"
    set +e
    ( set -e; "$@" ) > "$state/out" 2>&1
    rc=$?
    set -e
}
tick() {
    run watch_main
    [[ $rc -eq 0 ]] || fail "watch_main failed (rc=$rc): $(tail -n 5 "$state/out")"
}
did() { grep -qx "$1" "$actions"; }
reset() {
    rm -rf "$state/vm" "$SNIPPETS_DIR" "$SLOT_STATE_DIR"
    mkdir -p "$state/vm" "$SNIPPETS_DIR"
    : > "$state/logger"
    forget_all_extra_runners
    template_config=$'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local-lvm:base-9000-disk-0,size=30G'
    clone_rc=0
    # Slot runner-1 is up, so only the extra runner is ever missing.
    runner_vm 9001 runner-1 running acme slot
}
# build-box powers off $1 seconds after its clone, and its reclone runs.
die_after() {
    runner_vm 9002 build-box stopped acme extra $((clock - $1))
    run reclone_main 9002
}

# Repeated fast deaths (its network is down, so the guest gives up) hold
# build-box. Once the hold ends, the watcher clones it again.
reset
record_extra_runner build-box acme
die_after 250
did 'clone build-box acme' || fail "the first fast death was not recloned: $(tr '\n' ' ' < "$actions")"
die_after 250
die_after 250
[[ "$(cat "$actions")" == "destroy 9002" ]] || fail "the third fast death was recloned: $(tr '\n' ' ' < "$actions")"
grep -q 'build-box is held for 30s after repeated failures; the watcher refills it after that' "$state/logger" \
    || fail "the hold was not logged: $(cat "$state/logger")"
clock=$((clock + 25))
tick
did 'clone build-box acme' && fail "the watcher filled a held extra runner"
clock=$((clock + 6))
tick
did 'clone build-box acme' || fail "the watcher did not fill the extra runner after its hold: $(cat "$state/out")"

# The template is being rebuilt when build-box finishes a job. The reclone
# leaves it empty; the watcher fills it once the template is converted.
reset
record_extra_runner build-box acme
template_config=$'name: ubuntu-cloud-template\nscsi0: local-lvm:vm-9000-disk-0,size=30G'
die_after 3600
[[ "$(cat "$actions")" == "destroy 9002" ]] || fail "a reclone cloned from an unfinished template: $(tr '\n' ' ' < "$actions")"
grep -q 'leaving build-box empty for the watcher' "$state/out" || fail "the skipped refill was not logged"
clock=$((clock + 30))
tick
did 'clone build-box acme' && fail "the watcher cloned from an unfinished template"
template_config=$'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local-lvm:base-9000-disk-0,size=30G'
clock=$((clock + 30))
tick
did 'clone build-box acme' || fail "the watcher did not fill the extra runner once the template was done"

# The reclone's clone fails: the watcher tries again when the hold ends.
reset
record_extra_runner build-box acme
clone_rc=1
die_after 3600
[[ $rc -ne 0 ]] || fail "a failed re-clone reported success"
clone_rc=0
clock=$((clock + 31))
tick
did 'clone build-box acme' || fail "the watcher did not retry an extra runner whose re-clone failed"

# Only a recorded extra runner is filled, and only while its org is
# configured. A configured slot of the same name is filled once, as a slot.
reset
org_conf beta ci 0
record_extra_runner old-box gone
record_extra_runner runner-1 beta
rm -rf "$state/vm/9001"
tick
[[ "$(sort "$actions")" == "clone runner-1 acme" ]] || fail "unexpected fills: $(tr '\n' ' ' < "$actions")"
grep -q 'Filling 1 missing slot' "$state/out" || fail "an extra runner that is not filled was queued: $(cat "$state/out")"
rm -f "$ORG_CONFIG_DIR/beta.conf"

# `runner destroy` ended the extra runner after the scan listed it: the
# worker checks the record again under the slot lock.
reset
record_extra_runner build-box acme
forget_extra_runners build-box acme
run fill_runner_slot build-box acme extra
[[ ! -s "$actions" ]] || fail "a worker filled an extra runner that was no longer recorded"

# A retired name is no longer filled as an extra runner: its org is gone, or
# another org now uses it as a slot.
reset
record_extra_runner old-box gone
runner_vm 9002 old-box stopped gone extra
run reclone_main 9002
[[ "$(cat "$actions")" == "destroy 9002" ]] || fail "a removed org's extra runner was cloned again"
if extra_runner_org old-box > /dev/null; then fail "a removed org's extra runner stayed recorded"; fi
reset
org_conf beta runner-x 2
record_extra_runner runner-x-2 acme
runner_vm 9002 runner-x-2 stopped acme extra
run reclone_main 9002
grep -q 'not re-cloning runner-x-2: org beta now uses runner-x-2 as a slot' "$state/out" \
    || fail "the extra runner was not retired: $(cat "$state/out")"
if extra_runner_org runner-x-2 > /dev/null; then fail "an extra runner that is now another org's slot stayed recorded"; fi
rm -f "$ORG_CONFIG_DIR/beta.conf"

# A clone of a recorded extra runner cut off before its snippets is
# reclaimed like a slot's, and the name filled again. A VM of that name
# without this tool's marks is reported and left alone.
reset
record_extra_runner build-box acme
mkdir -p "$state/vm/9002"
printf 'build-box\n' > "$state/vm/9002/name"
printf 'stopped\n' > "$state/vm/9002/status"
printf 'selfhosted-runners org=acme kind=extra vmid=9002\n' > "$state/vm/9002/desc"
tick
clock=$((clock + 61))
tick
did 'destroy 9002' || fail "a cut-off clone of an extra runner was not reclaimed: $(cat "$state/out")"
did 'clone build-box acme' || fail "the extra runner was not filled after its cut-off clone"
reset
record_extra_runner build-box acme
mkdir -p "$state/vm/9002"
printf 'build-box\n' > "$state/vm/9002/name"
printf 'stopped\n' > "$state/vm/9002/status"
tick
clock=$((clock + 61))
tick
[[ ! -s "$actions" ]] || fail "a VM without this tool's marks was touched: $(tr '\n' ' ' < "$actions")"
grep -q 'build-box (VMID 9002) is stopped but carries no selfhosted-runners snippet or marker' "$state/out" \
    || fail "a VM holding an extra runner's name was not reported"

printf 'ownership-extras: ok\n'
