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
rebake_needed "$ver" "$ver" "$fresh" "$now" && fail "5-day-old matching template was treated as stale"
rebake_needed "$ver" "$ver" "$just_under" "$now" && fail "a template one second under 21 days was treated as stale"
rebake_needed "$ver" "$ver" "$exact" "$now" || fail "a template exactly 21 days old was treated as current"
rebake_needed "$ver" "2.330.0" "$fresh" "$now" || fail "a version mismatch was treated as current"
rebake_needed "" "$ver" "$fresh" "$now" || fail "a missing recorded version was treated as current"
rebake_needed "$ver" "$ver" "" "$now" || fail "an unknown bake time was treated as current"
rebake_needed "v$ver" "$ver" "$fresh" "$now" && fail "a leading v was not normalized"

DID_BAKE=0
perform_bake() { DID_BAKE=$((DID_BAKE + 1)); }

rebake_apply_decision "$ver" "$ver" "$fresh" "$now"
[[ "$DID_BAKE" -eq 0 ]] || fail "already-current decision started a bake"

rebake_apply_decision "$ver" "2.330.0" "$fresh" "$now"
[[ "$DID_BAKE" -eq 1 ]] || fail "version mismatch did not start a bake"

rebake_apply_decision "$ver" "$ver" "$exact" "$now"
[[ "$DID_BAKE" -eq 2 ]] || fail "21-day-old template did not start a bake"

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
date() { printf '%s\n' "$now"; }
write_baked_record "2.329.0" "2026-09-01T00:00:00Z" "9000"
read_baked_record
[[ "$RECORDED_RUNNER_VERSION" == "2.329.0" ]] || fail "recorded version did not round-trip: $RECORDED_RUNNER_VERSION"
[[ "$RECORDED_RUNNER_PUBLISHED_AT" == "2026-09-01T00:00:00Z" ]] || fail "recorded published_at did not round-trip: $RECORDED_RUNNER_PUBLISHED_AT"
write_baked_record "2.329.0" "" "9000"
read_baked_record
[[ -z "$RECORDED_RUNNER_PUBLISHED_AT" ]] || fail "empty published_at did not round-trip: $RECORDED_RUNNER_PUBLISHED_AT"
[[ "$RECORDED_BAKED_AT" == "$now" ]] || fail "successful bake time did not round-trip"
rebake_apply_decision "$RECORDED_RUNNER_VERSION" "$ver" "$RECORDED_BAKED_AT" "$((now + day))"
[[ "$DID_BAKE" -eq 3 ]] || fail "fresh bake of an old release baked again the next day"
rebake_apply_decision "$RECORDED_RUNNER_VERSION" "$ver" "$RECORDED_BAKED_AT" "$((now + 21 * day))"
[[ "$DID_BAKE" -eq 4 ]] || fail "successful bake did not expire after 21 days"
unset -f date
# Older records have no bake time: refresh once rather than trusting release age.
printf 'version=2.329.0\npublished_at=2026-09-01T00:00:00Z\ntemplate_id=9000\n' > "$BAKED_VERSION_FILE"
read_baked_record
[[ -z "$RECORDED_BAKED_AT" ]] || fail "legacy record retained the previous bake time"
rebake_needed "$RECORDED_RUNNER_VERSION" "$ver" "$RECORDED_BAKED_AT" "$now" || fail "legacy record without bake time did not refresh"
rebake_needed "$ver" "$ver" "$((now + day))" "$now" || fail "future bake time was accepted"
rm -rf "$state"

# A real lookup has to return 0. The old last line was `[[ == "null" ]] &&`,
# which is false for every ISO timestamp and made every rebake exit before
# the decision. rebake_main calls this under `if !`, same as here.
curl() {
    printf '%s\n' '{"tag_name":"v2.329.0","published_at":"2026-09-01T00:00:00Z"}'
}
if ! fetch_latest_runner_release; then
    fail "successful release lookup returned non-zero"
fi
[[ "$LATEST_RUNNER_VERSION" == "2.329.0" ]] || fail "tag_name was not normalized: ${LATEST_RUNNER_VERSION}"
[[ "$LATEST_RUNNER_PUBLISHED_AT" == "2026-09-01T00:00:00Z" ]] || fail "published_at was not kept: ${LATEST_RUNNER_PUBLISHED_AT}"

curl() {
    printf '%s\n' '{"tag_name":"v2.329.0","published_at":null}'
}
if ! fetch_latest_runner_release; then
    fail "release lookup with a null published_at returned non-zero"
fi
[[ "$LATEST_RUNNER_VERSION" == "2.329.0" ]] || fail "null published_at changed the version: ${LATEST_RUNNER_VERSION}"
[[ -z "$LATEST_RUNNER_PUBLISHED_AT" ]] || fail "null published_at was not cleared: ${LATEST_RUNNER_PUBLISHED_AT}"
unset -f curl

# awk failing must not replace the config or retire the live template.
# switch_template_id is invoked under `||`, which is what used to hide the
# failure and still update TEMPLATE_ID.
switch_conf=$(mktemp)
switch_state=$(mktemp -d)
trap 'rm -f "$fixture" "$fixture".* "$switch_conf" "$switch_conf".*; rm -rf "$switch_state"' EXIT
printf 'TEMPLATE_ID=9000\nNETWORK_BRIDGE=vmbr0\n' > "$switch_conf"
cp "$switch_conf" "$switch_conf.orig"
# shellcheck disable=SC2034 # switch_template_id reads these
CONFIG_FILE=$switch_conf
TEMPLATE_ID=9000
STATE_DIR=$switch_state
RETIRED_TEMPLATES_FILE=$switch_state/retired-templates
awk() { return 1; }
status=0
switch_template_id 9100 || status=$?
unset -f awk
[[ "$status" -ne 0 ]] || fail "switch_template_id returned 0 after awk failed"
[[ "$TEMPLATE_ID" == "9000" ]] || fail "shell TEMPLATE_ID changed after a failed switch: ${TEMPLATE_ID}"
cmp -s "$switch_conf" "$switch_conf.orig" || fail "config file changed after a failed TEMPLATE_ID update"
[[ ! -e "$RETIRED_TEMPLATES_FILE" ]] || fail "retired template list was written after a failed switch"
shopt -s nullglob
leftovers=()
for leftover in "$switch_conf".*; do
    [[ "$leftover" == "$switch_conf.orig" ]] && continue
    leftovers+=("$leftover")
done
shopt -u nullglob
[[ ${#leftovers[@]} -eq 0 ]] || fail "failed TEMPLATE_ID update left ${leftovers[*]}"

# Runner.Listener creates _diag before printing --version. The probe has to
# run as the runner user, and the home has to be chowned again afterward.
awk '
    /sudo -u "\$RUNNER_USER" \.\/bin\/Runner\.Listener --version/ { probe = NR }
    probe && /chown -R "\$RUNNER_USER:\$RUNNER_USER" "\$RUNNER_HOME"/ { found = 1; exit }
    END { exit found ? 0 : 1 }
' "$root/templates/template-setup.yaml" || fail "listener version probe is not run as the runner user and chowned afterward"

# template_has_linked_clones calls this under if !, which disables errexit
# inside the function. A failed base-volume listing must still return non-zero.
qm() { return 0; }
pvesm() {
    printf 'nvme-pool:vm-1-disk-0\n'
    return 0
}
list_template_base_volids() { return 1; }
# shellcheck disable=SC2034
VM_STORAGE=nvme-pool
if vols=$(list_template_linked_clone_volids 9000); then
    fail "failed base-volume listing looked like no linked clones"
fi
unset -f qm pvesm list_template_base_volids

printf 'rebake-decision: ok\n'
