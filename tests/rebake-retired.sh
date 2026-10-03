#!/usr/bin/env bash
# The retired-template list is the only thing that ever destroys an old
# template, so no failed write may lose an entry: the old template is recorded
# before TEMPLATE_ID moves, and a failed rewrite keeps the previous list.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'rebake-retired: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'rebake-retired: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# These globals are read by the sourced rebake functions.
# shellcheck disable=SC2034
{
    STATE_DIR=$state/lib
    RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
    CONFIG_FILE=$state/github-runners.conf
}
mkdir -p "$STATE_DIR"

# Failures hit only writes of the retired list; the config write also uses
# mktemp and mv and must keep working. short-write is ENOSPC part-way
# through: a truncated temp file and a failed write.
inject() {
    case "$1" in
        mktemp)
            mktemp() {
                if [[ "${1:-}" == "$STATE_DIR/.retired."* ]]; then return 1; fi
                command mktemp "$@"
            }
            ;;
        short-write)
            # Called by the code under test; it forwards the caller's format.
            # shellcheck disable=SC2329,SC2059
            printf() {
                if [[ "${1:-}" == '%s\n' && "${2:-}" =~ ^[0-9]+$ ]]; then
                    builtin printf '%s' "${2:0:2}"
                    return 1
                fi
                builtin printf "$@"
            }
            ;;
        rename)
            mv() {
                if [[ "${*: -1}" == "$RETIRED_TEMPLATES_FILE" ]]; then return 1; fi
                command mv "$@"
            }
            ;;
    esac
}
clear_injection() { unset -f mktemp printf mv; }
list() { if [[ -e "$RETIRED_TEMPLATES_FILE" ]]; then tr '\n' ' ' < "$RETIRED_TEMPLATES_FILE"; else printf '<none>'; fi; }
seed_config() {
    printf 'TEMPLATE_ID=9000\nNETWORK_BRIDGE=vmbr0\n' > "$CONFIG_FILE"
    cp "$CONFIG_FILE" "$state/config.orig"
    TEMPLATE_ID=9000
}
no_leftovers() {
    local f
    for f in "$STATE_DIR"/.retired.*; do
        [[ ! -e "$f" ]] || fail "$1 left $f"
    done
}

# A successful switch lists the old template.
seed_config
printf '8999\n' > "$RETIRED_TEMPLATES_FILE"
switch_template_id 9001 || fail "switch_template_id failed"
[[ "$TEMPLATE_ID" == 9001 ]] || fail "TEMPLATE_ID was not switched"
[[ "$(list)" == "8999 9000 " ]] || fail "the old template was not listed: $(list)"

# An entry without a trailing newline is not glued to the next one.
seed_config
printf '8999' > "$RETIRED_TEMPLATES_FILE"
switch_template_id 9001 || fail "switch_template_id failed after an unterminated entry"
[[ "$(list)" == "8999 9000 " ]] || fail "an unterminated entry merged with the new one: $(list)"

# When the old template cannot be recorded, TEMPLATE_ID must not move: once
# it has, nothing would ever retire the old one.
for failure in mktemp short-write rename; do
    seed_config
    printf '8999\n' > "$RETIRED_TEMPLATES_FILE"
    inject "$failure"
    status=0
    switch_template_id 9001 || status=$?
    clear_injection
    [[ "$status" -ne 0 ]] || fail "$failure: switch_template_id succeeded without recording the old template"
    [[ "$TEMPLATE_ID" == 9000 ]] || fail "$failure: TEMPLATE_ID moved without recording the old template"
    cmp -s "$CONFIG_FILE" "$state/config.orig" || fail "$failure: the config changed without recording the old template"
    [[ "$(list)" == "8999 " ]] || fail "$failure: the retired list changed: $(list)"
    no_leftovers "$failure"
done

# A failed config write keeps the old template live, so it is not left listed.
seed_config
printf '8999\n' > "$RETIRED_TEMPLATES_FILE"
set_conf_assignment() { return 1; }
status=0
switch_template_id 9001 || status=$?
unset -f set_conf_assignment
[[ "$status" -ne 0 ]] || fail "switch_template_id succeeded after the config write failed"
[[ "$TEMPLATE_ID" == 9000 ]] || fail "TEMPLATE_ID moved after the config write failed"
[[ "$(list)" == "8999 " ]] || fail "the live template was left listed for retirement: $(list)"

# Retirement keeps 9000 (it still has linked clones) and drops 9005 (gone).
TEMPLATE_ID=9010
qm() {
    case "$1" in
        status) [[ "$2" == 9000 ]] ;;
        config) printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:base-9000-disk-0,size=30G\ntemplate: 1\n' ;;
        *) return 1 ;;
    esac
}
pvesh() { printf '[{"vmid":9000,"type":"qemu"}]\n'; }
template_has_linked_clones() { [[ "$1" == 9000 ]]; }

# perform_bake runs it as `retire_retired_templates || true`: errexit is off
# inside, so every failed write has to be caught explicitly.
for failure in mktemp short-write rename; do
    printf '9000\n9005\n' > "$RETIRED_TEMPLATES_FILE"
    inject "$failure"
    status=0
    retire_retired_templates || status=$?
    clear_injection
    [[ "$status" -ne 0 ]] || fail "$failure: retire_retired_templates hid a failed rewrite"
    [[ "$(list)" == "9000 9005 " ]] || fail "$failure: a failed rewrite changed the retired list: $(list)"
    no_leftovers "retire after a $failure failure"
done

printf '9000\n9005\n' > "$RETIRED_TEMPLATES_FILE"
retire_retired_templates || fail "retire_retired_templates failed"
[[ "$(list)" == "9000 " ]] || fail "retirement did not keep 9000 and drop 9005: $(list)"
printf '9005\n' > "$RETIRED_TEMPLATES_FILE"
retire_retired_templates || fail "retire_retired_templates failed on an empty result"
[[ "$(list)" == "<none>" ]] || fail "an emptied retired list was kept: $(list)"

printf 'rebake-retired: ok\n'
