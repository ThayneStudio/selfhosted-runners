#!/usr/bin/env bats
# generation_refcount counts live VM configs attributed to a generation by
# tag or origin (spec 5). Untagged clones with no origin go to the active
# generation. write_infra_config still defaults MIN_VMID=500, which overlaps
# the generation band, so tests set 9001.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib generations.sh
    MIN_VMID=9001
    TEMPLATE_ID=8901
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=8901
    apply_generation_defaults
}

# Two generations: 5 (superseded, VMID 8900) and 9 (active, VMID 8901).
create_two_gens() {
    gen_store_init
    gen_create 8900 \
        GEN_ID=5 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0
    gen_create 8901 \
        GEN_ID=9 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=newdigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0
}

stub_template_configs() {
    stub_out qm 'config 8900' <<'EOF'
name: gen-5-template
scsi0: local-zfs:base-8900-disk-0,size=30G
template: 1
tags: runner;gen-5
EOF
    stub_out qm 'config 8901' <<'EOF'
name: gen-9-template
scsi0: local-zfs:base-8901-disk-0,size=30G
template: 1
tags: runner;gen-9
EOF
}

# No linked-clone children: dir/lvm without nested volids, or empty storage.
stub_empty_origin() {
    stub_out pvesm 'list *' <<'EOF'
Volid Format
local-zfs:base-8900-disk-0 raw
local-zfs:base-8901-disk-0 raw
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF
}

qm_list() {
    local body="$1"
    stub_out qm 'list' <<EOF
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      8900 gen-5-template       stopped    8192              30.00 0
      8901 gen-9-template       stopped    8192              30.00 0
$body
EOF
}

@test "generation_refcount counts VMs tagged gen-N and excludes the template" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      9001 acme-1               running    8192              30.00 1234
      9002 acme-2               running    8192              30.00 1235"
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-5
EOF
    stub_out qm 'config 9002' <<'EOF'
name: acme-2
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-9
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    refute_called qm 'destroy *'
    refute_called pvesm 'free *'
}

@test "generation_refcount is zero when no clones exist" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list ""

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "generation_refcount counts an untagged clone via ZFS origin" {
    create_two_gens
    stub_template_configs
    qm_list "      9003 acme-3               running    8192              30.00 1236"
    stub_out qm 'config 9003' <<'EOF'
name: acme-3
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-8900-disk-0                     raw     images     32212254720 8900
local-zfs:base-8901-disk-0                     raw     images     32212254720 8901
local-zfs:vm-9003-disk-0                       raw     images     32212254720 9003
EOF
    stub_out pvesm 'path local-zfs:base-8900-disk-0' <<'EOF'
/dev/zvol/tank/base-8900-disk-0
EOF
    stub_out pvesm 'path local-zfs:base-8901-disk-0' <<'EOF'
/dev/zvol/tank/base-8901-disk-0
EOF
    stub_out pvesm 'path local-zfs:vm-9003-disk-0' <<'EOF'
/dev/zvol/tank/vm-9003-disk-0
EOF
    stub_out zfs 'list -H -o name *' < /dev/null
    stub_out zfs 'get -H -o value origin tank/vm-9003-disk-0' <<'EOF'
tank/base-8900-disk-0@__base__
EOF
    stub_out zfs 'get -H -o value origin tank/base-8900-disk-0' <<'EOF'
-
EOF
    stub_out zfs 'get -H -o value origin tank/base-8901-disk-0' <<'EOF'
-
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "generation_refcount counts an untagged clone via nested volid origin" {
    create_two_gens
    stub_template_configs
    qm_list "      9003 acme-3               running    8192              30.00 1236"
    stub_out qm 'config 9003' <<'EOF'
name: acme-3
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-8900-disk-0                     raw     images     32212254720 8900
local-zfs:base-8901-disk-0                     raw     images     32212254720 8901
local-zfs:base-8900-disk-0/vm-9003-disk-0      raw     images     32212254720 9003
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "untagged clone with no origin is attributed to the active generation with a warning" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      9004 acme-4               running    8192              30.00 1237"
    stub_out qm 'config 9004' <<'EOF'
name: acme-4
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"[WARN]"* ]]
    [[ "$stderr" == *"9004"* ]]
    [[ "$stderr" == *"untagged"* ]]
    [[ "$stderr" == *"active"* ]]
}

@test "untagged clone with no origin is not counted for a superseded generation" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      9004 acme-4               running    8192              30.00 1237"
    stub_out qm 'config 9004' <<'EOF'
name: acme-4
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    [[ "$stderr" == *"[WARN]"* ]]
    [[ "$stderr" == *"untagged"* ]]
}

@test "a non-runner VM with no tag and no origin is not attributed" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      777 leftover             running    8192              30.00 1"
    stub_out qm 'config 777' <<'EOF'
name: leftover
EOF

    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    [[ "$stderr" != *"untagged"* ]]
}

@test "tag vs origin disagreement warns and counts the VM for both generations" {
    create_two_gens
    stub_template_configs
    qm_list "      9005 acme-5               running    8192              30.00 1238"
    stub_out qm 'config 9005' <<'EOF'
name: acme-5
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-5
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-8900-disk-0                     raw     images     32212254720 8900
local-zfs:base-8901-disk-0                     raw     images     32212254720 8901
local-zfs:base-8901-disk-0/vm-9005-disk-0      raw     images     32212254720 9005
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"[WARN]"* ]]
    [[ "$stderr" == *"disagrees"* ]]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"disagrees"* ]]
}

@test "two disks on one clone count as one VM" {
    create_two_gens
    stub_template_configs
    qm_list "      9001 acme-1               running    8192              30.00 1234"
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-5
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-8900-disk-0                     raw     images     32212254720 8900
local-zfs:base-8901-disk-0                     raw     images     32212254720 8901
local-zfs:base-8900-disk-0/vm-9001-disk-0      raw     images     32212254720 9001
local-zfs:base-8900-disk-0/vm-9001-disk-1      raw     images     32212254720 9001
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "generation_refcount fails closed when linked-clone listing fails" {
    create_two_gens
    stub_template_configs
    stub_status pvesm 'list *' 1
    qm_list "      9001 acme-1               running    8192              30.00 1234"
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
tags: runner;gen-5
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -ne 0 ]
    [ "$output" != "0" ]
    [ "$output" != "1" ]
}

@test "generation_refcount fails closed when qm list fails" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    stub_status qm 'list' 1

    run --separate-stderr generation_refcount 5
    [ "$status" -ne 0 ]
    [ "$output" != "0" ]
}

@test "generation_refcount fails for an unknown generation id" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list ""

    run --separate-stderr generation_refcount 99
    [ "$status" -ne 0 ]
}

@test "generation_refcount fails closed on an unreadable generation record" {
    create_two_gens
    printf 'garbage\n' >> "$GENERATIONS_DIR/8900.conf"
    stub_template_configs
    stub_empty_origin
    qm_list ""

    run --separate-stderr generation_refcount 9
    [ "$status" -ne 0 ]
}

@test "a Proxmox template that is not a generation record is not counted" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      8800 other-template       stopped    8192              30.00 0"
    stub_out qm 'config 8800' <<'EOF'
name: other-template
template: 1
tags: runner;gen-5
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}
