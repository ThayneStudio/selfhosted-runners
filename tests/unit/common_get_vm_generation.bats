#!/usr/bin/env bats
# get_vm_generation is how GC attributes a live clone to a generation: it
# parses tags: from qm config, independent of storage backend.

load test_helper

setup() {
    load_lib
}

@test "get_vm_generation reads gen-N from semicolon-separated tags" {
    stub_out qm 'config 9001' <<'EOF'
name: runner-acme-1
tags: runner;gen-5
EOF

    run get_vm_generation 9001
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
    assert_called qm 'config 9001'
}

@test "get_vm_generation reads gen-N from comma-separated tags" {
    stub_out qm 'config 9001' <<'EOF'
name: runner-acme-1
tags: runner,gen-9
EOF

    run get_vm_generation 9001
    [ "$status" -eq 0 ]
    [ "$output" = "9" ]
}

@test "get_vm_generation finds gen-N among other tags" {
    stub_out qm 'config 9001' <<'EOF'
name: canary-gen5
tags: runner;gen-5;runner-canary
EOF

    run get_vm_generation 9001
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "get_vm_generation strips whitespace around tags" {
    stub_out qm 'config 9001' <<'EOF'
name: runner-acme-1
tags: runner; gen-7 ;foo
EOF

    run get_vm_generation 9001
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]
}

@test "get_vm_generation normalizes a zero-padded generation id" {
    stub_out qm 'config 9001' <<'EOF'
tags: runner;gen-08
EOF

    run get_vm_generation 9001
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
}

@test "get_vm_generation ignores a gen- prefix that is not a generation id" {
    stub_out qm 'config 9001' <<'EOF'
tags: runner;gen-canary;gen-abc
EOF

    run get_vm_generation 9001
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "get_vm_generation still finds gen-N after a non-numeric gen- tag" {
    stub_out qm 'config 9001' <<'EOF'
tags: gen-canary;gen-3;runner
EOF

    run get_vm_generation 9001
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "get_vm_generation fails when the VM has no tags line" {
    stub_out qm 'config 9001' <<'EOF'
name: runner-acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run get_vm_generation 9001
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "get_vm_generation fails when tags have no gen-N" {
    stub_out qm 'config 9001' <<'EOF'
name: runner-acme-1
tags: runner;linux
EOF

    run get_vm_generation 9001
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "get_vm_generation fails when the VM does not exist" {
    stub_status qm 'config 999' 2

    run get_vm_generation 999
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
