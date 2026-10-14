#!/usr/bin/env bash
# BAKE_TIMEOUT and BAKE_MIN_FREE_GIB in /etc/github-runners.conf apply to the
# daily rebake and to setup. An explicit environment value still wins. A bad
# conf value fails before a VM is created. setup keeps those lines, and any
# other line it does not prompt for, when it rewrites the file. The rebake
# unit does not impose a shorter start timeout than the script's own limit.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-conf-limits: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'bake-conf-limits: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # read by setup, rebake and bake functions
{
    CONFIG_FILE=$state/github-runners.conf
    ORG_CONFIG_DIR=$state/github-runners.d
    STATE_DIR=$state/lib
    PENDING_BAKE_FILE=$STATE_DIR/pending-bake
    PENDING_VERSION_FILE=$STATE_DIR/pending-version
    RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
    BAKED_VERSION_FILE=$STATE_DIR/baked-runner-version
    REBAKE_LOCK_FILE=$state/rebake.lock
    REBAKE_UNIT_FILE=$state/github-runner-rebake.service
    REBAKE_LOG_FILE=$state/github-runner-rebake.log
    INSTALL_DIR=$root
    SNIPPETS_DIR=$state/snippets
    NETWORK_BRIDGE=vmbr0
    VLAN_TAG=
    VM_STORAGE=local-zfs
    TEMPLATE_ID=9100
    MIN_VMID=9001
    BALLOON=0
    DNS_SERVERS='1.1.1.1 8.8.8.8'
    DOCKER_MIRROR_URL='http://10.20.1.19:8080'
    LATEST_RUNNER_VERSION=2.330.0
}
mkdir -p "$STATE_DIR" "$SNIPPETS_DIR" "$ORG_CONFIG_DIR"
: > "$REBAKE_UNIT_FILE"
calls=$state/calls
: > "$calls"
unset INVOCATION_ID REBAKE_FOREGROUND REBAKE_DETACHED BAKE_TIMEOUT BAKE_MIN_FREE_GIB LIVE_TEMPLATE_ID

require_root() { :; }
flock() { return 0; }
fetch_latest_runner_release() {
    # shellcheck disable=SC2034 # read by the sourced rebake functions
    LATEST_RUNNER_VERSION=2.330.0
}
rebake_apply_decision() {
    printf 'apply timeout=%s min=%s\n' "${BAKE_TIMEOUT-unset}" "${BAKE_MIN_FREE_GIB-unset}" >> "$calls"
}
sleep() { :; }

# --- setup keeps bake limits and other lines it does not prompt for ---
cat > "$CONFIG_FILE" <<'EOF'
# operator note
NETWORK_BRIDGE=old
export VLAN_TAG=9
VM_STORAGE=old
BAKE_TIMEOUT=7200
BAKE_MIN_FREE_GIB=15
EXTRA_LIMIT='keep me'
TEMPLATE_ID=1
TEMPLATE_ID=2
MIN_VMID=2
BALLOON=1
DNS_SERVERS=9.9.9.9
DOCKER_MIRROR_URL=http://old.example
EOF
# shellcheck disable=SC2034 # write_infra_config reads it
LIVE_TEMPLATE_ID=9000
BAKE_TIMEOUT=99999
write_infra_config
[[ "$(sed -n '1p' "$CONFIG_FILE")" == '# operator note' ]] || fail "setup dropped a comment: $(cat "$CONFIG_FILE")"
[[ "$(grep -c '^TEMPLATE_ID=' "$CONFIG_FILE")" -eq 2 ]] || fail "setup dropped or added a TEMPLATE_ID line"
grep -qx 'TEMPLATE_ID=9000' "$CONFIG_FILE" || fail "TEMPLATE_ID was not rewritten to the live template: $(cat "$CONFIG_FILE")"
if grep -qx 'TEMPLATE_ID=1' "$CONFIG_FILE" || grep -qx 'TEMPLATE_ID=2' "$CONFIG_FILE"; then
    fail "an old TEMPLATE_ID value survived the rewrite: $(cat "$CONFIG_FILE")"
fi
grep -qx 'BAKE_TIMEOUT=7200' "$CONFIG_FILE" || fail "setup dropped or rewrote BAKE_TIMEOUT: $(cat "$CONFIG_FILE")"
grep -qx 'BAKE_MIN_FREE_GIB=15' "$CONFIG_FILE" || fail "setup dropped BAKE_MIN_FREE_GIB: $(cat "$CONFIG_FILE")"
grep -qx "EXTRA_LIMIT='keep me'" "$CONFIG_FILE" || fail "setup dropped an unknown key: $(cat "$CONFIG_FILE")"
grep -qx 'NETWORK_BRIDGE=vmbr0' "$CONFIG_FILE" || fail "setup did not rewrite the bridge"
if grep -q 'VLAN_TAG=9' "$CONFIG_FILE"; then
    fail "an exported VLAN_TAG value survived the rewrite: $(cat "$CONFIG_FILE")"
fi
grep -qx "VLAN_TAG=''" "$CONFIG_FILE" || fail "VLAN_TAG was not rewritten: $(grep VLAN_TAG "$CONFIG_FILE")"
grep -qxF 'DNS_SERVERS=1.1.1.1\ 8.8.8.8' "$CONFIG_FILE" || fail "DNS was not rewritten: $(grep DNS_SERVERS "$CONFIG_FILE")"
# The one-run environment value is not what got stored.
if grep -q '99999' "$CONFIG_FILE"; then fail "setup stored the one-run BAKE_TIMEOUT"; fi
cp "$CONFIG_FILE" "$state/once"
write_infra_config
cmp -s "$CONFIG_FILE" "$state/once" || fail "a second setup rewrite changed a preserved file: $(cat "$CONFIG_FILE")"

rm -f "$CONFIG_FILE"
unset LIVE_TEMPLATE_ID
write_infra_config
[[ "$(grep -c '.' "$CONFIG_FILE")" -eq 8 ]] || fail "a new conf was not the eight prompted keys: $(cat "$CONFIG_FILE")"
if grep -q '^BAKE_' "$CONFIG_FILE"; then fail "a new conf gained a bake limit from the environment"; fi
grep -qx 'TEMPLATE_ID=9100' "$CONFIG_FILE" || fail "a new conf did not save TEMPLATE_ID"

# A partial file keeps its extra lines and gains the prompted keys it lacked.
printf '# note\nBAKE_TIMEOUT=4200\n' > "$CONFIG_FILE"
write_infra_config
grep -qx '# note' "$CONFIG_FILE" || fail "setup dropped a comment from a partial conf"
grep -qx 'BAKE_TIMEOUT=4200' "$CONFIG_FILE" || fail "setup dropped BAKE_TIMEOUT from a partial conf"
grep -qx 'NETWORK_BRIDGE=vmbr0' "$CONFIG_FILE" || fail "setup did not add a missing prompted key"
unset BAKE_TIMEOUT

# --- the timer path reads the conf; an environment value wins ---
write_limits() {
    local timeout min
    # %q keeps a value with spaces a single assignment. An unquoted "15 GiB"
    # would be a command, and the variable would never hold that text.
    printf -v timeout '%q' "$1"
    printf -v min '%q' "$2"
    cat > "$CONFIG_FILE" <<EOF
NETWORK_BRIDGE=vmbr0
VLAN_TAG=''
VM_STORAGE=local-zfs
TEMPLATE_ID=9000
MIN_VMID=9001
BALLOON=0
DNS_SERVERS=''
DOCKER_MIRROR_URL=''
BAKE_TIMEOUT=$timeout
BAKE_MIN_FREE_GIB=$min
EOF
}
# shellcheck disable=SC2329 # called by the sourced bake and rebake functions
qm() {
    printf 'qm %s\n' "$*" >> "$calls"
    if [[ "$1" == config && "$2" == 9000 ]]; then
        printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-9000-cloudinit,media=cdrom\nscsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 1\n'
        return 0
    fi
    if [[ "$1" == create ]]; then
        return 0
    fi
    return 2
}
run_rebake() {
    local timeout_mode="${1-unset}" min_mode="${2-unset}"
    : > "$calls"
    rebake_rc=0
    (
        unset BAKE_TIMEOUT BAKE_MIN_FREE_GIB
        # shellcheck disable=SC2034 # detach_rebake_from_ssh reads it
        REBAKE_FOREGROUND=1
        if [[ "$timeout_mode" != unset ]]; then
            export BAKE_TIMEOUT="$timeout_mode"
        fi
        if [[ "$min_mode" != unset ]]; then
            export BAKE_MIN_FREE_GIB="$min_mode"
        fi
        rebake_main
    ) >"$state/out" 2>"$state/log" || rebake_rc=$?
}

write_limits 120 0
run_rebake
[[ "$rebake_rc" == 0 ]] || fail "a conf BAKE_TIMEOUT=120 was refused: $(cat "$state/log")"
grep -qx 'apply timeout=120 min=0' "$calls" || fail "the timer rebake did not use the conf limits: $(cat "$calls") $(cat "$state/log")"

write_limits 120 0
run_rebake 180 5
[[ "$rebake_rc" == 0 ]] || fail "an environment bake limit was refused: $(cat "$state/log")"
grep -qx 'apply timeout=180 min=5' "$calls" || fail "the environment limit did not win over the conf: $(cat "$calls")"

write_limits 120 0
run_rebake '' unset
[[ "$rebake_rc" == 0 ]] || fail "an empty BAKE_TIMEOUT was refused: $(cat "$state/log")"
grep -qx 'apply timeout= min=0' "$calls" || fail "an empty BAKE_TIMEOUT did not win over the conf: $(cat "$calls")"

write_limits 2h 0
run_rebake
[[ "$rebake_rc" != 0 ]] || fail "rebake accepted BAKE_TIMEOUT=2h from the conf"
grep -q 'BAKE_TIMEOUT must be a whole number of seconds' "$state/log" || fail "a bad conf BAKE_TIMEOUT was not reported: $(cat "$state/log")"
if grep -q '^qm ' "$calls"; then fail "a bad conf BAKE_TIMEOUT reached qm: $(cat "$calls")"; fi
if grep -q '^apply ' "$calls"; then fail "a bad conf BAKE_TIMEOUT continued the rebake"; fi

write_limits 7200 '15 GiB'
run_rebake
[[ "$rebake_rc" != 0 ]] || fail "rebake accepted a non-numeric BAKE_MIN_FREE_GIB from the conf"
grep -q 'BAKE_MIN_FREE_GIB must be a whole number of GiB' "$state/log" || fail "a bad conf BAKE_MIN_FREE_GIB was not reported: $(cat "$state/log")"
if grep -q '^qm ' "$calls"; then fail "a bad conf BAKE_MIN_FREE_GIB reached qm: $(cat "$calls")"; fi

# The environment value is what the bake uses, even when the conf disagrees.
write_limits 2h 50
run_rebake 7200 0
[[ "$rebake_rc" == 0 ]] || fail "a valid environment limit lost to a bad conf value: $(cat "$state/log")"
grep -qx 'apply timeout=7200 min=0' "$calls" || fail "the valid environment limit was not kept: $(cat "$calls") $(cat "$state/log")"

# --- create_bake_vm refuses a conf value before qm create; the poll uses it ---
pvesm() {
    printf 'pvesm %s\n' "$*" >> "$calls"
    case "$1" in
        list) printf 'Volid Format Type Size VMID\n' ;;
        status)
            printf 'Name Type Status Total Used Available %%\n'
            printf 'local-zfs lvmthin active 1000000000 100000000 10485760 10.00%%\n'
            ;;
        *) return 1 ;;
    esac
}
load_limits() {
    local timeout_mode="${1-unset}" min_mode="${2-unset}"
    unset BAKE_TIMEOUT BAKE_MIN_FREE_GIB
    if [[ "$timeout_mode" != unset ]]; then
        BAKE_TIMEOUT=$timeout_mode
    fi
    if [[ "$min_mode" != unset ]]; then
        BAKE_MIN_FREE_GIB=$min_mode
    fi
    load_infra_config
}

write_limits 2h 0
: > "$calls"
load_limits
create_rc=0
create_bake_vm 9001 2>"$state/log" || create_rc=$?
[[ "$create_rc" != 0 ]] || fail "create_bake_vm accepted BAKE_TIMEOUT=2h from the conf"
if grep -q '^qm create' "$calls"; then fail "create_bake_vm created a VM with a bad conf BAKE_TIMEOUT"; fi
grep -q 'BAKE_TIMEOUT must be a whole number of seconds' "$state/log" || fail "create_bake_vm did not report the conf BAKE_TIMEOUT"

write_limits 7200 50
: > "$calls"
load_limits
create_rc=0
create_bake_vm 9001 2>"$state/log" || create_rc=$?
[[ "$create_rc" != 0 ]] || fail "create_bake_vm ignored a conf free-space floor above the free space"
if grep -q '^qm create' "$calls"; then fail "create_bake_vm created a VM below the conf free-space floor"; fi
grep -q 'a bake needs 50 GiB' "$state/log" || fail "the conf floor was not the one refused: $(cat "$state/log")"

write_limits 7200 50
: > "$calls"
load_limits unset 5
create_rc=0
create_bake_vm 9001 2>"$state/log" || create_rc=$?
[[ "$create_rc" == 0 ]] || fail "BAKE_MIN_FREE_GIB=5 did not win over the conf floor: $(cat "$state/log")"
grep -q '^qm create 9001 ' "$calls" || fail "an environment floor that fits did not reach qm create"

# setup's prefill source is the path that puts a conf limit on a setup bake.
write_limits 2h 0
unset BAKE_TIMEOUT BAKE_MIN_FREE_GIB
# shellcheck disable=SC2034 # load_setup_prefills reads it
NETWORK_BRIDGE=vmbr0
load_setup_prefills
[[ "${BAKE_TIMEOUT-unset}" == 2h ]] || fail "setup did not take BAKE_TIMEOUT from the conf (got ${BAKE_TIMEOUT-unset})"
: > "$calls"
create_rc=0
create_bake_vm 9001 2>"$state/log" || create_rc=$?
[[ "$create_rc" != 0 ]] || fail "a setup bake accepted BAKE_TIMEOUT=2h from the conf"
if grep -q '^qm create' "$calls"; then fail "a setup bake created a VM with a bad conf BAKE_TIMEOUT"; fi

write_limits 10800 0
BAKE_TIMEOUT=180
load_setup_prefills
[[ "$BAKE_TIMEOUT" == 180 ]] || fail "setup let the conf replace an explicit BAKE_TIMEOUT (got ${BAKE_TIMEOUT-unset})"
unset BAKE_TIMEOUT

# The poll's deadline is the conf value, not the 5400 default.
# shellcheck disable=SC2329 # called by bake_and_publish_vm
qm() {
    printf 'qm %s\n' "$*" >> "$calls"
    case "$1" in
        importdisk) printf "unused0: successfully imported disk 'local-zfs:vm-9001-disk-0'\n" ;;
        status) printf 'status: running\n' ;;
        guest) return 1 ;;
        set|resize|start) return 0 ;;
        *) return 1 ;;
    esac
}
poll_for() {
    local expect="$1"
    : > "$calls"
    bake_rc=0
    bake_and_publish_vm 9001 2>"$state/log" || bake_rc=$?
    [[ "$bake_rc" != 0 ]] || fail "a bake with no guest marker succeeded"
    grep -q "Bake timed out after ${expect} minutes" "$state/log" \
        || fail "expected a ${expect}-minute bake timeout, got: $(grep 'Bake timed out' "$state/log" || echo none)"
    if grep -q 'after 90 minutes' "$state/log"; then
        fail "the bake used the default 90 minutes instead of ${expect}"
    fi
}
write_limits 120 0
load_limits
poll_for 2
write_limits 120 0
load_limits 180
poll_for 3

grep -qx 'TimeoutStartSec=9000' "$root/templates/github-runner-rebake.service" \
    || fail "the rebake unit's default cap is not the default poll limit plus an hour"
grep -qx 'TimeoutStopSec=180' "$root/templates/github-runner-rebake.service" \
    || fail "TimeoutStopSec no longer gives cleanup time to destroy a partial VM"
grep -qx 'KillMode=mixed' "$root/templates/github-runner-rebake.service" \
    || fail "KillMode=mixed was dropped"

printf 'bake-conf-limits: ok\n'
