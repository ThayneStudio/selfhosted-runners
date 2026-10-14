#!/usr/bin/env bash
# Runners are destroyed and recloned while the rebake scans a retired
# template's ZFS linked clones. When a lookup failed, the scan listed the
# storage again and skipped the volume only if that listing no longer showed
# it. A reclone reuses the VMID and creates vm-<id>-cloudinit first, often
# within seconds, so a volume gone at its lookup and back by the second
# listing failed the scan, and the template was kept another day. The failing
# lookup's own "dataset does not exist" now decides; any other failure, or
# output that is not one origin, still fails closed.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'inventory2-zfs-recreate: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'inventory2-zfs-recreate: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
cd "$state"
VM_STORAGE=local-zfs

# Template 9000 is retired; runners are clones of the live template 9100.
qm() {
    [[ "$1" == config ]] || return 1
    printf 'name: ubuntu-cloud-template\nscsi0: local-zfs:base-%s-disk-0,size=30G\ntemplate: 1\n' "$2"
}

# The pool's zvols as "<name> <origin>". State lives in files: zfs and pvesm
# run inside $(...). Mocks read only mock_* variables.
mock_zvols=$state/zvols
mock_gone_once=$state/gone-once
mock_error=$state/error
mock_noise=$state/noise
printf '%s\n' 'base-9000-disk-0 -' 'base-9100-disk-0 -' \
    'vm-9003-disk-0 rpool/data/base-9000-disk-0@__base__' \
    'vm-9004-disk-0 rpool/data/base-9000-disk-0@manual' \
    'vm-9101-disk-0 rpool/data/base-9100-disk-0@__base__' 'vm-9101-cloudinit -' \
    'vm-9102-disk-0 rpool/data/base-9100-disk-0@__base__' 'vm-9102-cloudinit -' > "$mock_zvols"

pvesm() {
    local name origin
    case "$1" in
        list)
            printf 'Volid Format Type Size VMID\n'
            while read -r name origin; do
                # Like ZFSPoolPlugin::list_images: a clone of a base volume's
                # __base__ snapshot is listed under that base.
                if [[ "$origin" =~ ^rpool/data/(.+)@__base__$ ]]; then
                    name="${BASH_REMATCH[1]}/$name"
                fi
                printf 'local-zfs:%s raw images 1 0\n' "$name"
            done < "$mock_zvols"
            ;;
        # Like ZFSPoolPlugin, the path is built without checking the zvol.
        path) printf '/dev/zvol/rpool/data/%s\n' "${2##*[:/]}" ;;
        *) return 1 ;;
    esac
}
zfs() {
    local dataset="${*: -1}" origin
    # The dataset is destroyed just before this call and created again
    # right after it, under the same name and with the same origin.
    if [[ "$(cat "$mock_gone_once" 2>/dev/null)" == "$dataset" ]]; then
        rm -f "$mock_gone_once"
        printf "cannot open '%s': dataset does not exist\n" "$dataset" >&2
        return 1
    fi
    if ! origin=$(awk -v n="${dataset#rpool/data/}" '$1 == n { print $2; found = 1 } END { exit !found }' "$mock_zvols"); then
        printf "cannot open '%s': dataset does not exist\n" "$dataset" >&2
        return 1
    fi
    if [[ "$(cat "$mock_error" 2>/dev/null)" == "$dataset" ]]; then
        printf "cannot open '%s': pool I/O is currently suspended\n" "$dataset" >&2
        return 1
    fi
    case "$1" in
        list) printf '%s\n' "$dataset" ;;
        get)
            if [[ "$(cat "$mock_noise" 2>/dev/null)" == "$dataset" ]]; then
                printf 'warning: %s is busy\n' "$dataset" >&2
            fi
            printf '%s\n' "$origin"
            ;;
        *) return 1 ;;
    esac
}

reset() { rm -f "$mock_gone_once" "$mock_error" "$mock_noise"; }

# The nested clone comes from the listing, the clone of another snapshot of
# the base from its origin.
expected=$'local-zfs:base-9000-disk-0/vm-9003-disk-0\nlocal-zfs:vm-9004-disk-0'
reset
out=$(list_template_linked_clone_volids 9000) || fail "the scan failed with nothing changing"
[[ "$out" == "$expected" ]] || fail "the scan listed: $out"

# VM 9102 is destroyed and recloned while the scan runs: its cloud-init zvol
# is gone when looked up and listed again right after.
reset
printf 'rpool/data/vm-9102-cloudinit\n' > "$mock_gone_once"
out=$(list_template_linked_clone_volids 9000 2>"$state/stderr") ||
    fail "a runner recloned mid-scan failed the scan: $(cat "$state/stderr")"
[[ "$out" == "$expected" ]] || fail "after a runner was recloned mid-scan the scan listed: $out"
[[ ! -e "$mock_gone_once" ]] || fail "the scan never looked the recloned volume up"

# Any other error leaves the volume unknown.
reset
printf 'rpool/data/vm-9102-cloudinit\n' > "$mock_error"
if list_template_linked_clone_volids 9000 >/dev/null 2>&1; then
    fail "a lookup that failed for another reason passed"
fi

# The lookup's stderr is read with its output. Anything besides the one
# origin fails closed rather than hide a clone.
reset
printf 'rpool/data/vm-9004-disk-0\n' > "$mock_noise"
if out=$(list_template_linked_clone_volids 9000 2>/dev/null); then
    fail "a lookup that printed more than an origin passed and listed: $out"
fi

printf 'inventory2-zfs-recreate: ok\n'
