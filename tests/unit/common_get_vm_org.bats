#!/usr/bin/env bats
# get_vm_org is how every command tells a runner VM from an unrelated one on
# the same host, so its regex decides what `runner stop` and `runner destroy`
# are allowed to touch. Exercised entirely through the fake qm.

load test_helper

setup() {
    load_lib
}

# The per-VM snippet is what every clone minted since the JIT refactor carries;
# the legacy per-org name below only survives on VMs cloned before it.
@test "get_vm_org reads the org out of a per-VM JIT snippet name" {
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-9001-user-acme.yaml,meta=local:snippets/runner-9001-meta.yaml
EOF

    run get_vm_org 9001
    [ "$output" = "acme" ]
    assert_called qm 'config 9001'
}

@test "get_vm_org keeps hyphens in the org name of a per-VM JIT snippet" {
    stub_out qm 'config *' <<'EOF'
cicustom: user=local:snippets/runner-9002-user-thayne-studio.yaml,meta=local:snippets/runner-9002-meta.yaml
EOF

    run get_vm_org 9002
    [ "$output" = "thayne-studio" ]
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

@test "get_vm_generation reads gen-N from semicolon tags" {
    stub_out qm 'config 501' <<'EOF'
name: runner-acme-1
tags: runner;gen-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run get_vm_generation 501
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "get_vm_generation reads gen-N from comma tags" {
    stub_out qm 'config 502' <<'EOF'
tags: runner,gen-7
EOF

    run get_vm_generation 502
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]
}

# get_vm_generation now fails closed (status 1) rather than silently
# succeeding when a VM has no gen-N tag or does not exist -- #17 hardened the
# contract so an untagged/unknown VM cannot be mistaken for "generation
# unknown, count as 0" by callers doing refcount math. See the exhaustive
# coverage of this contract in tests/unit/common_get_vm_generation.bats;
# these two are kept here (updated) because they were part of this file
# originally.
@test "get_vm_generation is empty when tags have no gen-N" {
    stub_out qm 'config 503' <<'EOF'
name: runner-acme-1
tags: runner
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run get_vm_generation 503
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "get_vm_generation is empty when the vmid does not exist" {
    stub_status qm 'config 999' 2

    run get_vm_generation 999
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}
