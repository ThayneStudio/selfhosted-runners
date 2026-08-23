#!/usr/bin/env bats
# Unit tests for lib/guard.sh — the host-side termination guard.
#
# The guard destroys VMs, so most of what matters here is what it must *not*
# touch. Everything runs against stub `qm`/`flock`/`logger` executables inside a
# sandbox copy of lib/, so no Proxmox host is involved and nothing real is ever
# at risk.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"/{lib,bin,vms,etc,snippets,run/lock} \
             "$SANDBOX/pve/nodes/pve/qemu-server"

    cp "$REPO_ROOT"/lib/*.sh "$SANDBOX/lib/"
    chmod +x "$SANDBOX"/lib/*.sh

    # Retarget every host path at the sandbox and neuter the root check. The
    # scripts under test are otherwise byte-for-byte the shipped ones.
    sed -i.bak \
        -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"$SANDBOX/etc/github-runners.conf\"#" \
        -e "s#^ORG_CONFIG_DIR=.*#ORG_CONFIG_DIR=\"$SANDBOX/etc/github-runners.d\"#" \
        -e "s#^SNIPPETS_DIR=.*#SNIPPETS_DIR=\"$SANDBOX/snippets\"#" \
        -e "s#^POOL_DRAIN_FILE=.*#POOL_DRAIN_FILE=\"$SANDBOX/run/lock/drain\"#" \
        -e "s#^GUARD_STATE_DIR=.*#GUARD_STATE_DIR=\"$SANDBOX/run/guard\"#" \
        -e "s#^POOL_ACTIVITY_LOCK_FILE=.*#POOL_ACTIVITY_LOCK_FILE=\"$SANDBOX/run/lock/pool.lock\"#" \
        -e "s#/etc/pve/nodes#$SANDBOX/pve/nodes#" \
        -e "s#\$EUID -ne 0#1 -ne 1#" \
        "$SANDBOX/lib/common.sh"
    # macOS ships bash 3.2 as /bin/bash; run everything under the bash bats uses.
    sed -i.bak "1s|^#!/bin/bash|#!$BASH|" "$SANDBOX"/lib/*.sh
    rm -f "$SANDBOX"/lib/*.bak

    cat > "$SANDBOX/etc/github-runners.conf" <<EOF
NETWORK_BRIDGE="vmbr0"
VM_STORAGE="local-zfs"
TEMPLATE_ID="9000"
MIN_VMID="9001"
MAX_VM_LIFETIME_HOURS="8"
STOPPED_REAP_MINUTES="10"
EOF

    make_stubs
    PATH="$SANDBOX/bin:$PATH"
    export PATH
}

make_stubs() {
    {
        echo "#!/bin/bash"
        echo "SANDBOX=\"$SANDBOX\""
        cat <<'STUB'
cmd="$1"; shift
case "$cmd" in
    list)
        echo "      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
        for f in "$SANDBOX"/vms/*; do
            [[ -e "$f" ]] || continue
            (
                . "$f"
                printf '%10s %-20s %-10s %9s %12s %6s\n' \
                    "$(basename "$f")" "$NAME" "$STATUS" 8192 30 0
            )
        done
        ;;
    config)
        vmid="$1"; f="$SANDBOX/vms/$vmid"
        [[ -e "$f" ]] || { echo "no such vm" >&2; exit 2; }
        (
            . "$f"
            echo "boot: order=scsi0"
            echo "cores: 2"
            [[ -n "$ORG" ]] && echo "cicustom: user=local:snippets/runner-user-data-${ORG}.yaml,meta=local:snippets/runner-${vmid}-meta.yaml"
            echo "name: $NAME"
            [[ "${TEMPLATE:-0}" == "1" ]] && echo "template: 1"
        )
        ;;
    status)
        vmid="$1"; f="$SANDBOX/vms/$vmid"
        [[ -e "$f" ]] || { echo "no such vm" >&2; exit 2; }
        (
            . "$f"
            echo "status: $STATUS"
            if [[ "${2:-}" == "--verbose" ]]; then
                echo "qmpstatus: $STATUS"
                [[ -n "${UPTIME:-}" ]] && echo "uptime: $UPTIME"
                echo "vmid: $vmid"
            fi
        )
        ;;
    stop|shutdown)
        vmid="$1"; f="$SANDBOX/vms/$vmid"
        [[ -e "$f" ]] || exit 2
        sed -i.bak 's/^STATUS=.*/STATUS="stopped"/' "$f" && rm -f "$f.bak"
        ;;
    destroy)
        vmid="$1"; f="$SANDBOX/vms/$vmid"
        [[ -e "$f" ]] || { echo "no such vm" >&2; exit 2; }
        [[ "${STUB_DESTROY_FAIL:-}" != "$vmid" ]] || { echo "VM is locked" >&2; exit 1; }
        echo "$vmid" >> "$SANDBOX/destroyed.log"
        rm -f "$f" "$SANDBOX/pve/nodes/pve/qemu-server/$vmid.conf"
        ;;
    set)
        ;;
    *)
        echo "qm stub: unhandled command $cmd" >&2
        exit 1
        ;;
esac
exit 0
STUB
    } > "$SANDBOX/bin/qm"

    {
        echo "#!/bin/bash"
        echo "SANDBOX=\"$SANDBOX\""
        cat <<'STUB'
printf '%s\n' "$*" >> "$SANDBOX/logger.log"
STUB
    } > "$SANDBOX/bin/logger"

    cat > "$SANDBOX/bin/flock" <<'STUB'
#!/bin/bash
exit "${STUB_FLOCK_RC:-0}"
STUB

    cat > "$SANDBOX/bin/systemctl" <<'STUB'
#!/bin/bash
exit 0
STUB

    # macOS stat has no -c; give the guard a GNU-compatible mtime shim.
    if ! /usr/bin/stat -c %Y / >/dev/null 2>&1; then
        cat > "$SANDBOX/bin/stat" <<'STUB'
#!/bin/bash
if [[ "$1" == "-c" && "$2" == "%Y" ]]; then
    exec /usr/bin/stat -f %m "$3"
fi
exec /usr/bin/stat "$@"
STUB
    fi

    chmod +x "$SANDBOX"/bin/*
}

# make_vm <vmid> <name> <status> <org> [uptime] [template]
make_vm() {
    cat > "$SANDBOX/vms/$1" <<EOF
NAME="$2"
STATUS="$3"
ORG="$4"
UPTIME="${5:-0}"
TEMPLATE="${6:-0}"
EOF
    : > "$SANDBOX/pve/nodes/pve/qemu-server/$1.conf"
}

destroyed() {
    [[ -f "$SANDBOX/destroyed.log" ]] && grep -qx "$1" "$SANDBOX/destroyed.log"
}

run_guard() {
    run "$SANDBOX/lib/guard.sh" "$@"
    echo "guard status: $status"
    echo "guard output: $output"
}

# Backdate the stopped marker for <vmid> by <seconds>, preserving the recorded
# config mtime so the marker stays valid.
age_marker() {
    local marker="$SANDBOX/run/guard/$1.stopped" first mtime
    read -r first mtime < "$marker"
    printf '%s %s\n' "$((first - $2))" "$mtime" > "$marker"
}

@test "leaves unrelated VMs alone, running or stopped" {
    # No runner cloud-init snippet, so get_vm_org() reports "unknown". Both are
    # in the runner VMID range and both would otherwise be reapable.
    make_vm 9001 unrelated-nas running "" 999999
    make_vm 9003 unrelated-off stopped ""
    make_vm 9002 runner-1 running github 36000
    run_guard --now
    [ "$status" -eq 0 ]
    ! destroyed 9001
    ! destroyed 9003
    destroyed 9002
}

@test "never destroys the template VMID" {
    # Even with a runner snippet and an absurd uptime, TEMPLATE_ID is off limits.
    make_vm 9000 ubuntu-cloud-template running github 999999
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9000
}

@test "never destroys a VM below MIN_VMID" {
    make_vm 8500 runner-legacy stopped github
    run_guard --now
    [ "$status" -eq 0 ]
    ! destroyed 8500
}

@test "never destroys a template, whatever its VMID" {
    make_vm 9500 runner-gen2 stopped github 0 1
    run_guard --now
    [ "$status" -eq 0 ]
    ! destroyed 9500
}

@test "destroys a running VM past the lifetime ceiling" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    run_guard
    [ "$status" -eq 0 ]
    destroyed 9001
}

@test "leaves a running VM inside the lifetime ceiling" {
    make_vm 9001 runner-1 running github $((7 * 3600))
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
}

@test "never destroys a running VM whose uptime is unreadable" {
    make_vm 9001 runner-1 running github ""
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
}

@test "honours MAX_VM_LIFETIME_HOURS from the config" {
    sed -i.bak 's/^MAX_VM_LIFETIME_HOURS=.*/MAX_VM_LIFETIME_HOURS="2"/' \
        "$SANDBOX/etc/github-runners.conf"
    make_vm 9001 runner-1 running github $((3 * 3600))
    run_guard
    [ "$status" -eq 0 ]
    destroyed 9001
}

@test "falls back to the default ceiling when the config value is garbage" {
    sed -i.bak 's/^MAX_VM_LIFETIME_HOURS=.*/MAX_VM_LIFETIME_HOURS="forever"/' \
        "$SANDBOX/etc/github-runners.conf"
    make_vm 9001 runner-1 running github $((9 * 3600))
    make_vm 9002 runner-2 running github $((7 * 3600))
    run_guard
    [ "$status" -eq 0 ]
    destroyed 9001
    ! destroyed 9002
}

@test "gives a freshly stopped VM the full grace period" {
    make_vm 9001 runner-1 stopped github
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    [ -f "$SANDBOX/run/guard/9001.stopped" ]
}

@test "destroys a VM stopped for longer than STOPPED_REAP_MINUTES" {
    make_vm 9001 runner-1 stopped github
    run_guard
    ! destroyed 9001
    age_marker 9001 $((11 * 60))
    run_guard
    [ "$status" -eq 0 ]
    destroyed 9001
}

@test "restarts the stopped clock when the VM config is rewritten" {
    # A recycled VMID must not inherit the previous VM's observed age.
    make_vm 9001 runner-1 stopped github
    run_guard
    age_marker 9001 $((11 * 60))
    touch -t 203001010101 "$SANDBOX/pve/nodes/pve/qemu-server/9001.conf"
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
}

@test "--now reaps a stopped VM immediately" {
    make_vm 9001 runner-1 stopped github
    run_guard --stopped-only --now
    [ "$status" -eq 0 ]
    destroyed 9001
}

@test "--stopped-only skips the lifetime check" {
    make_vm 9001 runner-1 running github $((99 * 3600))
    run_guard --stopped-only --now
    [ "$status" -eq 0 ]
    ! destroyed 9001
}

@test "does nothing while a clone holds the pool activity lock" {
    make_vm 9001 runner-1 stopped github
    run_guard
    age_marker 9001 $((11 * 60))
    STUB_FLOCK_RC=1 run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    grep -q "skipped: clone activity in progress" "$SANDBOX/logger.log"
}

@test "logs every run and every forced destroy to the github-runner tag" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    run_guard
    grep -q "\[guard\] forcing destroy of runner-1 (VMID 9001)" "$SANDBOX/logger.log"
    grep -q "\[guard\] destroyed runner-1 (VMID 9001)" "$SANDBOX/logger.log"
    grep -q "\[guard\] checked 1 managed VM(s): destroyed 1, failed 0" "$SANDBOX/logger.log"
}

@test "reports a failed destroy and exits non-zero" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    STUB_DESTROY_FAIL=9001 run_guard
    [ "$status" -eq 1 ]
    ! destroyed 9001
    grep -q "FAILED to destroy runner-1 (VMID 9001)" "$SANDBOX/logger.log"
    grep -q "\[guard\] checked 1 managed VM(s): destroyed 0, failed 1" "$SANDBOX/logger.log"
}

@test "sweeps stale markers for VMIDs that are no longer stopped runners" {
    make_vm 9001 runner-1 stopped github
    run_guard
    [ -f "$SANDBOX/run/guard/9001.stopped" ]
    sed -i.bak 's/^STATUS=.*/STATUS="running"/' "$SANDBOX/vms/9001"
    run_guard
    [ ! -f "$SANDBOX/run/guard/9001.stopped" ]
}

@test "runner start reaps stopped VMs before clearing the drain flag" {
    make_vm 9001 runner-1 stopped github
    : > "$SANDBOX/run/lock/drain"
    run "$SANDBOX/lib/start.sh"
    echo "start status: $status"
    echo "start output: $output"
    [ "$status" -eq 0 ]
    destroyed 9001
    [ ! -e "$SANDBOX/run/lock/drain" ]
}

@test "rejects unknown options instead of guessing" {
    run_guard --destroy-everything
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}
