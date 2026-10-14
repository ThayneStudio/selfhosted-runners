#!/usr/bin/env bash
# Rebake destroys must not pass --purge: it also deletes the VMID from every
# backup job's include and exclude lists, and runner VMIDs are handed out again.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'rebake-destroy: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'rebake-destroy: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# These globals are read by the sourced rebake functions.
# shellcheck disable=SC2034
{
    STATE_DIR=$state
    PENDING_BAKE_FILE=$state/pending-bake
    PENDING_VERSION_FILE=$state/pending-version
    RETIRED_TEMPLATES_FILE=$state/retired-templates
    TEMPLATE_ID=9000
    VM_STORAGE=local
    REBAKE_PUBLISHED=0
}
actions=$state/actions
: > "$actions"

# 9001 is a failed bake, 9005 an unused retired template on dir storage.
qm() {
    printf '%s\n' "$*" >> "$actions"
    case "$1" in
        status) [[ "$2" == 9001 || "$2" == 9005 ]] ;;
        config)
            case "$2" in
                9001) printf 'name: ubuntu-cloud-template\nscsi0: local:9001/vm-9001-disk-0.raw,size=30G\n' ;;
                9005) printf 'name: ubuntu-cloud-template\nscsi0: local:9005/base-9005-disk-0.raw,size=30G\ntemplate: 1\n' ;;
                *) return 2 ;;
            esac
            ;;
        stop|destroy) return 0 ;;
        *) return 1 ;;
    esac
}
pvesm() {
    case "$1" in
        list) printf 'Volid Format Type Size VMID\nlocal:9005/base-9005-disk-0.raw raw images 1 9005\n' ;;
        path) printf '/var/lib/vz/images/9005/base-9005-disk-0.raw\n' ;;
        *) return 1 ;;
    esac
}
release_vmid_reservation() { :; }

BAKE_VMID=9001
printf '9001\n' > "$PENDING_BAKE_FILE"
if (cleanup_rebake 1); then fail "cleanup_rebake reported success after a failed bake"; fi
grep -q '^destroy 9001' "$actions" || fail "cleanup_rebake did not destroy the failed bake VM"

printf '9001\n' > "$PENDING_BAKE_FILE"
recover_pending_bake || fail "recover_pending_bake could not destroy the incomplete VM"
[[ "$(grep -c '^destroy 9001' "$actions")" == 2 ]] || fail "recover_pending_bake did not destroy the incomplete VM"

printf '9005\n' > "$RETIRED_TEMPLATES_FILE"
retire_retired_templates || fail "retire_retired_templates failed"
grep -q '^destroy 9005' "$actions" || fail "an unused retired template was not destroyed"

if grep -- '--purge' "$actions" >&2; then
    fail "a rebake destroy passed --purge"
fi

printf 'rebake-destroy: ok\n'
