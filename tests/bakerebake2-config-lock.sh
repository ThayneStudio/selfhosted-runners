#!/usr/bin/env bash
# setup bakes under the rebake lock and then moves TEMPLATE_ID to its new
# template. A rebake that read the config before it took the lock acted on the
# template setup had just replaced: it queued setup's new template for
# retirement, or published over it and left it recorded nowhere. The rebake
# must read the config only under the lock.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'bakerebake2-config-lock: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'bakerebake2-config-lock: %s\n' "$1" >&2; exit 1; }
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
now=$(date -u +%s)

# Host commands for rebake_main. Every VM is a converted ubuntu-cloud-template
# that linked clones still use, so retirement never destroys one.
require_root() { :; }
qm() {
    case "$1" in
        status) [[ "$2" == 9000 || "$2" == 9100 || "$2" == 9200 ]] ;;
        config) printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1\n' "$2" ;;
        *) return 1 ;;
    esac
}
pvesh() { printf '[{"vmid":9000,"type":"qemu"},{"vmid":9100,"type":"qemu"},{"vmid":9200,"type":"qemu"}]\n'; }
template_has_linked_clones() { return 0; }
curl() { printf '{"tag_name":"v2.330.0","published_at":"2026-09-01T00:00:00Z"}\n'; }
# A bake publishes template 9200.
perform_bake() {
    : > "$baked"
    switch_template_id 9200
}

write_config() {
    printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=%q\nMIN_VMID=9001\n' "$1" > "$CONFIG_FILE"
}
record() {
    printf 'version=%s\npublished_at=2026-09-01T00:00:00Z\ntemplate_id=%s\nbaked_at=%s\n' "$1" "$2" "$3" \
        > "$BAKED_VERSION_FILE"
}
retired() { if [[ -e "$RETIRED_TEMPLATES_FILE" ]]; then tr '\n' ' ' < "$RETIRED_TEMPLATES_FILE"; fi; }
config_template() { sed -n 's/^TEMPLATE_ID=//p' "$CONFIG_FILE"; }

# The rebake starts while setup bakes template 9100 beside live template 9000.
# setup's switch lands, and setup releases the lock, just before the rebake
# takes it: the mocked flock writes what setup writes and then succeeds.
setup_switch() {
    write_config 9100
    printf '9000\n' > "$RETIRED_TEMPLATES_FILE"
}
setup_switch_and_record() {
    setup_switch
    record 2.330.0 9100 "$now"
}
on_lock=""
flock() {
    [[ -z "$on_lock" ]] || "$on_lock"
    on_lock=""
}
# rebake_main relies on errexit, as when `runner rebake` runs it.
run_rebake() {
    rm -f "$baked" "$RETIRED_TEMPLATES_FILE"
    on_lock=$1
    set +e
    (set -e; rebake_main --foreground) 2>"$state/log"
    rebake_rc=$?
    set -e
    [[ "$rebake_rc" == 0 ]] || fail "rebake_main failed: $(cat "$state/log")"
}

# setup also recorded its bake: the current release on template 9100. Nothing
# is stale, so the rebake neither bakes nor touches setup's template.
write_config 9000
record 2.330.0 9000 "$((now - 86400))"
run_rebake setup_switch_and_record
[[ ! -e "$baked" ]] || fail "the rebake baked over setup's fresh template 9100: $(cat "$state/log")"
[[ "$(retired)" == "9000 " ]] || fail "setup's template 9100 was queued for retirement: $(retired)"
[[ "$(config_template)" == 9100 ]] || fail "TEMPLATE_ID moved off setup's template: $(config_template)"

# setup's record has not landed yet and the old one is stale, so the rebake
# bakes and publishes 9200. Template 9100, which it replaces, must be queued
# for retirement; nothing else would ever list it.
write_config 9000
record 2.329.0 9000 "$((now - 86400))"
run_rebake setup_switch
[[ -e "$baked" ]] || fail "a stale record did not bake: $(cat "$state/log")"
[[ "$(config_template)" == 9200 ]] || fail "TEMPLATE_ID is not the new template: $(config_template)"
[[ " $(retired)" == *" 9100 "* ]] || fail "setup's template 9100 leaked: retired list is '$(retired)'"
[[ " $(retired)" == *" 9000 "* ]] || fail "template 9000 left the retired list: $(retired)"

printf 'bakerebake2-config-lock: ok\n'
