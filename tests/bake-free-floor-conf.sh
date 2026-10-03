#!/usr/bin/env bash
# BAKE_FREE_FLOOR_GIB in /etc/github-runners.conf is the mid-bake floor. An
# explicit environment value wins, including an empty one. A bad conf value
# fails before detach: systemd would not see an empty override and would run
# the conf. A value set in the environment detaches through setsid, because
# systemctl start cannot pass it. setup keeps the line.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bake-free-floor-conf: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'bake-free-floor-conf: %s\n' "$1" >&2; exit 1; }
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
    REBAKE_DROPIN_FILE=$state/timeout.conf
    INSTALL_DIR=$root
    NETWORK_BRIDGE=vmbr0
    VLAN_TAG=
    VM_STORAGE=local-zfs
    TEMPLATE_ID=9000
    MIN_VMID=9001
    BALLOON=0
    DNS_SERVERS=
    DOCKER_MIRROR_URL=
}
mkdir -p "$STATE_DIR" "$ORG_CONFIG_DIR"
: > "$REBAKE_UNIT_FILE"
calls=$state/calls
: > "$calls"
unset INVOCATION_ID REBAKE_FOREGROUND REBAKE_DETACHED BAKE_TIMEOUT BAKE_MIN_FREE_GIB BAKE_FREE_FLOOR_GIB

require_root() { :; }
flock() { return 0; }
fetch_latest_runner_release() {
    # shellcheck disable=SC2034 # read by the sourced rebake functions
    LATEST_RUNNER_VERSION=2.330.0
}
rebake_apply_decision() {
    printf 'apply floor=%s\n' "${BAKE_FREE_FLOOR_GIB-unset}" >> "$calls"
}
# shellcheck disable=SC2329 # called by rebake_main and the drop-in writer
systemctl() { printf 'systemctl %s\n' "$*" >> "$calls"; }
# shellcheck disable=SC2329 # called by detach_rebake_from_ssh
setsid() {
    printf 'setsid BAKE_FREE_FLOOR_GIB=%s\n' \
        "$(printenv BAKE_FREE_FLOOR_GIB || printf unset)" >> "$calls"
}
# shellcheck disable=SC2329 # called by require_live_template
qm() {
    printf 'qm %s\n' "$*" >> "$calls"
    if [[ "$1" == config && "$2" == 9000 ]]; then
        printf 'name: ubuntu-cloud-template\nide2: local-zfs:vm-9000-cloudinit,media=cdrom\nscsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 1\n'
        return 0
    fi
    return 2
}

write_conf() {
    cat > "$CONFIG_FILE" <<EOF
NETWORK_BRIDGE=vmbr0
VLAN_TAG=''
VM_STORAGE=local-zfs
TEMPLATE_ID=9000
MIN_VMID=9001
BALLOON=0
DNS_SERVERS=''
DOCKER_MIRROR_URL=''
BAKE_TIMEOUT=7200
BAKE_MIN_FREE_GIB=0
BAKE_FREE_FLOOR_GIB=$1
EOF
}

# The floor is not one of the eight prompted keys, so a rewrite leaves it.
cat > "$CONFIG_FILE" <<'EOF'
# operator note
NETWORK_BRIDGE=old
BAKE_FREE_FLOOR_GIB=8
EOF
write_infra_config
grep -qx '# operator note' "$CONFIG_FILE" || fail "setup dropped a comment: $(cat "$CONFIG_FILE")"
grep -qx 'BAKE_FREE_FLOOR_GIB=8' "$CONFIG_FILE" || fail "setup dropped BAKE_FREE_FLOOR_GIB: $(cat "$CONFIG_FILE")"
grep -qx 'NETWORK_BRIDGE=vmbr0' "$CONFIG_FILE" || fail "setup did not rewrite the bridge"

# --- an explicit value wins; one the environment left unset takes the conf ---
write_conf 12
unset BAKE_FREE_FLOOR_GIB
load_infra_config
[[ "${BAKE_FREE_FLOOR_GIB-unset}" == 12 ]] \
    || fail "load_infra_config did not take the conf floor (got ${BAKE_FREE_FLOOR_GIB-unset})"

BAKE_FREE_FLOOR_GIB=7
load_infra_config
[[ "$BAKE_FREE_FLOOR_GIB" == 7 ]] \
    || fail "load_infra_config let the conf replace an explicit floor (got ${BAKE_FREE_FLOOR_GIB-unset})"

BAKE_FREE_FLOOR_GIB=
load_infra_config
[[ -z "${BAKE_FREE_FLOOR_GIB}" ]] \
    || fail "an empty floor did not win over the conf (got ${BAKE_FREE_FLOOR_GIB-unset})"
unset BAKE_FREE_FLOOR_GIB

write_conf 12
BAKE_FREE_FLOOR_GIB=7
load_setup_prefills
[[ "$BAKE_FREE_FLOOR_GIB" == 7 ]] \
    || fail "setup let the conf replace an explicit floor (got ${BAKE_FREE_FLOOR_GIB-unset})"
unset BAKE_FREE_FLOOR_GIB
load_setup_prefills
[[ "${BAKE_FREE_FLOOR_GIB-unset}" == 12 ]] \
    || fail "setup did not take the conf floor (got ${BAKE_FREE_FLOOR_GIB-unset})"
unset BAKE_FREE_FLOOR_GIB

run_rebake() {
    local foreground="$1" floor_mode="${2-unset}"
    : > "$calls"
    rebake_rc=0
    (
        unset BAKE_TIMEOUT BAKE_MIN_FREE_GIB BAKE_FREE_FLOOR_GIB REBAKE_FOREGROUND
        if [[ "$foreground" == 1 ]]; then
            # shellcheck disable=SC2034 # detach_rebake_from_ssh reads it
            REBAKE_FOREGROUND=1
        fi
        if [[ "$floor_mode" != unset ]]; then
            export BAKE_FREE_FLOOR_GIB="$floor_mode"
        fi
        rebake_main
    ) >"$state/out" 2>"$state/log" || rebake_rc=$?
}

# The timer path reads the conf. A valid environment value is what the bake
# uses when the conf value would be refused.
write_conf 4
run_rebake 1
[[ "$rebake_rc" == 0 ]] || fail "a conf floor of 4 was refused: $(cat "$state/log")"
grep -qx 'apply floor=4' "$calls" || fail "the timer rebake did not use the conf floor: $(cat "$calls") $(cat "$state/log")"

write_conf lots
run_rebake 1 9
[[ "$rebake_rc" == 0 ]] || fail "a valid environment floor lost to a bad conf value: $(cat "$state/log")"
grep -qx 'apply floor=9' "$calls" || fail "the environment floor was not the one applied: $(cat "$calls") $(cat "$state/log")"

# No override, and an empty override: systemd runs the conf, so a bad conf
# value fails in this shell. Neither handoff may start.
refuse_bad_conf() {
    local floor_mode="$1" label="$2"
    write_conf lots
    run_rebake 0 "$floor_mode"
    [[ "$rebake_rc" != 0 ]] || fail "$label detached with a bad conf floor"
    grep -qF "BAKE_FREE_FLOOR_GIB must be a whole number of GiB, not 'lots'" "$state/log" \
        || fail "$label did not report the conf floor: $(cat "$state/log")"
    if grep -q 'systemctl' "$calls"; then
        fail "$label handed a bad conf floor to systemd: $(cat "$calls")"
    fi
    if grep -q '^setsid ' "$calls"; then
        fail "$label detached a bad conf floor with setsid: $(cat "$calls")"
    fi
    if grep -q '^apply ' "$calls" || grep -q '^qm ' "$calls"; then
        fail "$label continued past the bad conf floor: $(cat "$calls")"
    fi
}
refuse_bad_conf unset "an unset floor"
refuse_bad_conf '' "an empty floor"

# A set value, including 0, has to ride along with setsid. systemctl start
# would drop it and the unit would use the conf.
write_conf lots
run_rebake 0 3
[[ "$rebake_rc" == 0 ]] || fail "a valid environment floor did not detach: $(cat "$state/log")"
grep -qx 'setsid BAKE_FREE_FLOOR_GIB=3' "$calls" \
    || fail "BAKE_FREE_FLOOR_GIB=3 did not detach through setsid: $(cat "$calls")"
if grep -q 'systemctl start' "$calls"; then
    fail "BAKE_FREE_FLOOR_GIB=3 was handed to systemd: $(cat "$calls")"
fi

write_conf 12
run_rebake 0 0
[[ "$rebake_rc" == 0 ]] || fail "BAKE_FREE_FLOOR_GIB=0 did not detach: $(cat "$state/log")"
grep -qx 'setsid BAKE_FREE_FLOOR_GIB=0' "$calls" \
    || fail "BAKE_FREE_FLOOR_GIB=0 did not detach through setsid: $(cat "$calls")"
if grep -q 'systemctl start' "$calls"; then
    fail "BAKE_FREE_FLOOR_GIB=0 was handed to systemd: $(cat "$calls")"
fi

# No environment floor: the unit is what runs, and it reads the conf.
write_conf 4
run_rebake 0
[[ "$rebake_rc" == 0 ]] || fail "a valid conf floor did not detach: $(cat "$state/log")"
grep -qx 'systemctl start --no-block github-runner-rebake.service' "$calls" \
    || fail "a valid conf floor did not start the unit: $(cat "$calls")"
if grep -q '^setsid ' "$calls"; then
    fail "a conf floor with no environment value detached through setsid: $(cat "$calls")"
fi

printf 'bake-free-floor-conf: ok\n'
