#!/usr/bin/env bash
# setup replaces a conf line only when it is exactly one assignment of a key
# it prompts for. A second command on the line, or a quote that continues
# below, used to be swallowed, which dropped BAKE_TIMEOUT or left a file
# bash could not source. A later command that sets one of those keys without
# looking like such an assignment must not stay the sourced value. A result
# that is not valid shell, or that still does not source to the new values,
# must not replace the old file.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup-conf-rewrite: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup.sh
source "$root/lib/setup.sh"
fail() { printf 'setup-conf-rewrite: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# shellcheck disable=SC2034 # write_infra_config reads these
{
    CONFIG_FILE=$state/github-runners.conf
    ORG_CONFIG_DIR=$state/github-runners.d
    NETWORK_BRIDGE=vmbr0
    VLAN_TAG=
    VM_STORAGE=local-lvm
    TEMPLATE_ID=9000
    MIN_VMID=100
    BALLOON=0
    DNS_SERVERS='1.1.1.1 8.8.8.8'
    # shellcheck disable=SC2016 # the mirror value is the literal text, including $(id)
    DOCKER_MIRROR_URL='http://x/$(id)'
}
mkdir -p "$ORG_CONFIG_DIR"

cat > "$CONFIG_FILE" <<'EOF'
# operator comment
export NETWORK_BRIDGE=vmbr1
MIN_VMID=200; BAKE_TIMEOUT=10800
DNS_SERVERS="9.9.9.9
 1.1.1.1"
BAKE_MIN_FREE_GIB=50
EOF
write_infra_config
# The semicolon line is not one assignment, so the bake limit on it survives
# and the new MIN_VMID is appended, where it wins.
grep -qx 'MIN_VMID=200; BAKE_TIMEOUT=10800' "$CONFIG_FILE" \
    || fail "setup rewrote a line that was more than one assignment: $(cat "$CONFIG_FILE")"
if grep -qx 'BAKE_TIMEOUT=10800' "$CONFIG_FILE"; then
    fail "setup stored BAKE_TIMEOUT on its own and dropped the rest of the line"
fi
# shellcheck disable=SC1090
(
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [[ "$MIN_VMID" == 100 ]] || exit 1
    [[ "$BAKE_TIMEOUT" == 10800 ]] || exit 1
    [[ "$BAKE_MIN_FREE_GIB" == 50 ]] || exit 1
    [[ "$NETWORK_BRIDGE" == vmbr0 ]] || exit 1
    [[ "$DNS_SERVERS" == '1.1.1.1 8.8.8.8' ]] || exit 1
) || fail "the rewritten conf did not source to the new values: $(cat "$CONFIG_FILE")"
grep -qx '# operator comment' "$CONFIG_FILE" || fail "setup dropped a comment"
if grep -q 'export NETWORK_BRIDGE=vmbr1' "$CONFIG_FILE"; then
    fail "an exact exported assignment was not replaced"
fi
# A continued quote stays a complete assignment, then the appended value wins.
grep -q '9.9.9.9' "$CONFIG_FILE" || fail "setup dropped the continued DNS line: $(cat "$CONFIG_FILE")"

# No space after the semicolon. The second assignment is still part of the
# line, and replacing the line would drop BAKE_TIMEOUT.
cat > "$CONFIG_FILE" <<'EOF'
MIN_VMID=200;BAKE_TIMEOUT=10800
EOF
write_infra_config
grep -qx 'MIN_VMID=200;BAKE_TIMEOUT=10800' "$CONFIG_FILE" \
    || fail "setup rewrote a semicolon command with no space: $(cat "$CONFIG_FILE")"
# shellcheck disable=SC1090
(
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [[ "$MIN_VMID" == 100 ]] || exit 1
    [[ "$BAKE_TIMEOUT" == 10800 ]] || exit 1
) || fail "the appended MIN_VMID did not win over the semicolon line: $(cat "$CONFIG_FILE")"

# An unclosed quote must not be published. The appended assignment would sit
# inside it, and every later source of the conf would fail.
cat > "$CONFIG_FILE" <<'EOF'
NETWORK_BRIDGE='unterminated
EOF
cp "$CONFIG_FILE" "$state/before"
rewrite_rc=0
write_infra_config 2>"$state/err" || rewrite_rc=$?
[[ "$rewrite_rc" != 0 ]] || fail "setup published a conf bash cannot source"
cmp -s "$CONFIG_FILE" "$state/before" || fail "setup replaced the conf with a file that is not valid shell"
grep -q 'not valid shell' "$state/err" || fail "the refusal did not say why: $(cat "$state/err")"

# The exact assignment is replaced in place, and this later command does not
# look like one, so nothing used to be appended after it. It stayed last and
# won. The sourced TEMPLATE_ID has to be the value setup just collected.
TEMPLATE_ID=9001
cat > "$CONFIG_FILE" <<'EOF'
TEMPLATE_ID=9000
true; TEMPLATE_ID=9000
BAKE_MIN_FREE_GIB=50
EOF
write_infra_config
grep -qx 'true; TEMPLATE_ID=9000' "$CONFIG_FILE" \
    || fail "setup rewrote a later command that only mentions TEMPLATE_ID: $(cat "$CONFIG_FILE")"
grep -qx 'BAKE_MIN_FREE_GIB=50' "$CONFIG_FILE" || fail "setup dropped BAKE_MIN_FREE_GIB: $(cat "$CONFIG_FILE")"
# shellcheck disable=SC1090
(
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [[ "$TEMPLATE_ID" == 9001 ]] || exit 1
    [[ "$BAKE_MIN_FREE_GIB" == 50 ]] || exit 1
    [[ "$NETWORK_BRIDGE" == vmbr0 ]] || exit 1
) || fail "setup left a later command as the effective TEMPLATE_ID: $(cat "$CONFIG_FILE")"
cp "$CONFIG_FILE" "$state/stable"
write_infra_config
cmp -s "$CONFIG_FILE" "$state/stable" \
    || fail "a second setup rewrite appended another TEMPLATE_ID: $(cat "$CONFIG_FILE")"

# false aborts the source before any appended assignment. The old file stays.
cat > "$CONFIG_FILE" <<'EOF'
TEMPLATE_ID=9000
false
EOF
cp "$CONFIG_FILE" "$state/before"
rewrite_rc=0
write_infra_config 2>"$state/err" || rewrite_rc=$?
[[ "$rewrite_rc" != 0 ]] || fail "setup published a conf that does not source to the new values"
cmp -s "$CONFIG_FILE" "$state/before" \
    || fail "setup replaced a conf whose sourced keys stay wrong: $(cat "$CONFIG_FILE")"
grep -q 'does not set' "$state/err" || fail "the refusal did not say why: $(cat "$state/err")"

printf 'setup-conf-rewrite: ok\n'
