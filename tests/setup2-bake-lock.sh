#!/usr/bin/env bash
# Setup bakes under the rebake lock. It must keep that lock until TEMPLATE_ID,
# the retired list and the baked-version record name the new template, as
# perform_bake does. Released earlier, a daily rebake could take it in that
# tail and act on the old TEMPLATE_ID or record: it baked again, then left
# setup's template untracked or destroyed it and overwrote the record.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup2-bake-lock: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'setup2-bake-lock: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
CONFIG_FILE=$state/github-runners.conf
ORG_CONFIG_DIR=$state/github-runners.d
STATE_DIR=$state/lib
RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
BAKED_VERSION_FILE=$STATE_DIR/baked-runner-version
PENDING_BAKE_FILE=$STATE_DIR/pending-bake
PENDING_VERSION_FILE=$STATE_DIR/pending-version
REBAKE_LOCK_FILE=$state/rebake.lock
NETWORK_BRIDGE=vmbr0 VLAN_TAG="" VM_STORAGE=local-zfs MIN_VMID=9001 BALLOON=0
DNS_SERVERS="" DOCKER_MIRROR_URL=""

converted() {
    printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-%s-cloudinit,media=cdrom\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1' "$1" "$1"
}
mkdir -p "$state/vm"
qm() {
    [[ "$1" == config && -f "$state/vm/$2" ]] || return 2
    cat "$state/vm/$2"
}
# flock(1) locks fd 199 for as long as that fd stays open, so an open fd 199
# is the held lock. Another process's `flock -n` fails until it is closed.
exec 199>&-
flock() { [[ "$*" == "-n 199" ]]; }
lock_held() { { : >&199; } 2>/dev/null; }
held=$state/held
note() {
    if lock_held; then
        printf '%s: held\n' "$1" >> "$held"
    else
        printf '%s: released\n' "$1" >> "$held"
    fi
}
prepare_cloud_image() { :; }
create_bake_vm() { printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:vm-%s-disk-0\n' "$1" > "$state/vm/$1"; }
bake_and_publish_vm() {
    converted "$1" > "$state/vm/$1"
    BAKE_RUNNER_VERSION=2.330.0
}
# The real config and retired-list writers run, wrapped to note the lock.
eval "real_$(declare -f set_conf_assignment)"
eval "real_$(declare -f remember_retired_template)"
set_conf_assignment() { note "switch TEMPLATE_ID to $3"; real_set_conf_assignment "$@"; }
remember_retired_template() { note "retire $1"; real_remember_retired_template "$@"; }
commit_baked_version() { note "record version $1 for $2"; }
conf_template_id() { sed -n 's/^TEMPLATE_ID=//p' "$CONFIG_FILE"; }

bake() {
    : > "$held"
    rm -rf "$STATE_DIR" "$state/vm/9100"
    LIVE_TEMPLATE_ID=$1
    TEMPLATE_ID=9100
    write_infra_config
    (
        bake_setup_template
        note "after bake_setup_template"
    ) 2> "$state/log" || fail "the bake failed: $(cat "$state/log")"
}

# A new Template VM ID baked beside the live template 9000.
converted 9000 > "$state/vm/9000"
bake 9000
expected=$'switch TEMPLATE_ID to 9100: held\nretire 9000: held\nrecord version 2.330.0 for 9100: held\nafter bake_setup_template: released'
[[ "$(cat "$held")" == "$expected" ]] ||
    fail "setup let a rebake run before it finished publishing template 9100: $(tr '\n' ';' < "$held")"
[[ "$(conf_template_id)" == 9100 ]] || fail "TEMPLATE_ID did not move to the new template"
[[ "$(cat "$RETIRED_TEMPLATES_FILE")" == 9000 ]] || fail "the replaced template was not queued for retirement"

# A first bake has no live template, but it still records the version under the lock.
bake ""
expected=$'record version 2.330.0 for 9100: held\nafter bake_setup_template: released'
[[ "$(cat "$held")" == "$expected" ]] ||
    fail "a first bake recorded its version without the rebake lock: $(tr '\n' ';' < "$held")"

printf 'setup2-bake-lock: ok\n'
