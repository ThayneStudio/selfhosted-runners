#!/usr/bin/env bash
# A VM is published as TEMPLATE_ID only once qm template has converted its
# disks. `qm template` exits 0 when its conversion worker fails, and Proxmox
# writes `template: 1` before converting, so neither may be trusted alone.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'rebake-publish: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'rebake-publish: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# These globals are read by the sourced rebake and bake functions.
# shellcheck disable=SC2034
{
    STATE_DIR=$state/lib
    PENDING_BAKE_FILE=$STATE_DIR/pending-bake
    PENDING_VERSION_FILE=$STATE_DIR/pending-version
    RETIRED_TEMPLATES_FILE=$STATE_DIR/retired-templates
    BAKED_VERSION_FILE=$STATE_DIR/baked-runner-version
    CONFIG_FILE=$state/github-runners.conf
    INSTALL_DIR=$root
    SNIPPETS_DIR=$state/snippets
    VM_STORAGE=local-zfs
    # rebake_main resolves the release before baking.
    LATEST_RUNNER_VERSION=2.330.0
}
mkdir -p "$STATE_DIR" "$SNIPPETS_DIR"
actions=$state/actions
vms=$state/vms
: > "$actions"

# Each VM is a directory: name, disk volume, template flag, power state, and
# whether the disk is attached as scsi0 (an imported disk is unused0 until
# `qm set --scsi0`). `qm template` sets the flag and exits 0; it converts the
# disk only when $state/convert says so, as when its worker fails after
# writing the flag.
add_vm() {
    mkdir -p "$vms/$1"
    printf '%s' "$2" > "$vms/$1/name"
    printf '%s' "$3" > "$vms/$1/disk"
    printf '%s' "$4" > "$vms/$1/template"
    printf stopped > "$vms/$1/power"
    if [[ "${5:-attached}" == attached ]]; then
        : > "$vms/$1/attached"
    fi
}
qm() {
    local cmd="$1" id="${2:-}"
    printf '%s\n' "$*" >> "$actions"
    case "$cmd" in
        # qemu-server >= 8.2.7 wording.
        importdisk) printf "unused0: successfully imported disk '%s'\n" "$(cat "$vms/$id/disk")" ;;
        set)
            [[ -d "$vms/$id" ]] || return 2
            if [[ " $* " == *" --scsi0 "* ]]; then
                : > "$vms/$id/attached"
            fi
            ;;
        resize) [[ -d "$vms/$id" ]] ;;
        start) printf running > "$vms/$id/power" ;;
        shutdown|stop) [[ ! -d "$vms/$id" ]] || printf stopped > "$vms/$id/power" ;;
        status)
            [[ -d "$vms/$id" ]] || return 2
            printf 'status: %s\n' "$(cat "$vms/$id/power")"
            ;;
        config)
            [[ -d "$vms/$id" ]] || return 2
            printf 'name: %s\n' "$(cat "$vms/$id/name")"
            printf 'ide2: local-zfs:vm-%s-cloudinit,media=cdrom\n' "$id"
            if [[ -e "$vms/$id/attached" ]]; then
                printf 'scsi0: %s,size=30G\n' "$(cat "$vms/$id/disk")"
            else
                printf 'unused0: %s\n' "$(cat "$vms/$id/disk")"
            fi
            if [[ "$(cat "$vms/$id/template")" == 1 ]]; then
                printf 'template: 1\n'
            fi
            ;;
        guest)
            # qm guest exec <vmid> -- <command...>
            case "${*:4}" in
                *template-setup-complete*) printf '{"exitcode":0,"exited":1}\n' ;;
                *baked-runner-version*) printf '{"exitcode":0,"exited":1,"out-data":"2.330.0\\n"}\n' ;;
                *) printf '{"exitcode":0,"exited":1}\n' ;;
            esac
            ;;
        template)
            id="$2"
            printf 1 > "$vms/$id/template"
            if [[ "$(cat "$state/convert")" == 1 ]]; then
                printf 'local-zfs:base-%s-disk-0' "$id" > "$vms/$id/disk"
            fi
            ;;
        destroy) rm -rf "${vms:?}/$id" ;;
        *) return 1 ;;
    esac
}
mock_inventory='[]'
pvesh() { printf '%s\n' "$mock_inventory"; }
# No volumes are left over on the storage.
pvesm() {
    case "$1" in
        list) printf 'Volid Format Type Size VMID\n' ;;
        *) return 1 ;;
    esac
}
curl() { return 22; }
sleep() { :; }
release_vmid_reservation() { :; }
reset_host() {
    rm -rf "$vms" "${STATE_DIR:?}"/*
    mkdir -p "$vms"
    : > "$actions"
    printf 'TEMPLATE_ID=9000\nVM_STORAGE=local-zfs\n' > "$CONFIG_FILE"
    TEMPLATE_ID=9000
    REBAKE_PUBLISHED=0
    add_vm 9000 ubuntu-cloud-template local-zfs:base-9000-disk-0 1
}
destroyed() { grep -Eq "^destroy $1( |$)" "$actions"; }

# The bake: qm template exits 0 but leaves scsi0 a vm- volume.
reset_host
add_vm 9001 ubuntu-cloud-template local-zfs:vm-9001-disk-0 0 imported
printf 0 > "$state/convert"
if bake_and_publish_vm 9001; then
    fail "bake_and_publish_vm accepted a template whose disk was not converted"
fi
[[ "$REBAKE_PUBLISHED" == 0 ]] || fail "an unconverted template was marked published"
grep -q '^template 9001' "$actions" || fail "the bake never reached qm template"

# The same bake with a real conversion publishes.
reset_host
add_vm 9001 ubuntu-cloud-template local-zfs:vm-9001-disk-0 0 imported
printf 1 > "$state/convert"
bake_and_publish_vm 9001 || fail "bake_and_publish_vm rejected a converted template"
[[ "$REBAKE_PUBLISHED" == 1 ]] || fail "a converted template was not marked published"
[[ "$BAKE_RUNNER_VERSION" == 2.330.0 ]] || fail "the baked runner version was not read"

# cleanup_rebake: `template: 1` over an unconverted disk is a failed bake.
reset_host
add_vm 9001 ubuntu-cloud-template local-zfs:vm-9001-disk-0 1
printf '9001\n' > "$PENDING_BAKE_FILE"
BAKE_VMID=9001
if (cleanup_rebake 1); then fail "cleanup_rebake reported success after a failed bake"; fi
destroyed 9001 || fail "cleanup_rebake kept a half-converted template for the next run to publish"
[[ ! -e "$PENDING_BAKE_FILE" ]] || fail "cleanup_rebake kept the pending record of a destroyed VM"

# cleanup_rebake: a converted template is kept for the next run to publish.
reset_host
add_vm 9001 ubuntu-cloud-template local-zfs:base-9001-disk-0 1
printf '9001\n' > "$PENDING_BAKE_FILE"
BAKE_VMID=9001
if (cleanup_rebake 0); then fail "cleanup_rebake reported success with an unpublished template"; fi
! destroyed 9001 || fail "cleanup_rebake destroyed a converted template"
[[ -e "$PENDING_BAKE_FILE" ]] || fail "cleanup_rebake dropped the record of an unpublished template"

# cleanup_rebake never destroys the live template, converted or not.
reset_host
printf 'local-zfs:vm-9000-disk-0' > "$vms/9000/disk"
BAKE_VMID=9000
if (cleanup_rebake 1); then fail "cleanup_rebake reported success on the live template"; fi
! destroyed 9000 || fail "cleanup_rebake destroyed the live template"

# recover_pending_bake: a half-converted pending VM is destroyed, not published.
reset_host
add_vm 9001 ubuntu-cloud-template local-zfs:vm-9001-disk-0 1
printf '9001\n' > "$PENDING_BAKE_FILE"
printf 'version=2.330.0\n' > "$PENDING_VERSION_FILE"
recover_pending_bake || fail "recover_pending_bake failed on a half-converted VM"
[[ "$TEMPLATE_ID" == 9000 ]] || fail "recover_pending_bake published a half-converted template"
grep -qx 'TEMPLATE_ID=9000' "$CONFIG_FILE" || fail "recover_pending_bake rewrote TEMPLATE_ID"
[[ ! -e "$BAKED_VERSION_FILE" ]] || fail "recover_pending_bake recorded a half-converted template"
destroyed 9001 || fail "recover_pending_bake left the half-converted VM"
[[ ! -e "$PENDING_BAKE_FILE" ]] || fail "recover_pending_bake kept the record of a destroyed VM"

# recover_pending_bake: a converted pending template is published.
reset_host
add_vm 9001 ubuntu-cloud-template local-zfs:base-9001-disk-0 1
printf '9001\n' > "$PENDING_BAKE_FILE"
printf 'version=2.330.0\n' > "$PENDING_VERSION_FILE"
recover_pending_bake || fail "recover_pending_bake failed on a converted template"
[[ "$TEMPLATE_ID" == 9001 ]] || fail "recover_pending_bake did not publish a converted template"
grep -q '^version=2.330.0$' "$BAKED_VERSION_FILE" || fail "recover_pending_bake did not record the version"
! destroyed 9001 || fail "recover_pending_bake destroyed a converted template"

# require_live_template refuses a live template that was never converted.
reset_host
require_live_template || fail "require_live_template refused a converted template"
printf 'local-zfs:vm-9000-disk-0' > "$vms/9000/disk"
if require_live_template; then fail "require_live_template accepted an unconverted template"; fi

printf 'rebake-publish: ok\n'
