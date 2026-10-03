#!/usr/bin/env bash
# Re-running add-org to rotate a PAT must keep every other line of the org
# config, such as a hand-set RUNNER_LABELS that fetch_jit_config sends to GitHub.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'orgs-pat-rotation: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'orgs-pat-rotation: %s\n' "$1" >&2; exit 1; }

# Run the real add-org.sh from a copy of lib/ whose common.sh points the host
# paths at a scratch dir, skips the root check, and mocks curl (HTTP 200).
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
mkdir -p "$state/lib" "$state/orgs" "$state/install/templates"
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
conf=$state/orgs/acme.conf
add_org() {
    printf '%s' "$1" | "$BASH" "$state/lib/add-org.sh" >/dev/null 2>"$state/err" ||
        fail "add-org failed: $(cat "$state/err")"
}
# Print GITHUB_PAT/RUNNER_PREFIX/RUNNER_COUNT/RUNNER_GROUP_ID/RUNNER_LABELS as
# the scripts that source the org config see them.
sourced() {
    (
        # shellcheck source=/dev/null
        source "$conf"
        printf '%s/%s/%s/%s/%s' "$GITHUB_PAT" "$RUNNER_PREFIX" "$RUNNER_COUNT" "$RUNNER_GROUP_ID" "${RUNNER_LABELS:-}"
    )
}
managed=$'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_new"\nRUNNER_PREFIX="gpu"\nRUNNER_COUNT="3"\nRUNNER_GROUP_ID="7"'

# A new org gets exactly the prompted keys.
add_org $'acme\nghp_new\ngpu\n3\n7\n'
[[ "$(cat "$conf")" == "$managed" ]] || fail "a new org config is not just the prompted keys"

# Rotation input: org, confirm, PAT, then Enter to keep prefix, count and group.
cat > "$conf" <<'EOF'
# GPU pool: labels set by hand
GITHUB_ORG="acme"
GITHUB_PAT="ghp_old"
RUNNER_PREFIX="gpu"
RUNNER_COUNT="3"
RUNNER_GROUP_ID="7"
RUNNER_LABELS="self-hosted,linux,x64,gpu"
EOF
add_org $'acme\ny\nghp_new\n\n\n\n'
[[ "$(sourced)" == ghp_new/gpu/3/7/self-hosted,linux,x64,gpu ]] || fail "rotation lost a setting: $(sourced)"
grep -qxF '# GPU pool: labels set by hand' "$conf" || fail "rotation dropped a comment"
# The prompted keys come last, once each, so they win over any kept line when
# sourced and the grep readers (watch, list-orgs) see the same values.
[[ "$(tail -n 5 "$conf")" == "$managed" ]] || fail "the prompted keys are not written last"
for key in GITHUB_ORG GITHUB_PAT RUNNER_PREFIX RUNNER_COUNT RUNNER_GROUP_ID RUNNER_LABELS; do
    [[ "$(grep -c "^$key=" "$conf")" == 1 ]] || fail "$key is not set exactly once"
done
if grep -q ghp_old "$conf"; then fail "the old PAT is still in the config"; fi

# A second update that changes the pool keeps the file's shape.
lines=$(wc -l < "$conf")
add_org $'acme\ny\nghp_newer\ngpu2\n4\n9\n'
[[ "$(sourced)" == ghp_newer/gpu2/4/9/self-hosted,linux,x64,gpu ]] || fail "a second update lost a setting: $(sourced)"
[[ "$(wc -l < "$conf")" == "$lines" ]] || fail "a second update changed the number of lines"

# A hand edit that left no newline at the end of the file.
printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_old"\nRUNNER_PREFIX="gpu"\nRUNNER_COUNT="3"\nRUNNER_GROUP_ID="7"\nRUNNER_LABELS="gpu"' > "$conf"
add_org $'acme\ny\nghp_new\n\n\n\n'
[[ "$(sourced)" == ghp_new/gpu/3/7/gpu ]] || fail "a last line without a newline was merged: $(sourced)"
grep -qxF 'GITHUB_ORG="acme"' "$conf" || fail "a last line without a newline swallowed GITHUB_ORG"

printf 'orgs-pat-rotation: ok\n'
