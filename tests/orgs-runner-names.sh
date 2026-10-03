#!/usr/bin/env bash
# Runner names become Proxmox VM names, and qm clone only accepts DNS names.
# add-org (for its slot prefix) and create must refuse anything else up front:
# otherwise every watcher tick mints a JIT runner whose clone then fails.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'orgs-runner-names: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'orgs-runner-names: %s\n' "$1" >&2; exit 1; }

valid=(runner-1 r 7 Runner-01 runner--1 my.pool-1 a.b.c-9 a1-b2.c3)
invalid=("" ci_runner-1 ci.-1 a..b-1 .runner-1 runner-1. -runner-1 runner- "run ner-1" a/b-1)
for name in "${valid[@]}"; do
    validate_runner_name "$name" || fail "rejected the valid VM name '$name'"
done
for name in "${invalid[@]}"; do
    if validate_runner_name "$name"; then fail "accepted the invalid VM name '$name'"; fi
done
# The same table must hold for Proxmox's own check (pve-common pve_verify_dns_name).
if command -v perl >/dev/null 2>&1; then
    pve_accepts() {
        perl -e 'my $namere = "([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)";
                 exit(($ARGV[0] =~ /^(${namere}\.)*${namere}\z/) ? 0 : 1)' -- "$1"
    }
    for name in "${valid[@]}"; do
        pve_accepts "$name" || fail "Proxmox would reject '$name'"
    done
    for name in "${invalid[@]}"; do
        if pve_accepts "$name"; then fail "Proxmox would accept '$name'"; fi
    done
fi

# Run the real scripts from a copy of lib/ whose common.sh points the host paths
# at a scratch dir, skips the root check, and mocks curl (200) and qm.
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
POOL_DRAIN_FILE="$state/drain"
require_root() { :; }
curl() { printf 'curl %s\n' "\${*: -1}" >> "$state/calls"; printf 200; }
qm() { printf 'qm %s\n' "\$*" >> "$state/calls"; return 1; }
EOF
conf=$state/orgs/acme.conf
add_org() {
    printf '%s' "$1" | "$BASH" "$state/lib/add-org.sh" >/dev/null 2>"$state/err"
}
create() {
    rm -f "$state/calls"
    "$BASH" "$state/lib/create.sh" "$1" >/dev/null 2>"$state/err"
}

# add-org input: org, PAT, prefix, then the count and group defaults.
for prefix in ci_runner ci. a..b; do
    if add_org $'acme\nghp_test\n'"$prefix"$'\n\n\n'; then fail "add-org accepted the prefix '$prefix'"; fi
    grep -q 'Invalid prefix' "$state/err" || fail "add-org did not refuse the prefix '$prefix' as invalid: $(cat "$state/err")"
    [[ -z "$(ls -A "$state/orgs")" ]] || fail "add-org wrote a config for the prefix '$prefix'"
done
for prefix in ci-runner my.pool runner-; do
    add_org $'acme\nghp_test\n'"$prefix"$'\n\n\n' || fail "add-org refused the prefix '$prefix': $(cat "$state/err")"
    grep -qxF "RUNNER_PREFIX=\"$prefix\"" "$conf" || fail "add-org did not save the prefix '$prefix'"
    rm -f "$conf"
done
# A saved prefix that never worked is refused as the default, and nothing is written.
printf 'GITHUB_ORG="acme"\nGITHUB_PAT="ghp_old"\nRUNNER_PREFIX="ci_runner"\nRUNNER_COUNT="2"\nRUNNER_GROUP_ID="1"\n' > "$conf"
cp "$conf" "$state/saved"
if add_org $'acme\ny\nghp_new\n\n\n\n'; then fail "add-org kept the saved prefix 'ci_runner'"; fi
cmp -s "$conf" "$state/saved" || fail "a refused prefix still rewrote the org config"
rm -f "$conf"

# create refuses the name before any GitHub or qm call. With no org configured,
# a valid name gets as far as choosing the org.
for name in my_runner foo- foo. a..b .foo; do
    if create "$name"; then fail "create accepted the name '$name'"; fi
    grep -q 'Invalid runner name' "$state/err" || fail "create did not refuse the name '$name' up front: $(cat "$state/err")"
    [[ ! -e "$state/calls" ]] || fail "create called GitHub or qm for the name '$name'"
done
for name in runner-01 my.pool-1; do
    if create "$name"; then fail "create succeeded with no org configured"; fi
    grep -q 'No organizations configured' "$state/err" || fail "create refused the valid name '$name': $(cat "$state/err")"
done

printf 'orgs-runner-names: ok\n'
