#!/usr/bin/env bats
# runner list gains a generation column from VM tags.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib list.sh
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
}

@test "lib/list.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/list.sh"
}

@test "runner list shows a GEN column from tags" {
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1234
      9002 runner-2             stopped    8192              30.00 0
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF
    stub_out qm 'config 9002' <<'EOF'
name: runner-2
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner
EOF

    run --separate-stderr list_runners
    [ "$status" -eq 0 ]
    [[ "$output" == *"GEN"* ]]
    [[ "$output" == *"9001"* ]]
    [[ "$output" == *"acme"* ]]
    [ "$(echo "$output" | awk '/^9001/{print $NF}')" = "1" ]
    [ "$(echo "$output" | awk '/^9002/{print $NF}')" = "-" ]
    [[ "$output" != *"9000"* ]]
    refute_called qm 'set *'
    refute_called qm 'clone *'
    refute_called qm 'destroy *'
}

@test "runner list reports no runners when the fleet is empty" {
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
EOF

    run --separate-stderr list_runners
    [ "$status" -eq 0 ]
    [[ "$output" == *"(no runners found)"* ]]
}
