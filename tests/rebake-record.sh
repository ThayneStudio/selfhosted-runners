#!/usr/bin/env bash
# The baked-version record says which template it describes. A record for a
# template other than the live TEMPLATE_ID must not suppress the next bake, and
# the template it names, which nothing else lists, is queued for retirement.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'rebake-record: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'rebake-record: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# These globals are read by the sourced rebake functions.
# shellcheck disable=SC2034
{
    STATE_DIR=$state/lib
    BAKED_VERSION_FILE=$STATE_DIR/baked-runner-version
    RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
    PENDING_BAKE_FILE=$STATE_DIR/pending-bake
    PENDING_VERSION_FILE=$STATE_DIR/pending-version
    REBAKE_LOCK_FILE=$state/rebake.lock
    CONFIG_FILE=$state/github-runners.conf
}
mkdir -p "$STATE_DIR"
baked=$state/baked
day=86400
now=$(date -u +%s)

# Host commands for rebake_main. Every listed VM is a converted
# ubuntu-cloud-template with no linked clones.
require_root() { :; }
flock() { :; }
qm() {
    case "$1" in
        status) [[ "$2" == 9000 || "$2" == 9005 ]] ;;
        config) printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1\n' "$2" ;;
        *) return 1 ;;
    esac
}
pvesh() { printf '[{"vmid":9000,"type":"qemu"},{"vmid":9005,"type":"qemu"}]\n'; }
template_has_linked_clones() { return 0; }
curl() { printf '{"tag_name":"v2.330.0","published_at":"2026-09-01T00:00:00Z"}\n'; }
perform_bake() { : > "$baked"; }

# Runs one daily check with TEMPLATE_ID=$1 and the record given on stdin.
daily_check() {
    printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=%s\nMIN_VMID=9001\n' "$1" > "$CONFIG_FILE"
    cat > "$BAKED_VERSION_FILE"
    rm -f "$baked"
    (rebake_main --foreground) || fail "rebake_main failed"
}
retired() { if [[ -e "$RETIRED_TEMPLATES_FILE" ]]; then tr '\n' ' ' < "$RETIRED_TEMPLATES_FILE"; fi; }

# A fresh record for the live template: no bake.
daily_check 9000 <<EOF
version=2.330.0
published_at=2026-09-01T00:00:00Z
template_id=9000
baked_at=$((now - day))
EOF
[[ ! -e "$baked" ]] || fail "a fresh record for the live template started a bake"

# Setup pointed TEMPLATE_ID back at 9000 after a rebake had published 9005.
# The record still describes 9005: bake once, and queue 9005 for retirement.
printf '9000\n' > "$RETIRED_TEMPLATES_FILE"
daily_check 9000 <<EOF
version=2.330.0
published_at=2026-09-01T00:00:00Z
template_id=9005
baked_at=$((now - day))
EOF
[[ -e "$baked" ]] || fail "a record for template 9005 suppressed the bake of live template 9000"
[[ "$(retired)" == "9005 " ]] || fail "template 9005 was not queued for retirement: $(retired)"

# Older and hand-written records have no template_id; they still count.
rm -f "$RETIRED_TEMPLATES_FILE"
daily_check 9000 <<EOF
version=2.330.0
published_at=''
baked_at=$((now - day))
EOF
[[ ! -e "$baked" ]] || fail "a record without template_id started a bake"
[[ -z "$(retired)" ]] || fail "a record without template_id queued a retirement: $(retired)"

printf 'rebake-record: ok\n'
