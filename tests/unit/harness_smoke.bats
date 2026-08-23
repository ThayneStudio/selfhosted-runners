#!/usr/bin/env bats
# Proves the harness itself, and doubles as the worked example for the stub
# API. If you are writing a new test file, read this one first.

load test_helper

@test "the fake qm shadows anything real" {
    run command -v qm
    [ "$output" = "$REPO_ROOT/tests/stubs/bin/qm" ]
}

@test "an unprogrammed stub succeeds silently" {
    run pvesm list local-zfs
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "stub_out matches an exact argument list" {
    stub_out zfs 'get -H -o value origin tank/vm-501-disk-0' <<'EOF'
tank/base-9000-disk-0@__base__
EOF

    run zfs get -H -o value origin tank/vm-501-disk-0
    [ "$output" = "tank/base-9000-disk-0@__base__" ]

    run zfs get -H -o value origin tank/vm-502-disk-0
    [ "$output" = "" ]
}

@test "stub_out patterns are globs" {
    stub_out qm 'config *' <<'EOF'
name: runner-acme-a1b2
EOF

    run qm config 501
    [ "$output" = "name: runner-acme-a1b2" ]
    run qm config 502
    [ "$output" = "name: runner-acme-a1b2" ]
}

@test "the newest matching rule wins, so a test can override its setup" {
    stub_out qm '*' <<'EOF'
from the broad rule
EOF
    stub_out qm 'config 501' <<'EOF'
from the specific rule
EOF

    run qm config 501
    [ "$output" = "from the specific rule" ]
    run qm config 502
    [ "$output" = "from the broad rule" ]
}

@test "stub_status makes a call fail" {
    stub_status qm 'start 501' 1

    run qm start 501
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "stub_out can pair output with a non-zero status" {
    stub_out pvesm 'free local-zfs:vm-501-disk-0' 5 <<'EOF'
volume is busy
EOF

    run pvesm free local-zfs:vm-501-disk-0
    [ "$status" -eq 5 ]
    [ "$output" = "volume is busy" ]
}

@test "calls are recorded in order and can be asserted on" {
    qm clone 9000 501 --name runner-acme-a1b2
    qm start 501

    [ "$(stub_calls qm)" = "clone 9000 501 --name runner-acme-a1b2
start 501" ]

    assert_called qm 'clone 9000 501 *'
    assert_called qm 'start 501'
    refute_called qm 'destroy *'
    [ "$(call_count qm)" -eq 2 ]
    [ "$(call_count qm 'start *')" -eq 1 ]
}

@test "an exported function stubs behavior a canned response cannot" {
    # State that changes between calls: the VM is running until it is not.
    qm_stub() {
        if [[ "$*" == "status 501" ]]; then
            if [[ -e "$STUB_DIR/stopped" ]]; then
                echo "status: stopped"
            else
                : > "$STUB_DIR/stopped"
                echo "status: running"
            fi
        fi
    }
    export -f qm_stub

    run qm status 501
    [ "$output" = "status: running" ]
    run qm status 501
    [ "$output" = "status: stopped" ]
}

@test "host paths point at the sandbox, never at /etc or /run" {
    load_lib

    [ "${CONFIG_FILE#"$STUB_DIR"}" != "$CONFIG_FILE" ]
    [ "${POOL_DRAIN_FILE#"$STUB_DIR"}" != "$POOL_DRAIN_FILE" ]

    write_org_config acme
    run list_orgs
    [ "$output" = "acme" ]
}
