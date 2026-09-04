#!/usr/bin/env bats
# list_template_linked_clone_volids decides which volumes GC is allowed to
# free, so a wrong answer here either strands disk or frees a live runner's
# disk. Two shapes of linked clone exist: nested volids (LVM-thin, dir) and
# sibling zvols related only by the ZFS origin property.

load test_helper

setup() {
    load_lib
    write_infra_config      # VM_STORAGE=local-zfs, TEMPLATE_ID=9000

    stub_out qm 'config 9000' <<'EOF'
name: runner-template
scsi0: local-zfs:base-9000-disk-0,size=30G
ide2: local-zfs:vm-9000-cloudinit,media=cdrom
template: 1
EOF
}

@test "nested child volids of the template base are reported" {
    stub_out pvesm 'list local-zfs' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-9000-disk-0                     raw     images     32212254720 9000
local-zfs:base-9000-disk-0/vm-501-disk-0       raw     images     32212254720 501
local-zfs:base-9000-disk-0/vm-502-disk-0       raw     images     32212254720 502
local-zfs:vm-777-disk-0                        raw     images     32212254720 777
EOF
    # Not a ZFS storage in this test: the origin pass finds no zvol path.
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF

    run list_template_linked_clone_volids
    [ "$status" -eq 0 ]
    [ "$output" = "local-zfs:base-9000-disk-0/vm-501-disk-0
local-zfs:base-9000-disk-0/vm-502-disk-0" ]
}

@test "an unrelated VM's volume on the same storage is left alone" {
    stub_out pvesm 'list local-zfs' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-9000-disk-0                     raw     images     32212254720 9000
local-zfs:vm-777-disk-0                        raw     images     32212254720 777
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF

    run list_template_linked_clone_volids
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "sibling zvols are matched through the ZFS origin property" {
    stub_out pvesm 'list local-zfs' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-9000-disk-0                     raw     images     32212254720 9000
local-zfs:vm-503-disk-0                        raw     images     32212254720 503
local-zfs:vm-777-disk-0                        raw     images     32212254720 777
EOF
    stub_out pvesm 'path local-zfs:base-9000-disk-0' <<'EOF'
/dev/zvol/tank/base-9000-disk-0
EOF
    stub_out pvesm 'path local-zfs:vm-503-disk-0' <<'EOF'
/dev/zvol/tank/vm-503-disk-0
EOF
    stub_out pvesm 'path local-zfs:vm-777-disk-0' <<'EOF'
/dev/zvol/tank/vm-777-disk-0
EOF
    stub_out zfs 'list -H -o name *' < /dev/null
    stub_out zfs 'get -H -o value origin tank/vm-503-disk-0' <<'EOF'
tank/base-9000-disk-0@__base__
EOF
    # An independent volume: no origin, so no relationship to the template.
    stub_out zfs 'get -H -o value origin tank/vm-777-disk-0' <<'EOF'
-
EOF

    run list_template_linked_clone_volids
    [ "$status" -eq 0 ]
    [ "$output" = "local-zfs:vm-503-disk-0" ]
}

@test "a storage listing that fails is an error, not an empty result" {
    # Reporting "no children" when the storage cannot be listed would let a
    # caller conclude the template is safe to delete.
    stub_status pvesm 'list local-zfs' 2

    run list_template_linked_clone_volids
    [ "$status" -eq 1 ]
}

@test "an unreadable config for a live recorded template fails closed" {
    stub_status qm 'config 9000' 2
    stub_out qm 'status 9000' <<'EOF'
status: stopped
EOF
    stub_out pvesm 'list local-zfs' <<'EOF'
Volid Format
local-zfs:base-9000-disk-0 raw
EOF

    run list_template_base_volids 9000
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot read config for live template VMID 9000"* ]]
}

@test "a positively absent config recovers residual base volumes from storage" {
    stub_status qm 'config 9000' 2
    stub_status qm 'status 9000' 2
    stub_out pvesm 'list local-zfs' <<'EOF'
Volid Format
local-zfs:base-9000-disk-0 raw
EOF

    run list_template_base_volids 9000
    [ "$status" -eq 0 ]
    [ "$output" = "local-zfs:base-9000-disk-0" ]
}
