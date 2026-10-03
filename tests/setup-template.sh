#!/usr/bin/env bash
# Setup's template step. Only a finished template is used as it is, and any
# other VM at the Template VM ID is refused. A new Template VM ID is baked
# while the saved template keeps serving clones, and TEMPLATE_ID moves only
# once the new VM is a finished template. The bake's EXIT trap destroys a
# partial VM even when the SSH tty is gone.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup-template: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'setup-template: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
actions=$state/actions
: > "$actions"
CONFIG_FILE=$state/github-runners.conf
ORG_CONFIG_DIR=$state/github-runners.d
STATE_DIR=$state/lib
RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
BAKED_VERSION_FILE=$STATE_DIR/baked-runner-version
REBAKE_LOCK_FILE=$state/rebake.lock

# The saved answers write_infra_config needs besides TEMPLATE_ID.
NETWORK_BRIDGE=vmbr0 VLAN_TAG="" VM_STORAGE=local-zfs MIN_VMID=9001 BALLOON=0
DNS_SERVERS="1.1.1.1 8.8.8.8" DOCKER_MIRROR_URL=""

converted() {
    printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1' "$1" "$1"
}
baking() {
    printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:vm-%s-disk-0,size=30G' "$1" "$1"
}
# Proxmox writes the flag before it converts the disk.
flagged() { printf '%s\ntemplate: 1' "$(baking "$1")"; }

declare -A vm_config=()
guest_ids=""
hup_on_stop=0
qm() {
    case "$1" in
        config)
            [[ -n "${vm_config[$2]+set}" ]] || return 2
            printf '%s\n' "${vm_config[$2]}"
            ;;
        stop|destroy)
            printf '%s\n' "$*" >> "$actions"
            # The SIGHUP the kernel sends again when the login shell exits.
            if [[ "$1" == stop && "$hup_on_stop" == 1 ]]; then
                kill -HUP "$BASHPID"
            fi
            ;;
        *) return 1 ;;
    esac
}
# A container or a VM on another node: no qemu config on this node.
vmid_in_use() { [[ " $guest_ids " == *" $1 "* ]]; }
conf_template_id() { sed -n 's/^TEMPLATE_ID=//p' "$CONFIG_FILE"; }

# --- Which Template VM ID answers are used, baked, or refused ---
SETUP_PREFILLS=([TEMPLATE_ID]=9000)
vm_config[9000]=$(converted 9000)
TEMPLATE_ID=9000
plan_template || fail "the saved finished template was refused"
[[ "$TEMPLATE_READY" == 1 && -z "$LIVE_TEMPLATE_ID" ]] || fail "a finished template was not used as it is"

TEMPLATE_ID=9100
plan_template || fail "a free Template VM ID was refused"
[[ "$TEMPLATE_READY" == 0 ]] || fail "a free Template VM ID was not baked"
[[ "$LIVE_TEMPLATE_ID" == 9000 ]] || fail "a new Template VM ID did not keep the saved template serving clones"

vm_config[9100]=$(baking 9100)
if plan_template 2> "$state/err"; then
    fail "a bake VM that never reached qm template was accepted as the template"
fi
grep -qF 'qm stop 9100; qm destroy 9100' "$state/err" || fail "the refusal did not say how to remove the leftover bake"
if grep -qF -- '--purge' "$state/err"; then
    fail "the refusal suggests --purge, which edits backup jobs"
fi

vm_config[9100]=$(flagged 9100)
if plan_template 2>/dev/null; then
    fail "a template whose disk was never converted was accepted"
fi

vm_config[9100]=$'name: runner-3\nscsi0: local-zfs:vm-9100-disk-0,size=30G'
if plan_template 2> "$state/err"; then
    fail "a runner VM was accepted as the template"
fi
grep -qF 'runner-3' "$state/err" || fail "the refusal did not name the VM it found"

unset 'vm_config[9100]'
guest_ids=9100
if plan_template 2>/dev/null; then
    fail "a VM ID that belongs to another guest was accepted"
fi
guest_ids=""

# Only a finished saved template keeps serving during the bake.
vm_config[9000]=$(flagged 9000)
plan_template || fail "a free Template VM ID was refused"
[[ -z "$LIVE_TEMPLATE_ID" ]] || fail "an unfinished saved template was kept serving clones"
SETUP_PREFILLS=()
vm_config[9000]=$(converted 9000)
plan_template || fail "a fresh install was refused"
[[ -z "$LIVE_TEMPLATE_ID" ]] || fail "a fresh install invented a live template"

# --- The config keeps the live template until the new one is finished ---
TEMPLATE_ID=9100
LIVE_TEMPLATE_ID=9000
write_infra_config
[[ "$(conf_template_id)" == 9000 ]] || fail "the config named the new template before it was baked"
LIVE_TEMPLATE_ID=""
write_infra_config
[[ "$(conf_template_id)" == 9100 ]] || fail "a fresh install did not save its Template VM ID"

lock_busy=0
flock() { [[ "$lock_busy" == 0 ]]; }
prepare_cloud_image() { :; }
create_bake_vm() {
    printf 'create %s\n' "$1" >> "$actions"
    vm_config[$1]=$(baking "$1")
}
bake_result=converted
bake_and_publish_vm() {
    printf 'bake %s with TEMPLATE_ID=%s\n' "$1" "$(conf_template_id)" >> "$actions"
    case "$bake_result" in
        failed) return 1 ;;
        flagged) vm_config[$1]=$(flagged "$1") ;;
        converted) vm_config[$1]=$(converted "$1") ;;
    esac
    BAKE_RUNNER_VERSION=2.330.0
}
commit_baked_version() {
    printf 'commit %s %s with TEMPLATE_ID=%s\n' "$1" "$2" "$(conf_template_id)" >> "$actions"
}
start_bake() {
    : > "$actions"
    rm -rf "$STATE_DIR"
    unset 'vm_config[9100]'
    LIVE_TEMPLATE_ID=$1
    write_infra_config
}

start_bake 9000
( bake_setup_template ) 2> "$state/log" || fail "a successful bake failed: $(cat "$state/log")"
grep -qxF 'bake 9100 with TEMPLATE_ID=9000' "$actions" || fail "TEMPLATE_ID named the VM that was still baking"
[[ "$(conf_template_id)" == 9100 ]] || fail "TEMPLATE_ID did not move to the finished template"
grep -qxF 'commit 2.330.0 9100 with TEMPLATE_ID=9100' "$actions" || fail "the runner version was not recorded for the new template"
[[ "$(cat "$RETIRED_TEMPLATES_FILE")" == 9000 ]] || fail "the replaced template was not queued for retirement"
if grep -qE '^(stop|destroy) ' "$actions"; then
    fail "the finished template was destroyed"
fi

for bake_result in failed flagged; do
    start_bake 9000
    if ( bake_setup_template ) 2>/dev/null; then
        fail "a $bake_result bake reported success"
    fi
    [[ "$(conf_template_id)" == 9000 ]] || fail "a $bake_result bake moved TEMPLATE_ID off the live template"
    grep -qxF 'destroy 9100' "$actions" || fail "the $bake_result bake VM was not destroyed"
    [[ ! -e "$RETIRED_TEMPLATES_FILE" ]] || fail "a $bake_result bake retired the live template"
    if grep -q '^commit ' "$actions"; then
        fail "a $bake_result bake recorded a runner version"
    fi
done
bake_result=converted

start_bake ""
( bake_setup_template ) 2>/dev/null || fail "a fresh bake failed"
[[ "$(conf_template_id)" == 9100 ]] || fail "a fresh bake changed TEMPLATE_ID"
[[ ! -e "$RETIRED_TEMPLATES_FILE" ]] || fail "a fresh bake retired a template"

start_bake 9000
lock_busy=1
if ( bake_setup_template ) 2>/dev/null; then
    fail "setup baked while a rebake held its lock"
fi
if grep -q '^create ' "$actions"; then
    fail "setup created a bake VM while a rebake held its lock"
fi
lock_busy=0

# --- The EXIT trap destroys a partial VM, also with a dead tty ---
TEMPLATE_ID=9100
expect_destroyed=$'stop 9100 --timeout 30\ndestroy 9100'
vm_config[9100]=$(baking 9100)
: > "$actions"
# A closed stderr fails every log write, as EIO on a hung-up SSH tty does.
( trap cleanup_bake EXIT; false ) 2>&- || true
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "errexit with a dead tty left the partial bake VM"
: > "$actions"
{ ( trap cleanup_bake EXIT; kill -HUP "$BASHPID"; sleep 5 ) 2>&-; } 2>/dev/null || true
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "SIGHUP with a dead tty left the partial bake VM"
: > "$actions"
hup_on_stop=1
{ ( trap cleanup_bake EXIT; false ) 2>&-; } 2>/dev/null || true
hup_on_stop=0
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "a second SIGHUP during qm stop skipped qm destroy"
# stderr piped to a reader that died with the session (runner setup | tee).
mkfifo "$state/fifo"
exec {fifo_rw}<>"$state/fifo"
exec {broken_pipe}>"$state/fifo"
exec {fifo_rw}<&-
: > "$actions"
{ ( trap cleanup_bake EXIT; false ) 2>&"$broken_pipe"; } 2>/dev/null || true
exec {broken_pipe}>&-
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "SIGPIPE on a log write left the partial bake VM"

vm_config[9100]=$(flagged 9100)
: > "$actions"
( trap cleanup_bake EXIT; false ) 2>/dev/null || true
[[ "$(cat "$actions")" == "$expect_destroyed" ]] || fail "a VM with template: 1 but an unconverted disk was kept"

for kept in converted foreign unreadable; do
    case "$kept" in
        converted) vm_config[9100]=$(converted 9100) ;;
        foreign) vm_config[9100]=$'name: runner-3\nscsi0: local-zfs:vm-9100-disk-0,size=30G' ;;
        unreadable) unset 'vm_config[9100]' ;;
    esac
    : > "$actions"
    ( trap cleanup_bake EXIT; false ) 2>/dev/null || true
    [[ ! -s "$actions" ]] || fail "cleanup touched a $kept VM"
done

# --- The wizard uses these steps, in this order ---
main=$(awk '/^require_root "setup"$/ { seen = 1 } seen' "$root/lib/setup.sh")
line_of() { awk -v text="$1" 'index($0, text) { print NR; exit }' <<< "$main"; }
plan=$(line_of 'if ! plan_template; then')
proceed=$(line_of 'Proceed?')
write=$(line_of 'write_infra_config')
bake=$(line_of 'bake_setup_template')
[[ -n "$plan" && -n "$proceed" && -n "$write" && -n "$bake" ]] || fail "setup.sh no longer runs its template steps"
(( plan < proceed && write < bake )) || fail "setup.sh runs its template steps out of order"
if grep -qF 'qm status' <<< "$main"; then
    fail "setup decides about the template with qm status again"
fi

printf 'setup-template: ok\n'
