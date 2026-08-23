#!/usr/bin/env bats
# Pure helpers in lib/common.sh — no Proxmox, no stubs needed.

load test_helper

setup() {
    load_lib
}

@test "validate_org_name accepts GitHub-shaped names" {
    validate_org_name "acme"
    validate_org_name "ACME"
    validate_org_name "acme-corp"
    validate_org_name "a1"
    validate_org_name "0"
}

@test "validate_org_name rejects names that would escape the config path" {
    run validate_org_name "../etc"
    [ "$status" -ne 0 ]
    run validate_org_name "acme/corp"
    [ "$status" -ne 0 ]
    run validate_org_name "acme corp"
    [ "$status" -ne 0 ]
    run validate_org_name ""
    [ "$status" -ne 0 ]
}

@test "validate_org_name rejects leading and trailing hyphens" {
    run validate_org_name "-acme"
    [ "$status" -ne 0 ]
    run validate_org_name "acme-"
    [ "$status" -ne 0 ]
}

@test "generate_mac is deterministic and locally administered" {
    run generate_mac "runner-acme-1"
    [ "$status" -eq 0 ]
    first="$output"

    # The whole point of deriving from the name: a rebuilt VM keeps its lease.
    run generate_mac "runner-acme-1"
    [ "$output" = "$first" ]

    [[ "$first" =~ ^02(:[0-9a-f]{2}){5}$ ]]
}

@test "generate_mac gives different names different addresses" {
    run generate_mac "runner-acme-1"
    one="$output"
    run generate_mac "runner-acme-2"
    [ "$output" != "$one" ]
}

@test "linked_clone_child_vmid extracts the vmid from a child volid" {
    run linked_clone_child_vmid "local-zfs:base-9000-disk-0/vm-501-disk-0"
    [ "$output" = "501" ]

    run linked_clone_child_vmid "local-lvm:vm-1234-disk-0"
    [ "$output" = "1234" ]
}

@test "linked_clone_child_vmid stays silent on volids that are not clones" {
    run linked_clone_child_vmid "local-zfs:base-9000-disk-0"
    [ "$output" = "" ]

    run linked_clone_child_vmid "local-zfs:vm-abc-disk-0"
    [ "$output" = "" ]
}
