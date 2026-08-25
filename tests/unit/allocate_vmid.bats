#!/usr/bin/env bats
# Generation VMID allocation from the template band (spec 4.2).
#
# vmid_in_use / vm_config_path probe $PVE_NODES_DIR/*/qemu-server/<vmid>.conf,
# not `qm config`. Tests occupy a VMID by writing a sandbox config file.

load test_helper

setup() {
    load_lib generations.sh
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_BAND_MIN=8900
    TEMPLATE_BAND_MAX=8902
    apply_generation_defaults
    TEMPLATE_BAND_MIN=8900
    TEMPLATE_BAND_MAX=8902
}

teardown() {
    [[ -z "${HOLDER_PID:-}" ]] || kill "$HOLDER_PID" 2>/dev/null || true
}

# Write a Proxmox qemu-server conf so vmid_in_use reports this VMID occupied.
occupy_vmid() {
    local vmid="$1"
    mkdir -p "$PVE_NODES_DIR/pve/qemu-server"
    cat > "$PVE_NODES_DIR/pve/qemu-server/${vmid}.conf"
}

@test "allocate_generation_vmid returns the lowest free band VMID" {
    run allocate_generation_vmid
    [ "$status" -eq 0 ]
    [ "$output" = "8900" ]
}

@test "allocate_generation_vmid skips a VMID that already has a config" {
    occupy_vmid 8900 <<'EOF'
name: leftover
EOF
    run allocate_generation_vmid
    [ "$status" -eq 1 ]
    [[ "$output" == *8900* ]]
}

@test "foreign config inside the band is a hard error before allocation" {
    occupy_vmid 8900 <<'EOF'
name: orcest-something
EOF
    run validate_band_inventory
    [ "$status" -eq 1 ]
    [[ "$output" == *8900* ]]
}

@test "allocate_generation_vmid refuses to hand out a VMID with a live generation record" {
    gen_store_init
    gen_create 8900 GEN_ID=1 GEN_STATE=failed GEN_RUNNER_VERSION=x GEN_IMAGE_SHA256=y GEN_TEMPLATE_DIGEST=z
    occupy_vmid 8900 <<'EOF'
name: ubuntu-cloud-template
template: 1
EOF
    run allocate_generation_vmid
    [ "$status" -eq 0 ]
    [ "$output" = "8901" ]
}

@test "allocate_generation_vmid fails when the band is exhausted" {
    gen_store_init
    gen_create 8900 GEN_ID=1 GEN_STATE=failed GEN_RUNNER_VERSION=x GEN_IMAGE_SHA256=y GEN_TEMPLATE_DIGEST=z
    gen_create 8901 GEN_ID=2 GEN_STATE=failed GEN_RUNNER_VERSION=x GEN_IMAGE_SHA256=y GEN_TEMPLATE_DIGEST=z
    gen_create 8902 GEN_ID=3 GEN_STATE=failed GEN_RUNNER_VERSION=x GEN_IMAGE_SHA256=y GEN_TEMPLATE_DIGEST=z
    run allocate_generation_vmid
    [ "$status" -eq 1 ]
    [[ "$output" == *exhausted* ]]
}

@test "allocate_generation_vmid is busy when the generation VMID lock is held" {
    # Independent process so the allocator does not inherit the fd. flock is
    # not stubbed: a fake that always succeeds would not prove flock -n.
    local ready="$STUB_DIR/gen-vmid-lock-ready"
    rm -f "$ready"
    python3 -c '
import fcntl, sys, time
f = open(sys.argv[1], "w")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)
' "$GENERATION_VMID_LOCK_FILE" "$ready" &
    HOLDER_PID=$!
    local waited=0
    while [[ ! -e "$ready" && "$waited" -lt 100 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    [[ -e "$ready" ]]
    run allocate_generation_vmid
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
    [ "$status" -eq 1 ]
    [[ "$output" == *busy* ]]
}
