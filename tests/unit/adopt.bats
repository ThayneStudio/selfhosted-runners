#!/usr/bin/env bats
# Adoption of the already-deployed TEMPLATE_ID template as generation 1 (spec 8).
#
# Inventory matches lib/guard.sh / lib/list.sh: `qm list` plus per-VM
# `qm config`, not `qm list --full`. write_infra_config still defaults
# MIN_VMID=500, which overlaps the generation band, so tests set 9001.

load test_helper

setup() {
    load_lib generations.sh
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
}

# Nested linked-clone volid so tagging traces to TEMPLATE_ID (not cicustom).
stub_origin_clone() {
    local child="${1:-9001}"
    stub_out qm "config ${TEMPLATE_ID}" <<EOF
name: ubuntu-cloud-template
scsi0: ${VM_STORAGE}:base-${TEMPLATE_ID}-disk-0,size=30G
template: 1
EOF
    stub_out pvesm 'list *' <<EOF
Volid Format
${VM_STORAGE}:base-${TEMPLATE_ID}-disk-0 raw
${VM_STORAGE}:base-${TEMPLATE_ID}-disk-0/vm-${child}-disk-0 raw
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF
}

# Default fleet: template 9000 plus one untagged running clone.
stub_adopt_fleet() {
    stub_out qm 'status 9000' <<'EOF'
status: stopped
template: 1
EOF
    stub_origin_clone 9001
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      8999 leftover             running    8192              30.00 1
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 acme-1               running    8192              30.00 1234
      9002 other                running    8192              30.00 1235
EOF
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out qm 'config 9002' <<'EOF'
name: other
EOF
    stub_out qm 'set 9001 --tags runner,gen-1'
    write_org_config acme
}

@test "adopt creates GEN_ID=1 active with unknown digest when the store is empty" {
    stub_adopt_fleet
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_ID" = "1" ]
    [ "$GEN_STATE" = "active" ]
    [ "$GEN_VMID" = "9000" ]
    [ "$GEN_TEMPLATE_DIGEST" = "unknown" ]
    [ "$GEN_IMAGE_SHA256" = "unknown" ]
    [ "$GEN_RUNNER_VERSION" = "unknown" ]
}

@test "adopt is a no-op on the second run" {
    stub_adopt_fleet
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    count=$(gen_list | wc -l | tr -d ' ')
    [ "$count" = "1" ]
}

@test "adopt does not call qm destroy" {
    stub_adopt_fleet
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    refute_called qm 'destroy*'
}

@test "adopt is a no-op when the store already has any record" {
    gen_create 8900 GEN_ID=1 GEN_STATE=active
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    [ "$(gen_list)" = "8900" ]
    run gen_read 9000
    [ "$status" -ne 0 ]
    refute_called qm '*'
}

@test "adopt returns 0 when TEMPLATE_ID is missing" {
    stub_status qm 'status 9000' 2
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    [ "$(gen_list)" = "" ]
    [[ "$output" == *"nothing to adopt"* ]]
}

@test "adopt tags a stopped runner clone gen-1" {
    stub_out qm 'status 9000' <<'EOF'
status: stopped
EOF
    stub_origin_clone 9001
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 acme-1               stopped    8192              30.00 0
EOF
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out qm 'set 9001 --tags runner,gen-1'
    write_org_config acme
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    assert_called qm 'set 9001 --tags runner,gen-1'
}

@test "adopt merges gen-1 into existing tags" {
    stub_out qm 'status 9000' <<'EOF'
status: stopped
EOF
    stub_origin_clone 9001
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 acme-1               running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: foo;bar
EOF
    stub_out qm 'set 9001 --tags runner,foo,bar,gen-1'
    write_org_config acme
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    assert_called qm 'set 9001 --tags runner,foo,bar,gen-1'
}

@test "adopt does not retag a clone that already has a gen- tag" {
    stub_out qm 'status 9000' <<'EOF'
status: stopped
EOF
    stub_origin_clone 9001
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 acme-1               running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-2
EOF
    write_org_config acme
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    refute_called qm 'set *'
}

@test "non-template TEMPLATE_ID is not adopted" {
    stub_out qm 'status 9000' <<'EOF'
status: stopped
EOF
    stub_out qm 'config 9000' <<'EOF'
name: leftover-vm
ostype: l26
EOF
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 leftover-vm          stopped    8192              30.00 0
      9001 acme-1               running    8192              30.00 1234
EOF
    write_org_config acme
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    [ "$(gen_list)" = "" ]
    refute_called qm 'set *'
    refute_called qm 'destroy *'
}

@test "adopt resumes tagging untagged clones when the store is gen-1 only" {
    stub_adopt_fleet
    stub_status qm 'set 9001 --tags *' 1
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_ID" = "1" ]
    local first
    first=$(call_count qm 'set 9001 --tags *')
    [ "$first" -ge 1 ]

    stub_out qm 'set 9001 --tags runner,gen-1'
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    [ "$(call_count qm 'set 9001 --tags *')" -gt "$first" ]
    count=$(gen_list | wc -l | tr -d ' ')
    [ "$count" = "1" ]
}

@test "adopt fails closed when pvesm list fails" {
    stub_out qm 'status 9000' <<'EOF'
status: stopped
EOF
    stub_out qm 'config 9000' <<'EOF'
name: ubuntu-cloud-template
template: 1
EOF
    stub_status pvesm 'list *' 1

    run adopt_deployed_template
    [ "$status" -ne 0 ]
    [ "$(gen_list)" = "" ]
    refute_called qm 'destroy *'
}

@test "adopt fails closed when a foreign config occupies the generation band" {
    stub_adopt_fleet
    mkdir -p "$PVE_NODES_DIR/pve/qemu-server"
    printf 'name: leftover\n' > "$PVE_NODES_DIR/pve/qemu-server/8900.conf"

    run adopt_deployed_template
    [ "$status" -ne 0 ]
    [ "$(gen_list)" = "" ]
    refute_called qm 'destroy *'
}

@test "adopt tags untagged clones of TEMPLATE_ID even when a candidate record exists" {
    stub_adopt_fleet
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0

    run adopt_deployed_template
    [ "$status" -eq 0 ]
    assert_called qm 'set 9001 --tags runner,gen-1'
    count=$(gen_list | wc -l | tr -d ' ')
    [ "$count" = "2" ]
}

@test "adopt records a probed runner version from a running clone" {
    stub_adopt_fleet
    stub_out qm 'guest exec 9001 -- /home/runner/actions-runner/bin/Runner.Listener --version' <<'EOF'
{
   "exitcode" : 0,
   "exited" : 1,
   "out-data" : "2.328.0\n"
}
EOF
    run adopt_deployed_template
    [ "$status" -eq 0 ]
    gen_read 9000
    [ "$GEN_RUNNER_VERSION" = "2.328.0" ]
}
