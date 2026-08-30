#!/usr/bin/env bats
# Conservative tag-based clone refcount (spec 5). No ZFS origin, no GC.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib generations.sh
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
}

make_active() {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_RUNNER_VERSION=2.334.0 \
        GEN_TEMPLATE_DIGEST=abc \
        GEN_IMAGE_SHA256=abc \
        GEN_CREATED_AT=2026-08-22T00:00:00Z
}

@test "generation_refcount counts tagged clones and excludes the template VMID" {
    make_active
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1234
      9002 runner-2             running    8192              30.00 1235
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF
    stub_out qm 'config 9002' <<'EOF'
name: runner-2
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
    refute_called qm 'set *'
    refute_called qm 'clone *'
    refute_called qm 'destroy *'
}

@test "generation_refcount attributes untagged runners to the active generation and warns" {
    make_active
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"missing gen-"* ]]
    [[ "$stderr" == *"9001"* ]]
}

@test "generation_refcount does not attribute untagged runners to a superseded generation" {
    gen_store_init
    gen_create 8900 \
        GEN_ID=1 \
        GEN_STATE=superseded \
        GEN_RUNNER_VERSION=2.333.0 \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_CREATED_AT=2026-08-01T00:00:00Z
    gen_create 9000 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_RUNNER_VERSION=2.334.0 \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_CREATED_AT=2026-08-22T00:00:00Z

    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      8900 github-runner-gen-1  stopped    8192              30.00 0
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run --separate-stderr generation_refcount 2
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "generation_refcount ignores untagged non-runner VMs" {
    make_active
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      777  other                running    8192              30.00 9
EOF
    stub_out qm 'config 777' <<'EOF'
name: other
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    [[ "$stderr" != *"missing gen-"* ]]
}

@test "generation_refcount degrades to 0 with no generation records" {
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9001 runner-1             running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "generation_refcount refuses a non-numeric id" {
    run --separate-stderr generation_refcount abc
    [ "$status" -eq 1 ]
}

@test "generation_disk_usage reports pvesm Size as GiB" {
    stub_out pvesm 'list local-zfs' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-9000-disk-0                     raw     images     32212254720 9000
local-zfs:vm-9001-disk-0                       raw     images     32212254720 9001
EOF

    run generation_disk_usage 9000
    [ "$status" -eq 0 ]
    [ "$output" = "30G" ]
}

@test "generation_disk_usage is dash when pvesm list fails" {
    stub_status pvesm 'list local-zfs' 1

    run generation_disk_usage 9000
    [ "$status" -eq 0 ]
    [ "$output" = "-" ]
}
