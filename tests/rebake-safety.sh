#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'rebake-safety: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'rebake-safety: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
STATE_DIR=$state
PENDING_BAKE_FILE=$state/pending-bake
PENDING_VERSION_FILE=$state/pending-version
RETIRED_TEMPLATES_FILE=$state/retired-templates
TEMPLATE_ID=9100
VM_STORAGE=local
actions=$state/actions
: > "$actions"

# Only qm/pvesh are mocked: exercise the real retirement and recovery paths.
status_fails=1
mock_inventory='[{"vmid":9000,"type":"qemu"}]'
inventory_fails=0
has_clone=1
qm() {
    case "$1" in
        status) [[ "$status_fails" == 0 ]] ;;
        config) printf 'name: ubuntu-cloud-template\ntemplate: 1\nscsi0: local:9000/base-9000-disk-0.qcow2,size=30G\n' ;;
        stop|destroy) printf '%s %s\n' "$1" "$2" >> "$actions" ;;
        *) return 1 ;;
    esac
}
pvesh() {
    [[ "$inventory_fails" == 0 ]] || return 1
    printf '%s\n' "$mock_inventory"
}
pvesm() {
    case "$1" in
        list)
            printf 'Volid Format Type Size VMID\nlocal:9000/base-9000-disk-0.qcow2 qcow2 images 1 9000\n'
            if [[ "$has_clone" == 1 ]]; then
                printf 'local:9000/base-9000-disk-0.qcow2/9001/vm-9001-disk-0.qcow2 qcow2 images 1 9001\n'
            fi
            # An independent VM and a clone of another base must not match.
            printf 'local:9002/vm-9002-disk-0.qcow2 qcow2 images 1 9002\nlocal:8999/base-8999-disk-0.qcow2/9003/vm-9003-disk-0.qcow2 qcow2 images 1 9003\n'
            ;;
        path) printf '/var/lib/vz/images/9000/base-9000-disk-0.qcow2\n' ;;
        *) return 1 ;;
    esac
}
seed_records() {
    printf '9000\n' > "$PENDING_BAKE_FILE"
    printf 'version=2.329.0\n' > "$PENDING_VERSION_FILE"
    printf '9000\n' > "$RETIRED_TEMPLATES_FILE"
}
assert_pending() {
    [[ "$(cat "$PENDING_BAKE_FILE")" == 9000 ]] || fail "pending VMID was changed"
    [[ "$(cat "$PENDING_VERSION_FILE")" == version=2.329.0 ]] || fail "pending version was changed"
}

# Presence, failed inventory, and malformed inventory all retain records.
for condition in present unavailable malformed invalid_entry; do
    seed_records
    inventory_fails=0
    mock_inventory='[{"vmid":9000,"type":"qemu"}]'
    case "$condition" in
        unavailable) inventory_fails=1 ;;
        malformed) mock_inventory='not JSON' ;;
        invalid_entry) mock_inventory='[{}]' ;;
    esac
    if recover_pending_bake; then fail "$condition inventory allowed recovery to proceed"; fi
    assert_pending
    retire_retired_templates
    [[ "$(cat "$RETIRED_TEMPLATES_FILE")" == 9000 ]] || fail "$condition inventory dropped retirement record"
    [[ ! -s "$actions" ]] || fail "failed status lookup mutated a VM"
done

# EXIT cleanup must preserve the same recovery information and report failure.
inventory_fails=1
BAKE_VMID=9000
REBAKE_PUBLISHED=0
release_vmid_reservation() { :; }
if (cleanup_rebake); then fail "cleanup reported success after an inconclusive lookup"; fi
assert_pending

# A successful inventory proving absence still clears stale records.
inventory_fails=0
mock_inventory='[]'
recover_pending_bake
[[ ! -e "$PENDING_BAKE_FILE" && ! -e "$PENDING_VERSION_FILE" ]] || fail "confirmed absence did not clear pending records"
retire_retired_templates
[[ ! -e "$RETIRED_TEMPLATES_FILE" ]] || fail "confirmed absence did not clear retirement record"

status_fails=0
expected='local:9000/base-9000-disk-0.qcow2/9001/vm-9001-disk-0.qcow2'
[[ "$(list_template_base_volids 9000)" == local:9000/base-9000-disk-0.qcow2 ]] || fail "directory base was missed"
[[ "$(list_template_linked_clone_volids 9000)" == "$expected" ]] || fail "directory clone listing was incorrect"
[[ "$(linked_clone_child_vmid "$expected")" == 9001 ]] || fail "directory clone VMID was missed"
printf '9000\n' > "$RETIRED_TEMPLATES_FILE"
retire_retired_templates
[[ ! -s "$actions" ]] || fail "template with a linked directory clone was destroyed"
[[ "$(cat "$RETIRED_TEMPLATES_FILE")" == 9000 ]] || fail "template with a linked clone was forgotten"

has_clone=0
[[ -z "$(list_template_linked_clone_volids 9000)" ]] || fail "unrelated directory volumes matched the template"
retire_retired_templates
[[ "$(cat "$actions")" == 'destroy 9000' ]] || fail "unused directory template was not retired"
[[ ! -e "$RETIRED_TEMPLATES_FILE" ]] || fail "destroyed template was retained"

# Flat ZFS base names and sibling origins must continue to work.
(
    VM_STORAGE=local-zfs
    qm() { printf 'scsi0: local-zfs:base-9000-disk-0,size=30G\n'; }
    pvesm() {
        case "$1" in
            list) printf 'local-zfs:base-9000-disk-0\nlocal-zfs:vm-9001-disk-0\n' ;;
            path) printf '/dev/zvol/rpool/data/%s\n' "${2#*:}" ;;
            *) return 1 ;;
        esac
    }
    origin_fails=0
    zfs() {
        case "$1" in
            list) return 0 ;;
            get)
                [[ "$origin_fails" == 0 ]] || return 1
                printf 'rpool/data/base-9000-disk-0@__base__\n'
                ;;
            *) return 1 ;;
        esac
    }
    [[ "$(list_template_linked_clone_volids 9000)" == local-zfs:vm-9001-disk-0 ]] || fail "ZFS linked clone was missed"
    origin_fails=1
    if list_template_linked_clone_volids 9000; then fail "failed ZFS origin lookup allowed retirement"; fi
)

printf 'rebake-safety: ok\n'
