#!/usr/bin/env bash
# The baked-version record says which template it describes and which Docker
# mirror that template was baked with. A record for a template other than the
# live TEMPLATE_ID, or for another mirror, must not suppress the next bake. The
# template a stale record names, which nothing else lists, is queued for
# retirement.
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

# Runs one daily check against a config written the way setup writes it, with
# TEMPLATE_ID=$1 and DOCKER_MIRROR_URL=$2. The record is already in place.
write_config() {
    {
        printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=%q\n' "$1"
        printf 'MIN_VMID=9001\nDOCKER_MIRROR_URL=%q\n' "${2:-}"
    } > "$CONFIG_FILE"
    rm -f "$baked"
}
# rebake_main relies on errexit, as when `runner rebake` runs it. Bash ignores
# errexit in anything run under `if`, `&&` or `||`, even after `set -e`, so
# run it as a plain statement and keep its status in rebake_rc.
run_rebake() {
    set +e
    (set -e; rebake_main --foreground)
    rebake_rc=$?
    set -e
}
daily_check() {
    write_config "$@"
    run_rebake
    [[ "$rebake_rc" == 0 ]] || fail "rebake_main failed"
}
record() { cat > "$BAKED_VERSION_FILE"; }
retired() { if [[ -e "$RETIRED_TEMPLATES_FILE" ]]; then tr '\n' ' ' < "$RETIRED_TEMPLATES_FILE"; fi; }

# A fresh record for the live template: no bake.
record <<EOF
version=2.330.0
published_at=2026-09-01T00:00:00Z
template_id=9000
baked_at=$((now - day))
EOF
daily_check 9000
[[ ! -e "$baked" ]] || fail "a fresh record for the live template started a bake"

# Setup pointed TEMPLATE_ID back at 9000 after a rebake had published 9005.
# The record still describes 9005: bake once, and queue 9005 for retirement.
printf '9000\n' > "$RETIRED_TEMPLATES_FILE"
record <<EOF
version=2.330.0
published_at=2026-09-01T00:00:00Z
template_id=9005
baked_at=$((now - day))
EOF
daily_check 9000
[[ -e "$baked" ]] || fail "a record for template 9005 suppressed the bake of live template 9000"
[[ "$(retired)" == "9005 " ]] || fail "template 9005 was not queued for retirement: $(retired)"

# If 9005 cannot be queued (ENOSPC), do not bake: the bake would move
# TEMPLATE_ID on and leave 9005 recorded nowhere.
rm -f "$RETIRED_TEMPLATES_FILE"
write_config 9000
mktemp() {
    if [[ "${1:-}" == "$STATE_DIR/.retired."* ]]; then return 1; fi
    command mktemp "$@"
}
run_rebake
unset -f mktemp
[[ "$rebake_rc" != 0 ]] || fail "rebake_main succeeded although 9005 could not be queued"
[[ ! -e "$baked" ]] || fail "baked although template 9005 could not be queued for retirement"

# Older and hand-written records have no template_id or docker_mirror_url;
# they still count.
rm -f "$RETIRED_TEMPLATES_FILE"
record <<EOF
version=2.330.0
published_at=''
baked_at=$((now - day))
EOF
daily_check 9000 http://10.0.0.20:5000
[[ ! -e "$baked" ]] || fail "a record without template_id or docker_mirror_url started a bake"
[[ -z "$(retired)" ]] || fail "a record without template_id queued a retirement: $(retired)"

# The record keeps the mirror the template was baked with. Setup changing it
# (scheme or host, or adding or removing one) bakes once; the same mirror,
# written and read back by the real code, does not.
for mirror in "" http://10.0.0.20:5000 https://mirror.example:5000 'http://[fd00::20]:5000'; do
    DOCKER_MIRROR_URL=$mirror
    commit_baked_version 2.330.0 9000 || fail "commit_baked_version failed for mirror '${mirror}'"
    for configured in "" http://10.0.0.20:5000 http://10.0.0.21:5000 https://mirror.example:5000 'http://[fd00::20]:5000'; do
        daily_check 9000 "$configured"
        if [[ "$configured" == "$mirror" && -e "$baked" ]]; then
            fail "a template baked with mirror '${mirror}' was rebaked although the mirror is unchanged"
        fi
        if [[ "$configured" != "$mirror" && ! -e "$baked" ]]; then
            fail "a template baked with mirror '${mirror}' was kept after the mirror changed to '${configured}'"
        fi
    done
done
unset DOCKER_MIRROR_URL

printf 'rebake-record: ok\n'
