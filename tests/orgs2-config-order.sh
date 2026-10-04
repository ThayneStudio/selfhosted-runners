#!/usr/bin/env bash
# Re-running add-org must rewrite the five prompted keys where they are, not
# move them below the kept lines. Every caller sources the org config under
# set -u, so a hand-set line that expands a key, such as
# RUNNER_LABELS="...,${RUNNER_PREFIX}", must still come after that key, or the
# watcher's worker dies on an unbound variable and the org's pool drains.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'orgs2-config-order: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'orgs2-config-order: %s\n' "$1" >&2; exit 1; }

# Run the real add-org.sh from a copy of lib/ whose host paths point at a
# scratch dir, with the root check skipped and curl mocked (HTTP 200).
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
mkdir -p "$state/lib" "$state/orgs" "$state/install/templates" "$state/slots"
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
printf 'SLOT_STATE_DIR="%s"\n' "$state/slots" >> "$state/lib/recycle.sh"
conf=$state/orgs/acme.conf
add_org() {
    printf '%s' "$1" | "$BASH" "$state/lib/add-org.sh" >/dev/null 2>"$state/err" ||
        fail "add-org failed: $(cat "$state/err")"
}
# GITHUB_PAT/RUNNER_PREFIX/RUNNER_COUNT/RUNNER_GROUP_ID/RUNNER_LABELS as
# load_org_config sees them, sourced under set -u; or the error.
sourced() {
    # shellcheck disable=SC2016 # expands in the child shell
    "$BASH" -uc 'source "$1" && printf "%s/%s/%s/%s/%s" "$GITHUB_PAT" "$RUNNER_PREFIX" "$RUNNER_COUNT" "$RUNNER_GROUP_ID" "${RUNNER_LABELS:-}"' \
        _ "$conf" 2>&1 || true
}

# A hand-edited config in the natural order. Rotation input: org, confirm,
# PAT, then Enter to keep the prefix, count and group.
cat > "$conf" <<'EOF'
# GPU pool: labels set by hand
GITHUB_ORG="acme"
GITHUB_PAT="ghp_old"
RUNNER_PREFIX="gpu"
RUNNER_COUNT="3"
RUNNER_GROUP_ID="7"
RUNNER_LABELS="self-hosted,linux,x64,${RUNNER_PREFIX},${GITHUB_ORG}"
EOF
[[ "$(sourced)" == ghp_old/gpu/3/7/self-hosted,linux,x64,gpu,acme ]] || fail "the seed config does not source: $(sourced)"
expected=$(sed 's/ghp_old/ghp_new/' "$conf")
add_org $'acme\ny\nghp_new\n\n\n\n'
[[ "$(sourced)" == ghp_new/gpu/3/7/self-hosted,linux,x64,gpu,acme ]] ||
    fail "after a PAT rotation the config no longer sources under set -u: $(sourced)"
[[ "$(cat "$conf")" == "$expected" ]] || fail "a PAT rotation moved lines: $(cat "$conf")"

# A pool change: the kept line expands the new prefix.
add_org $'acme\ny\nghp_newer\nci\n4\n9\n'
[[ "$(sourced)" == ghp_newer/ci/4/9/self-hosted,linux,x64,ci,acme ]] ||
    fail "after a pool change the kept line does not see the new prefix: $(sourced)"
# shellcheck disable=SC2016 # a literal line of the config
[[ "$(sed -n 7p "$conf")" == 'RUNNER_LABELS="self-hosted,linux,x64,${RUNNER_PREFIX},${GITHUB_ORG}"' ]] ||
    fail "a pool change moved the kept line: $(cat "$conf")"

# A later line that sets a key another way must not override the new value,
# and a block around one must still parse.
cat > "$conf" <<'EOF'
GITHUB_ORG="acme"
GITHUB_PAT="ghp_old"
RUNNER_PREFIX="gpu"
RUNNER_COUNT="3"
RUNNER_GROUP_ID="7"
RUNNER_LABELS="${RUNNER_PREFIX}"
export GITHUB_PAT="ghp_old2"
if [[ -n "$RUNNER_LABELS" ]]; then
    RUNNER_COUNT="5"
fi
EOF
[[ "$(sourced)" == ghp_old2/gpu/5/7/gpu ]] || fail "the seed config with later assignments does not source: $(sourced)"
add_org $'acme\ny\nghp_new\n\n\n\n'
[[ "$(sourced)" == ghp_new/gpu/3/7/gpu ]] || fail "a later export or indented line overrode a new value: $(sourced)"
if grep -q ghp_old "$conf"; then fail "an old PAT is still in the config: $(cat "$conf")"; fi
[[ "$(wc -l < "$conf")" -eq 10 ]] || fail "a line was dropped or added: $(cat "$conf")"

# A key the file lacked goes at the end, after a last line with no newline.
# shellcheck disable=SC2016 # literal lines of the config
printf '# made by hand\nGITHUB_ORG="acme"\nGITHUB_PAT="ghp_old"\nRUNNER_PREFIX="gpu"\nRUNNER_COUNT="3"\nRUNNER_LABELS="${GITHUB_ORG}"' > "$conf"
add_org $'acme\ny\nghp_new\n\n\n\n'
[[ "$(sourced)" == ghp_new/gpu/3/1/acme ]] || fail "a config that lacked a key does not source: $(sourced)"
[[ "$(tail -n 2 "$conf")" == $'RUNNER_LABELS="${GITHUB_ORG}"\nRUNNER_GROUP_ID="1"' ]] ||
    fail "the missing key was not added on its own line at the end: $(cat "$conf")"

printf 'orgs2-config-order: ok\n'
