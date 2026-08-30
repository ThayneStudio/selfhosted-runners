#!/usr/bin/env bats
# get_vm_org is how every command tells a runner VM from an unrelated one on
# the same host, so its regex decides what `runner stop` and `runner destroy`
# are allowed to touch. Exercised entirely through the fake qm.

load test_helper

setup() {
    load_lib
}

@test "get_vm_org reads the org out of a full cicustom line" {
    stub_out qm 'config 501' <<'EOF'
name: runner-acme-a1b2
cicustom: user=local:snippets/runner-user-data-acme.yaml,meta=local:snippets/runner-501-meta.yaml
EOF

    run get_vm_org 501
    [ "$output" = "acme" ]
    assert_called qm 'config 501'
}

@test "get_vm_org keeps hyphens in the org name" {
    stub_out qm 'config *' <<'EOF'
cicustom: user=local:snippets/runner-user-data-thayne-studio.yaml,meta=local:snippets/runner-502-meta.yaml
EOF

    run get_vm_org 502
    [ "$output" = "thayne-studio" ]
}

@test "get_vm_org still reads the org when cicustom includes vendor=" {
    stub_out qm 'config 501' <<'EOF'
name: canary-gen5
cicustom: user=local:snippets/runner-user-data-acme.yaml,meta=local:snippets/runner-501-meta.yaml,vendor=local:snippets/runner-501-vendor.yaml
EOF

    run get_vm_org 501
    [ "$output" = "acme" ]
}

@test "get_vm_org reports unknown for a VM with no cicustom" {
    stub_out qm 'config 700' <<'EOF'
name: unrelated-vm
net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0
EOF

    run get_vm_org 700
    [ "$output" = "unknown" ]
}

@test "get_vm_org reports unknown for a cicustom that is not a runner snippet" {
    stub_out qm 'config 701' <<'EOF'
cicustom: user=local:snippets/some-other-user-data.yaml
EOF

    run get_vm_org 701
    [ "$output" = "unknown" ]
}

@test "get_vm_org reports unknown when the vmid does not exist" {
    stub_status qm 'config 999' 2

    run get_vm_org 999
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}
