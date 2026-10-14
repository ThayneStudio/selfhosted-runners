#!/usr/bin/env bash
# remove-org must say what happens to the org's runner VMs. They do not become
# unmanaged: once the org is gone, the pool destroys each one when it stops
# and clones nothing in its place (tests/pool-retire.sh checks that).
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'orgs2-remove-org: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'orgs2-remove-org: %s\n' "$1" >&2; exit 1; }

# Run the real remove-org.sh from a copy of lib/ whose host paths point at a
# scratch dir, with the root check skipped and qm mocked: VM 9001 is acme's
# gpu-1, VM 9002 is beta's other-1.
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
mkdir -p "$state/lib" "$state/orgs" "$state/snippets"
cp "$root"/lib/*.sh "$state/lib/"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=9000\n' > "$state/github-runners.conf"
cat >> "$state/lib/common.sh" <<EOF
CONFIG_FILE="$state/github-runners.conf"
ORG_CONFIG_DIR="$state/orgs"
SNIPPETS_DIR="$state/snippets"
require_root() { :; }
EOF
cat >> "$state/lib/common.sh" <<'EOF'
qm() {
    case "$1 ${2:-}" in
        "list ")
            printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
            printf '      9001 gpu-1                running    8192              30.00 4242\n'
            printf '      9002 other-1              running    8192              30.00 4243\n'
            ;;
        "config 9001") printf 'name: gpu-1\ncicustom: user=local:snippets/runner-9001-user-acme.yaml,meta=local:snippets/runner-9001-meta.yaml\n' ;;
        "config 9002") printf 'name: other-1\ncicustom: user=local:snippets/runner-9002-user-beta.yaml,meta=local:snippets/runner-9002-meta.yaml\n' ;;
        *) return 2 ;;
    esac
}
EOF
for org in acme beta; do
    printf 'GITHUB_ORG="%s"\nGITHUB_PAT="ghp_test"\n' "$org" > "$state/orgs/$org.conf"
done

printf 'yes\n' | "$BASH" "$state/lib/remove-org.sh" acme > "$state/out" 2>&1 ||
    fail "remove-org failed: $(cat "$state/out")"
[[ ! -e "$state/orgs/acme.conf" ]] || fail "the org config was not removed"
[[ -e "$state/orgs/beta.conf" ]] || fail "another org's config was removed"
grep -q 'gpu-1 (VMID: 9001)' "$state/out" || fail "the org's runner VM was not listed: $(cat "$state/out")"
if grep -q 'other-1' "$state/out"; then fail "another org's runner VM was listed"; fi
if grep -qi 'unmanaged' "$state/out"; then
    fail "remove-org still says the org's VMs become unmanaged: $(cat "$state/out")"
fi
grep -q "1 runner VM(s) of 'acme' remain" "$state/out" || fail "the warning does not count the org's VMs: $(cat "$state/out")"
grep -q 'each one is destroyed,' "$state/out" || fail "the warning does not say the VMs are destroyed: $(cat "$state/out")"
grep -q 'not re-cloned, when it stops' "$state/out" || fail "the warning does not say the VMs are not re-cloned: $(cat "$state/out")"
grep -q "run 'runner destroy <name>' for each once the org is removed" "$state/out" ||
    fail "the warning does not say how to remove the VMs sooner: $(cat "$state/out")"

printf 'orgs2-remove-org: ok\n'
