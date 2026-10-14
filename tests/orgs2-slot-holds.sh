#!/usr/bin/env bash
# add-org installs the operator's fix for a failing org, such as a rotated
# PAT. It must clear the failure holds of that org's slots, or the watcher
# keeps skipping them for up to 30 minutes. It must clear only that org's
# slots: another org whose prefix starts with this one's keeps its holds.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'orgs2-slot-holds: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# The watcher's own hold check (slot_is_held) judges the result.
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/recycle.sh
source "$root/lib/recycle.sh"
fail() { printf 'orgs2-slot-holds: %s\n' "$1" >&2; exit 1; }

# Run the real add-org.sh from a copy of lib/ whose host paths point at a
# scratch dir, with the root check skipped and curl mocked (HTTP 200).
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
SLOT_STATE_DIR=$state/slots
mkdir -p "$state/lib" "$state/orgs" "$state/install/templates" "$SLOT_STATE_DIR"
cp "$root"/lib/*.sh "$state/lib/"
: > "$state/install/templates/runner-user-data.yaml"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=9000\n' > "$state/github-runners.conf"
cat >> "$state/lib/common.sh" <<EOF
CONFIG_FILE="$state/github-runners.conf"
ORG_CONFIG_DIR="$state/orgs"
INSTALL_DIR="$state/install"
require_root() { :; }
curl() { printf 200; }
EOF
# recycle.sh is sourced after common.sh and sets its own state dir.
printf 'SLOT_STATE_DIR="%s"\n' "$SLOT_STATE_DIR" >> "$state/lib/recycle.sh"
add_org() {
    printf '%s' "$1" | "$BASH" "$state/lib/add-org.sh" >/dev/null 2>"$state/err" ||
        fail "add-org failed: $(cat "$state/err")"
}
# Hold slot $1 for 30 minutes, through recycle.sh's own record of eight failed
# clones in a row.
hold() {
    local i
    for i in 1 2 3 4 5 6 7 8; do
        slot_note_clone_failure "$1" 2>/dev/null
    done
}
expect_free() {
    if slot_is_held "$1"; then fail "$2: $1 is still held for ${SLOT_HOLD_LEFT}s"; fi
}
expect_held() {
    slot_is_held "$1" || fail "$2: the hold of $1 was cleared"
}

printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_old"\nRUNNER_PREFIX="gpu"\nRUNNER_COUNT="2"\nRUNNER_GROUP_ID="1"\n' \
    > "$state/orgs/acme.conf"
# Another org whose slot names a gpu-* glob would match.
printf 'GITHUB_ORG="beta"\nGITHUB_PAT="ghp_beta"\nRUNNER_PREFIX="gpu-x"\nRUNNER_COUNT="1"\nRUNNER_GROUP_ID="1"\n' \
    > "$state/orgs/beta.conf"
hold gpu-1
hold gpu-2
hold gpu-3
hold gpu-x-1

# The PAT expired and every slot is held; rotation input: org, confirm, PAT,
# then Enter to keep the prefix, count and group.
add_org $'acme\ny\nghp_new\n\n\n\n'
expect_free gpu-1 "a PAT rotation"
expect_free gpu-2 "a PAT rotation"
expect_held gpu-x-1 "a PAT rotation for acme"

# A raised count retries the new slot too.
add_org $'acme\ny\nghp_new\n\n3\n\n'
expect_free gpu-3 "a raised RUNNER_COUNT"
expect_held gpu-x-1 "a count change for acme"

# A new org that takes the prefix of a removed org gets its slots at once.
hold ci-1
hold ci-2
add_org $'gamma\nghp_new\nci\n\n\n'
expect_free ci-1 "a new org"
expect_free ci-2 "a new org"
expect_held gpu-x-1 "a new org"

printf 'orgs2-slot-holds: ok\n'
