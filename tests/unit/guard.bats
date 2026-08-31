#!/usr/bin/env bats
# Unit tests for lib/guard.sh — the host-side termination guard.
#
# The guard destroys VMs, so most of what matters here is what it must *not*
# touch. Everything runs against stub `qm`/`logger` executables inside a sandbox
# copy of lib/, so no Proxmox host is involved and nothing real is ever at risk.
#
# `flock` is deliberately NOT stubbed: the per-slot lock is the mechanism that
# keeps the guard off a VM another process is cloning, and a stub would pass
# just as happily with the wrong fd or the wrong lock file. Tests use the real
# flock(1) where it exists and an equivalent fcntl.flock shim otherwise, with a
# real background process holding the lock.

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
        -e "s#^POOL_DRAIN_COORD_LOCK_FILE=.*#POOL_DRAIN_COORD_LOCK_FILE=\"$SANDBOX/run/lock/drain-coord.lock\"#" \
        -e "s#^RUNNER_SLOT_LOCK_PREFIX=.*#RUNNER_SLOT_LOCK_PREFIX=\"$SANDBOX/run/lock/runner\"#" \
        -e "s#/etc/pve/nodes#$SANDBOX/pve/nodes#" \
        -e "s#\$EUID -ne 0#1 -ne 1#" \
        "$SANDBOX/lib/common.sh"
    # macOS ships bash 3.2 as /bin/bash; run everything under the bash bats uses.
    sed -i.bak "1s|^#!/bin/bash|#!$BASH|" "$SANDBOX"/lib/*.sh
    rm -f "$SANDBOX"/lib/*.bak

    write_config
    make_stubs
    PATH="$SANDBOX/bin:$PATH"
    export PATH
}

teardown() {
    [[ -z "${HOLDER_PID:-}" ]] || kill "$HOLDER_PID" 2>/dev/null || true
}

write_config() {
    cat > "$SANDBOX/etc/github-runners.conf" <<EOF
NETWORK_BRIDGE="vmbr0"
VM_STORAGE="local-zfs"
TEMPLATE_ID="9000"
MIN_VMID="9001"
MAX_VM_LIFETIME_HOURS="8"
STOPPED_REAP_MINUTES="10"
GUARD_EXCLUDE_VMIDS=""
EOF
}

config_set() {  # key value
    sed -i.bak "s/^${1}=.*/${1}=\"${2}\"/" "$SANDBOX/etc/github-runners.conf"
    rm -f "$SANDBOX/etc/github-runners.conf.bak"
}

config_unset() {  # key
    sed -i.bak "/^${1}=/d" "$SANDBOX/etc/github-runners.conf"
    rm -f "$SANDBOX/etc/github-runners.conf.bak"
}

make_stubs() {
    {
        echo "#!/bin/bash"
        echo "SANDBOX=\"$SANDBOX\""
        cat <<'STUB'
cmd="$1"; shift
case "$cmd" in
    list)
        [[ -z "${STUB_LIST_FAIL:-}" ]] || { echo "ipcc_send_rec failed" >&2; exit 2; }
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
        [[ "${STUB_CONFIG_FAIL:-}" != "$vmid" ]] || { echo "unable to read config" >&2; exit 2; }
        [[ -e "$f" ]] || { echo "no such vm" >&2; exit 2; }
        (
            . "$f"
            echo "boot: order=scsi0"
            echo "cores: 2"
            [[ -n "$ORG" ]] && echo "cicustom: user=local:snippets/runner-user-data-${ORG}.yaml,meta=local:snippets/runner-${vmid}-meta.yaml"
            [[ -n "${LOCKED:-}" ]] && echo "lock: $LOCKED"
            echo "name: $NAME"
            [[ "${PROTECTED:-0}" == "1" ]] && echo "protection: 1"
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

    # A real advisory lock, not a stub. util-linux flock where available;
    # otherwise the same fcntl.flock(2) call on the inherited descriptor, which
    # is exactly what makes the fd form work across processes.
    if ! command -v flock >/dev/null 2>&1; then
        cat > "$SANDBOX/bin/flock" <<'STUB'
#!/usr/bin/env python3
import fcntl, sys, time
args, timeout, nonblock = sys.argv[1:], None, False
i = 0
while i < len(args) and args[i].startswith('-'):
    if args[i] in ('-n', '--nonblock'):
        nonblock = True; i += 1
    elif args[i] in ('-w', '--timeout'):
        timeout = float(args[i + 1]); i += 2
    else:
        i += 1
fd = int(args[i])
deadline = time.time() + (timeout or 0)
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except OSError:
        if nonblock or timeout is None or time.time() >= deadline:
            sys.exit(1)
        time.sleep(0.05)
STUB
    fi

    chmod +x "$SANDBOX"/bin/*
}

# make_vm <vmid> <name> <status> <org> [uptime] [template] [protected] [lock]
make_vm() {
    cat > "$SANDBOX/vms/$1" <<EOF
NAME="$2"
STATUS="$3"
ORG="$4"
UPTIME="${5-0}"
TEMPLATE="${6:-0}"
PROTECTED="${7:-0}"
LOCKED="${8:-}"
EOF
    : > "$SANDBOX/pve/nodes/pve/qemu-server/$1.conf"
}

vm_conf() {
    echo "$SANDBOX/pve/nodes/pve/qemu-server/$1.conf"
}

# Backdate a file's mtime by N seconds. GNU touch where available, else python3.
age_file() {  # path seconds
    local target
    target=$(( $(date +%s) - $2 ))
    touch -d "@$target" "$1" 2>/dev/null && return 0
    python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$target"
}

# A stopped VM is only reapable once its Proxmox config has sat untouched
# longer than the threshold, so tests that expect a reap must age it.
age_vm_config() {  # vmid seconds
    age_file "$(vm_conf "$1")" "$2"
}

# Backdate the stopped marker for <vmid> by <seconds>, preserving the recorded
# config mtime so the marker stays valid.
age_marker() {
    local marker="$SANDBOX/run/guard/$1.stopped" first mtime
    read -r first mtime < "$marker"
    printf '%s %s\n' "$((first - $2))" "$mtime" > "$marker"
}

enable_drain() {
    : > "$SANDBOX/run/lock/drain"
}

# Hold a slot lock from a separate process, the way an in-flight clone does.
hold_slot_lock() {  # runner-name
    local lock_file="$SANDBOX/run/lock/runner-${1}.lock"
    local ready="$SANDBOX/holder-ready"
    rm -f "$ready"
    python3 -c '
import fcntl, sys, time
f = open(sys.argv[1], "w")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)
' "$lock_file" "$ready" &
    HOLDER_PID=$!
    local waited=0
    while [[ ! -e "$ready" && "$waited" -lt 100 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    [[ -e "$ready" ]]
}

destroyed() {
    [[ -f "$SANDBOX/destroyed.log" ]] && grep -qx "$1" "$SANDBOX/destroyed.log"
}

run_guard() {
    run "$SANDBOX/lib/guard.sh" "$@"
    echo "guard status: $status"
    echo "guard output: $output"
}

# --- scoping: what the guard must never touch ---------------------------------

@test "leaves unrelated VMs alone, running or stopped" {
    # No runner cloud-init snippet, so get_vm_org() reports "unknown". Both are
    # in the runner VMID range and both would otherwise be reapable.
    make_vm 9001 unrelated-nas running "" 999999
    make_vm 9003 unrelated-off stopped ""
    make_vm 9002 runner-1 running github 36000
    age_vm_config 9003 3600
    enable_drain
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
    age_vm_config 8500 3600
    enable_drain
    run_guard --now
    [ "$status" -eq 0 ]
    ! destroyed 8500
}

@test "an absent MIN_VMID is a hard error at config load" {
    # Generations cannot express overlap against auto-allocation, so
    # load_infra_config treats a missing MIN_VMID like 0 and refuses to start.
    config_unset MIN_VMID
    make_vm 102 runner-low stopped github
    age_vm_config 102 3600
    enable_drain
    run_guard --now
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIN_VMID=0"* ]]
    ! destroyed 102
}

@test "an explicit MIN_VMID=0 is a hard error at config load" {
    config_set MIN_VMID 0
    make_vm 102 runner-low stopped github
    age_vm_config 102 3600
    enable_drain
    run_guard --now
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIN_VMID=0"* ]]
    [[ "$output" == *"9000"* ]]
    ! destroyed 102
}

@test "never destroys a template, whatever its VMID" {
    make_vm 9500 runner-gen2 stopped github 0 1
    age_vm_config 9500 3600
    enable_drain
    run_guard --now
    [ "$status" -eq 0 ]
    ! destroyed 9500
}

@test "never destroys a protected VM, and does not fail the run over it" {
    make_vm 9001 runner-1 stopped github 0 0 1
    age_vm_config 9001 3600
    enable_drain
    run_guard --now
    [ "$status" -eq 0 ]
    ! destroyed 9001
    [[ "$output" == *"protection is set"* ]]
}

@test "never destroys a locked or suspended VM" {
    make_vm 9001 runner-1 stopped github 0 0 0 suspended
    age_vm_config 9001 3600
    enable_drain
    run_guard --now
    [ "$status" -eq 0 ]
    ! destroyed 9001
    [[ "$output" == *"lock: suspended"* ]]
}

@test "never destroys a VMID listed in GUARD_EXCLUDE_VMIDS" {
    config_set GUARD_EXCLUDE_VMIDS "9001, 9004"
    make_vm 9001 runner-1 running github 36000
    make_vm 9002 runner-2 running github 36000
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    destroyed 9002
}

# --- lifetime ceiling ---------------------------------------------------------

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

@test "honours MAX_VM_LIFETIME_HOURS from the config" {
    config_set MAX_VM_LIFETIME_HOURS 2
    make_vm 9001 runner-1 running github $((3 * 3600))
    run_guard
    [ "$status" -eq 0 ]
    destroyed 9001
}

@test "falls back to the default ceiling when the config value is garbage" {
    config_set MAX_VM_LIFETIME_HOURS forever
    make_vm 9001 runner-1 running github $((9 * 3600))
    make_vm 9002 runner-2 running github $((7 * 3600))
    run_guard
    [ "$status" -eq 0 ]
    destroyed 9001
    ! destroyed 9002
}

@test "an unreadable uptime never destroys, and never does so silently" {
    make_vm 9001 runner-1 running github ""
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    [[ "$output" == *"no readable uptime"* ]]
    grep -q "no readable uptime for runner-1" "$SANDBOX/logger.log"
    grep -q "no-uptime 1" "$SANDBOX/logger.log"
}

# --- stopped reaping ----------------------------------------------------------

@test "gives a freshly stopped VM the full grace period" {
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    [ -f "$SANDBOX/run/guard/9001.stopped" ]
}

@test "destroys a VM stopped for longer than STOPPED_REAP_MINUTES" {
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    run_guard
    ! destroyed 9001
    age_marker 9001 $((11 * 60))
    run_guard
    [ "$status" -eq 0 ]
    destroyed 9001
}

@test "refuses to reap a stopped VM whose config was just written" {
    # The structural freshness check, isolated: the marker says this VM has been
    # stopped for eleven minutes and matches the config mtime, so only the
    # freshness rule stands between the guard and a clone that just landed.
    make_vm 9001 runner-1 stopped github
    mkdir -p "$SANDBOX/run/guard"
    printf '%s %s\n' "$(( $(date +%s) - 11 * 60 ))" "$(stat -c %Y "$(vm_conf 9001)")" \
        > "$SANDBOX/run/guard/9001.stopped"
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
}

@test "restarts the stopped clock when the VM config is rewritten" {
    # A recycled VMID must not inherit the previous VM's observed age.
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    run_guard
    age_marker 9001 $((11 * 60))
    age_vm_config 9001 1800
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    read -r first _ < "$SANDBOX/run/guard/9001.stopped"
    [ "$first" -gt 0 ]
}

@test "never reaps a stopped VM whose config mtime cannot be read" {
    make_vm 9001 runner-1 stopped github
    rm -f "$(vm_conf 9001)"
    enable_drain
    run_guard --now
    [ "$status" -eq 0 ]
    ! destroyed 9001
    [[ "$output" == *"no readable config mtime"* ]]
    grep -q "no-mtime 1" "$SANDBOX/logger.log"
}

# --- --now / runner start -----------------------------------------------------

@test "--now refuses to run unless the pool is draining" {
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    run_guard --stopped-only --now
    [ "$status" -eq 1 ]
    ! destroyed 9001
    [[ "$output" == *"requires maintenance mode"* ]]
}

@test "--now reaps a stopped VM immediately while draining" {
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    enable_drain
    run_guard --stopped-only --now
    [ "$status" -eq 0 ]
    destroyed 9001
}

@test "--now still refuses a VM whose config was written seconds ago" {
    # GUARD_MIN_CONFIG_AGE_SECONDS floor: `runner create` takes no slot lock, so
    # this is what keeps a maintenance reap off a clone that just landed.
    make_vm 9001 runner-1 stopped github
    enable_drain
    run_guard --stopped-only --now
    [ "$status" -eq 0 ]
    ! destroyed 9001
}

@test "--stopped-only skips the lifetime check" {
    make_vm 9001 runner-1 running github $((99 * 3600))
    enable_drain
    run_guard --stopped-only --now
    [ "$status" -eq 0 ]
    ! destroyed 9001
}

@test "runner start reaps stopped VMs and clears the drain flag" {
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    : > "$SANDBOX/run/lock/drain"
    run "$SANDBOX/lib/start.sh"
    echo "start status: $status"
    echo "start output: $output"
    [ "$status" -eq 0 ]
    destroyed 9001
    [ ! -e "$SANDBOX/run/lock/drain" ]
}

# --- concurrency --------------------------------------------------------------

@test "leaves a VM alone while another process holds its slot lock" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    hold_slot_lock runner-1
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    grep -q "deferred 1" "$SANDBOX/logger.log"
}

@test "one busy slot does not stop the others being reaped" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    make_vm 9002 runner-2 running github $((9 * 3600))
    hold_slot_lock runner-1
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    destroyed 9002
}

@test "escalates when the same VM is deferred run after run" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    hold_slot_lock runner-1
    run_guard
    run_guard
    run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    grep -q "deferred 3 consecutive runs" "$SANDBOX/logger.log"
    [[ "$output" == *"deferred 3 runs in a row"* ]]
}

@test "reports failure when a caller that asked us to wait still could not finish" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    hold_slot_lock runner-1
    run_guard --wait 1
    [ "$status" -eq 1 ]
    ! destroyed 9001
}

@test "reaps once the slot lock is released" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    hold_slot_lock runner-1
    run_guard
    ! destroyed 9001
    kill "$HOLDER_PID"
    wait "$HOLDER_PID" 2>/dev/null || true
    HOLDER_PID=""
    run_guard
    [ "$status" -eq 0 ]
    destroyed 9001
    [ ! -f "$SANDBOX/run/guard/9001.deferred" ]
}

# --- state hygiene ------------------------------------------------------------

@test "sweeps stale markers for VMIDs that are no longer stopped runners" {
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    run_guard
    [ -f "$SANDBOX/run/guard/9001.stopped" ]
    sed -i.bak 's/^STATUS=.*/STATUS="running"/' "$SANDBOX/vms/9001"
    run_guard
    [ ! -f "$SANDBOX/run/guard/9001.stopped" ]
}

@test "keeps a marker when that VM's config could not be read" {
    # Deleting it would silently restart the VM's ten-minute clock forever.
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    run_guard
    age_marker 9001 $((11 * 60))
    STUB_CONFIG_FAIL=9001 run_guard
    [ "$status" -eq 0 ]
    ! destroyed 9001
    [ -f "$SANDBOX/run/guard/9001.stopped" ]
    [[ "$output" == *"could not read config for VMID 9001"* ]]
    grep -q "unreadable 1" "$SANDBOX/logger.log"
    # The marker survived, so the next healthy run reaps it instead of
    # restarting the ten-minute clock.
    run_guard
    destroyed 9001
}

@test "keeps every marker and reports failure when qm list fails" {
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    run_guard
    [ -f "$SANDBOX/run/guard/9001.stopped" ]
    STUB_LIST_FAIL=1 run_guard
    [ "$status" -eq 1 ]
    [ -f "$SANDBOX/run/guard/9001.stopped" ]
    grep -q "qm list failed" "$SANDBOX/logger.log"
}

# --- reporting ----------------------------------------------------------------

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
    grep -q "destroyed 0, failed 1" "$SANDBOX/logger.log"
}

@test "--dry-run destroys nothing and writes no state" {
    make_vm 9001 runner-1 running github $((9 * 3600))
    make_vm 9002 runner-2 stopped github
    age_vm_config 9002 3600
    run_guard --dry-run
    [ "$status" -eq 0 ]
    ! destroyed 9001
    ! destroyed 9002
    [[ "$output" == *"would destroy runner-1 (VMID 9001)"* ]]
    [ ! -f "$SANDBOX/run/guard/9002.stopped" ]
    grep -q "dry run: checked 2 managed VM(s), would destroy 1" "$SANDBOX/logger.log"
}

@test "emits spec notifications through lib/notify.sh when it is installed" {
    # notify.sh ships with the notification library; every other test in this
    # file runs without it, which is the guard's other required behaviour.
    cat > "$SANDBOX/lib/notify.sh" <<EOF
notify() { printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$SANDBOX/notify.log"; }
EOF
    make_vm 9001 runner-1 running github $((9 * 3600))
    make_vm 9002 runner-2 stopped github
    age_vm_config 9002 3600
    run_guard
    age_marker 9002 $((11 * 60))
    run_guard
    [ "$status" -eq 0 ]
    grep -q "^warn|lifetime.forced_destroy|forced destroy of runner-1 (VMID 9001)" "$SANDBOX/notify.log"
    grep -q "^warn|stopped_vm.reaped|forced destroy of runner-2 (VMID 9002)" "$SANDBOX/notify.log"
}

@test "notifies at info for the maintenance reap, and never on a dry run" {
    cat > "$SANDBOX/lib/notify.sh" <<EOF
notify() { printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$SANDBOX/notify.log"; }
EOF
    make_vm 9001 runner-1 stopped github
    age_vm_config 9001 3600
    run_guard --dry-run
    [ ! -f "$SANDBOX/notify.log" ]
    enable_drain
    run_guard --stopped-only --now
    [ "$status" -eq 0 ]
    grep -q "^info|stopped_vm.reaped|" "$SANDBOX/notify.log"
}

@test "rejects unknown options instead of guessing" {
    run_guard --destroy-everything
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}
