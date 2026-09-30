#!/usr/bin/env bash
# The "already current" decision must not start a bake. Sourcing lib/rebake.sh
# parses bash-4 syntax in lib/common.sh (local -A), so re-exec under bash 4+.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$candidate" ]]; then
            exec "$candidate" "$0" "$@"
        fi
    done
    printf 'rebake-decision: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)

fail() {
    printf 'rebake-decision: %s\n' "$1" >&2
    exit 1
}

# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"

# A failed release lookup exits before the decision, so it cannot start a bake.
awk '
    /Could not read the latest actions\/runner release/ { seen = 1 }
    seen && /exit 1/ { exited = 1; next }
    exited && /rebake_apply_decision/ { found = 1 }
    END { exit found ? 0 : 1 }
' "$root/lib/rebake.sh" || fail "API failure does not exit before rebake_apply_decision"

now=1700000000
day=86400
fresh=$((now - 5 * day))
exact=$((now - 21 * day))
just_under=$((exact + 1))
ver=2.329.0

# 0 = bake, 1 = already current.
rebake_needed "$ver" "$ver" "$fresh" "$now" && fail "5-day-old matching release was treated as stale"
rebake_needed "$ver" "$ver" "$just_under" "$now" && fail "a release one second under 21 days was treated as stale"
rebake_needed "$ver" "$ver" "$exact" "$now" || fail "a release exactly 21 days old was treated as current"
rebake_needed "$ver" "2.330.0" "$fresh" "$now" || fail "a version mismatch was treated as current"
rebake_needed "" "$ver" "$fresh" "$now" || fail "a missing recorded version was treated as current"
rebake_needed "$ver" "$ver" "" "$now" || fail "an unknown release date was treated as current"
rebake_needed "v$ver" "$ver" "$fresh" "$now" && fail "a leading v was not normalized"

DID_BAKE=0
perform_bake() { DID_BAKE=$((DID_BAKE + 1)); }

rebake_apply_decision "$ver" "$ver" "$fresh" "$now"
[[ "$DID_BAKE" -eq 0 ]] || fail "already-current decision started a bake"

rebake_apply_decision "$ver" "2.330.0" "$fresh" "$now"
[[ "$DID_BAKE" -eq 1 ]] || fail "version mismatch did not start a bake"

rebake_apply_decision "$ver" "$ver" "$exact" "$now"
[[ "$DID_BAKE" -eq 2 ]] || fail "21-day-old release did not start a bake"

rebake_apply_decision "" "$ver" "$fresh" "$now"
[[ "$DID_BAKE" -eq 3 ]] || fail "missing recorded version did not start a bake"

# Switching TEMPLATE_ID must leave the rest of the saved infra config alone.
fixture=$(mktemp)
cleanup() { rm -f "$fixture" "$fixture".*; }
trap cleanup EXIT
cat > "$fixture" <<'EOF'
NETWORK_BRIDGE=vmbr0
VLAN_TAG=''
VM_STORAGE=nvme-pool
TEMPLATE_ID=9000
MIN_VMID=9001
BALLOON=0
DNS_SERVERS=1.1.1.1\ 8.8.8.8
DOCKER_MIRROR_URL=http://10.20.1.19:8080
EOF
before=$(grep -v '^TEMPLATE_ID=' "$fixture")
set_conf_assignment "$fixture" TEMPLATE_ID 9100
after=$(grep -v '^TEMPLATE_ID=' "$fixture")
[[ "$before" == "$after" ]] || fail "set_conf_assignment rewrote a line other than TEMPLATE_ID"
[[ "$(grep '^TEMPLATE_ID=' "$fixture")" == "TEMPLATE_ID=9100" ]] || fail "TEMPLATE_ID was not updated"

(
    # shellcheck disable=SC1090
    source "$fixture"
    [[ "$NETWORK_BRIDGE" == "vmbr0" ]]
    [[ -z "${VLAN_TAG}" ]]
    [[ "$VM_STORAGE" == "nvme-pool" ]]
    [[ "$TEMPLATE_ID" == "9100" ]]
    [[ "$MIN_VMID" == "9001" ]]
    [[ "$BALLOON" == "0" ]]
    [[ "$DNS_SERVERS" == "1.1.1.1 8.8.8.8" ]]
    [[ "$DOCKER_MIRROR_URL" == "http://10.20.1.19:8080" ]]
) || fail "sourced config lost a live infra value"

state=$(mktemp -d)
# shellcheck disable=SC2034 # write_baked_record and read_baked_record read these
STATE_DIR=$state
# shellcheck disable=SC2034
BAKED_VERSION_FILE=$state/baked-runner-version
write_baked_record "2.329.0" "2026-09-01T00:00:00Z" "9000"
read_baked_record
[[ "$RECORDED_RUNNER_VERSION" == "2.329.0" ]] || fail "recorded version did not round-trip: $RECORDED_RUNNER_VERSION"
[[ "$RECORDED_RUNNER_PUBLISHED_AT" == "2026-09-01T00:00:00Z" ]] || fail "recorded published_at did not round-trip: $RECORDED_RUNNER_PUBLISHED_AT"
write_baked_record "2.329.0" "" "9000"
read_baked_record
[[ -z "$RECORDED_RUNNER_PUBLISHED_AT" ]] || fail "empty published_at did not round-trip: $RECORDED_RUNNER_PUBLISHED_AT"
rm -rf "$state"

printf 'rebake-decision: ok\n'
