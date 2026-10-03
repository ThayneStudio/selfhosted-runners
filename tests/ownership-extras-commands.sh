#!/usr/bin/env bash
# The commands keep the extra-runner record that the watcher fills from:
# `runner create` records an extra runner (not one of the org's slots);
# `runner destroy`, a full `runner stop` and `runner remove-org` end it, also
# when a hold or a template rebuild left it with no VM. They also manage
# only VMs bound to their own VMID: a full clone of a runner is not theirs.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'ownership-extras-commands: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'ownership-extras-commands: %s\n' "$1" >&2; exit 1; }

# Run the real commands from a copy of lib/ whose host paths point at a
# scratch dir, with the root check skipped and qm and clone_runner mocked.
# VMs live in $state/vm/<vmid>/. The extras paths are set in recycle.sh,
# which the commands source after common.sh.
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
mkdir -p "$state/lib" "$state/orgs" "$state/snippets" "$state/vm"
cp "$root"/lib/*.sh "$state/lib/"
printf 'NETWORK_BRIDGE=vmbr0\nVM_STORAGE=local-zfs\nTEMPLATE_ID=9000\n' > "$state/github-runners.conf"
cat >> "$state/lib/common.sh" <<EOF
CONFIG_FILE="$state/github-runners.conf"
ORG_CONFIG_DIR="$state/orgs"
SNIPPETS_DIR="$state/snippets"
INSTALL_DIR="$root"
POOL_DRAIN_FILE="$state/drain"
LEGACY_POOL_DRAIN_FILE="$state/legacy-drain"
POOL_ACTIVITY_LOCK_FILE="$state/pool.lock"
MOCK_STATE="$state"
EOF
cat >> "$state/lib/common.sh" <<'EOF'
require_root() { :; }
flock() { :; }
systemctl() { return 3; }
deregister_runner() { :; }
cleanup_template_orphan_volumes() { return 0; }
qm() {
    local id="${2:-}" d
    case "$1" in
        list)
            printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
            for d in "$MOCK_STATE"/vm/*; do
                [[ -d "$d" ]] || continue
                printf '%10s %-20s %-10s 8192 30.00 0\n' "${d##*/}" "$(cat "$d/name")" "$(cat "$d/status")"
            done
            ;;
        config)
            if [[ "$id" == 9000 ]]; then
                printf 'name: ubuntu-cloud-template\ntemplate: 1\n'
                return 0
            fi
            [[ -d "$MOCK_STATE/vm/$id" ]] || return 2
            printf 'name: %s\n' "$(cat "$MOCK_STATE/vm/$id/name")"
            printf 'description: %s\n' "$(cat "$MOCK_STATE/vm/$id/desc")"
            printf 'cicustom: %s\n' "$(cat "$MOCK_STATE/vm/$id/cicustom")"
            ;;
        status)
            [[ -d "$MOCK_STATE/vm/$id" ]] || return 2
            printf 'status: %s\n' "$(cat "$MOCK_STATE/vm/$id/status")"
            ;;
        set) ;;
        stop) printf 'stopped\n' > "$MOCK_STATE/vm/$id/status" ;;
        destroy)
            printf 'destroy %s\n' "$id" >> "$MOCK_STATE/actions"
            rm -rf "${MOCK_STATE:?}/vm/$id"
            ;;
        *) return 1 ;;
    esac
}
# A VM as the real clone_runner makes it, with the kind it would record.
clone_runner() {
    local name="$1" org="$2" vmid=9101 kind=extra n dir
    while [[ -d "$MOCK_STATE/vm/$vmid" ]]; do vmid=$((vmid + 1)); done
    if n=$(slot_number "$name" "${RUNNER_PREFIX:-runner}") && (( n <= RUNNER_COUNT )); then
        kind=slot
    fi
    dir="$MOCK_STATE/vm/$vmid"
    mkdir -p "$dir"
    printf '%s\n' "$name" > "$dir/name"
    printf 'running\n' > "$dir/status"
    printf 'user=local:snippets/runner-%s-user-%s.yaml,meta=local:snippets/runner-%s-meta.yaml\n' "$vmid" "$org" "$vmid" > "$dir/cicustom"
    printf 'selfhosted-runners org=%s kind=%s vmid=%s\n' "$org" "$kind" "$vmid" > "$dir/desc"
    printf 'clone %s %s\n' "$name" "$org" >> "$MOCK_STATE/actions"
    printf '%s\n' "$vmid"
}
EOF
cat >> "$state/lib/recycle.sh" <<EOF
SLOT_STATE_DIR="$state/slots"
SLOT_LOCK_PREFIX="$state/slot"
EXTRA_RUNNERS_FILE="$state/extras"
EXTRA_RUNNERS_LOCK_FILE="$state/extras.lock"
EOF
for org in acme beta; do
    printf 'GITHUB_ORG="%s"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="runner"\nRUNNER_COUNT="2"\n' "$org" > "$state/orgs/$org.conf"
done

# cmd <script> [args]: run a command; its output is in $state/out, its exit
# status in $rc.
cmd() {
    local script="$1"
    shift
    set +e
    "$BASH" "$state/lib/$script.sh" "$@" > "$state/out" 2>&1 < "${input:-/dev/null}"
    rc=$?
    set -e
}
extras() { if [[ -e "$state/extras" ]]; then sort "$state/extras" | tr '\n' ' '; fi; }
vmid_of() { grep -lx "$1" "$state"/vm/*/name 2>/dev/null | sed 's#.*/vm/\([0-9]*\)/name#\1#'; }

# runner create records an extra runner, not one of the org's slots.
cmd create --org acme build-box
[[ $rc -eq 0 ]] || fail "create failed: $(cat "$state/out")"
cmd create --org acme runner-2
[[ $rc -eq 0 ]] || fail "create of a slot failed: $(cat "$state/out")"
cmd create --org beta runner-3
[[ $rc -eq 0 ]] || fail "create of a name past RUNNER_COUNT failed: $(cat "$state/out")"
[[ "$(extras)" == "build-box acme runner-3 beta " ]] || fail "unexpected extra runners after create: $(extras)"

# runner destroy <name> of an extra runner ends it; of a slot, it does not
# touch the record.
cmd destroy runner-2
[[ $rc -eq 0 ]] || fail "destroy of a slot failed: $(cat "$state/out")"
[[ "$(extras)" == "build-box acme runner-3 beta " ]] || fail "destroying a slot changed the record: $(extras)"
cmd destroy build-box
[[ $rc -eq 0 ]] || fail "destroy of an extra runner failed: $(cat "$state/out")"
[[ -z "$(vmid_of build-box)" ]] || fail "the extra runner's VM was not destroyed"
[[ "$(extras)" == "runner-3 beta " ]] || fail "the destroyed extra runner stayed recorded: $(extras)"
grep -q 'the watcher will not recreate it' "$state/out" || fail "destroy did not say the extra runner is gone: $(cat "$state/out")"

# runner destroy --vmid ends an extra runner too.
cmd destroy --vmid "$(vmid_of runner-3)"
[[ $rc -eq 0 ]] || fail "destroy --vmid failed: $(cat "$state/out")"
[[ -z "$(extras)" ]] || fail "an extra runner destroyed by VMID stayed recorded: $(extras)"

# An extra runner that a hold left with no VM: runner destroy ends its record.
cmd create --org acme lost-box
rm -rf "${state:?}/vm/$(vmid_of lost-box)"
cmd destroy lost-box
[[ $rc -eq 0 ]] || fail "destroy of an extra runner with no VM failed: $(cat "$state/out")"
[[ -z "$(extras)" ]] || fail "an extra runner with no VM stayed recorded: $(extras)"
grep -q 'had no VM; the watcher will not create it again' "$state/out" || fail "unexpected output: $(cat "$state/out")"
cmd destroy no-such-runner
[[ $rc -ne 0 ]] || fail "destroy of an unknown name succeeded"
grep -q "'no-such-runner' not found" "$state/out" || fail "an unknown name was not reported: $(cat "$state/out")"

# runner remove-org ends that org's extra runners only.
cmd create --org acme a-box
cmd create --org beta b-box
input=$state/yes
printf 'yes\n' > "$input"
cmd remove-org beta
input=""
[[ $rc -eq 0 ]] || fail "remove-org failed: $(cat "$state/out")"
[[ "$(extras)" == "a-box acme " ]] || fail "remove-org left the wrong extra runners: $(extras)"
printf 'GITHUB_ORG="beta"\nGITHUB_PAT="ghp_test"\nRUNNER_PREFIX="runner"\nRUNNER_COUNT="2"\n' > "$state/orgs/beta.conf"

# Extra runners with no VM right now: a ranged stop leaves them, a full stop
# ends them all. (Neither stop below has a managed VM to destroy.)
rm -rf "${state:?}"/vm/*
printf 'lost-1 acme\nlost-2 beta\n' > "$state/extras"
cmd stop --watch-only --yes
[[ "$(extras)" == "lost-1 acme lost-2 beta " ]] || fail "stop --watch-only ended extra runners: $(extras)"
cmd stop --vmid-range 1:2 --yes
[[ $rc -eq 0 ]] || fail "a ranged stop failed: $(cat "$state/out")"
[[ "$(extras)" == "lost-1 acme lost-2 beta " ]] || fail "a ranged stop ended extra runners outside its range: $(extras)"
# A full clone of a runner (VM 9300 copied VM 9101's snippets and marker) is
# not a managed runner VM: the stop leaves it, and runner destroy refuses it.
mkdir -p "$state/vm/9300"
printf 'runner-7\n' > "$state/vm/9300/name"
printf 'stopped\n' > "$state/vm/9300/status"
printf 'user=local:snippets/runner-9101-user-acme.yaml,meta=local:snippets/runner-9101-meta.yaml\n' > "$state/vm/9300/cicustom"
printf 'selfhosted-runners org=acme kind=extra vmid=9101\n' > "$state/vm/9300/desc"
: > "$state/actions"
cmd stop --yes
[[ $rc -eq 0 ]] || fail "a full stop failed: $(cat "$state/out")"
[[ ! -e "$state/extras" ]] || fail "a full stop left extra runners: $(extras)"
grep -q 'destroy 0 managed runner VMs' "$state/out" || fail "a full stop selected a full clone of a runner: $(cat "$state/out")"
[[ -d "$state/vm/9300" && ! -s "$state/actions" ]] || fail "a full stop destroyed a full clone of a runner"
cmd destroy --vmid 9300
[[ $rc -ne 0 ]] || fail "runner destroy accepted a full clone of a runner: $(cat "$state/out")"
grep -q 'is not managed by selfhosted-runners' "$state/out" || fail "unexpected output: $(cat "$state/out")"
[[ -d "$state/vm/9300" ]] || fail "runner destroy destroyed a full clone of a runner"
# runner list shows the runner VM 9101 and not its copy.
mkdir -p "$state/vm/9101"
printf 'runner-1\n' > "$state/vm/9101/name"
printf 'running\n' > "$state/vm/9101/status"
cp "$state/vm/9300/cicustom" "$state/vm/9300/desc" "$state/vm/9101/"
cmd list
grep -q 'runner-1 ' "$state/out" || fail "runner list did not show a runner VM: $(cat "$state/out")"
grep -q 'runner-7' "$state/out" && fail "runner list showed a full clone of a runner: $(cat "$state/out")"

printf 'ownership-extras-commands: ok\n'
