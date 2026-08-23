#!/usr/bin/env bats
# Proves the harness itself, and doubles as the worked example for the stub
# API. If you are writing a new test file, read this one first.

load test_helper

@test "the fake qm shadows anything real" {
    run command -v qm
    [ "$output" = "$REPO_ROOT/tests/stubs/bin/qm" ]
}

@test "stub_out matches an exact argument list" {
    stub_out zfs 'get -H -o value origin tank/vm-501-disk-0' <<'EOF'
tank/base-9000-disk-0@__base__
EOF

    run zfs get -H -o value origin tank/vm-501-disk-0
    [ "$output" = "tank/base-9000-disk-0@__base__" ]
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

# --- Strict stubbing ------------------------------------------------------

@test "an unmatched call fails loudly instead of succeeding silently" {
    run pvesm list local-zfs
    [ "$status" -eq 97 ]
    [[ "$output" == *"no rule matches"* ]]
    [[ "$output" == *"pvesm list local-zfs"* ]]
}

@test "stub_lenient opts out for calls that do not matter" {
    stub_lenient

    run pvesm list local-zfs
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "destructive verbs need an explicit rule even when lenient" {
    stub_lenient

    for destructive in "qm destroy 501 --purge" "qm stop 501" \
                       "pvesm free local-zfs:vm-501-disk-0" \
                       "zfs destroy tank/vm-501-disk-0"; do
        run $destructive
        [ "$status" -eq 97 ]
        [[ "$output" == *"destructive calls need an explicit rule"* ]]
    done
}

@test "a destructive call with a rule behaves like any other" {
    stub_status qm 'destroy 501 --purge' 0

    run qm destroy 501 --purge
    [ "$status" -eq 0 ]
}

# --- Inspecting calls -----------------------------------------------------

@test "calls are recorded in order and can be asserted on" {
    stub_out qm 'clone *' < /dev/null
    stub_out qm 'start *' < /dev/null

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

# --- Isolation ------------------------------------------------------------

@test "every known host path constant is sandboxed" {
    load_lib

    local name
    for name in "${HARNESS_SANDBOXED_CONSTANTS[@]}"; do
        [[ -n "${!name:-}" ]] || {
            printf 'constant %s is empty after load_lib\n' "$name" >&2
            return 1
        }
        [[ "${!name}" == "$STUB_DIR"/* ]] || {
            printf 'constant %s escaped the sandbox: %s\n' "$name" "${!name}" >&2
            return 1
        }
    done
}

@test "a host path a later commit adds is sandboxed by value, not by name" {
    load_lib

    # Stands in for a constant this harness has never heard of, including one
    # derived from another constant at source time.
    GENERATIONS_DIR="/var/lib/github-runners/generations"
    sandbox_host_paths

    [[ "$GENERATIONS_DIR" == "$STUB_DIR"/* ]]
    [ -d "$GENERATIONS_DIR" ]
}

@test "the sandbox fails loudly if a constant it moves is renamed away" {
    load_lib
    HARNESS_SANDBOXED_CONSTANTS+=(NOT_A_REAL_CONSTANT)

    run sandbox_host_paths
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT_A_REAL_CONSTANT"* ]]
}

@test "sourcing a lib script keeps the sandbox in force" {
    load_lib
    write_infra_config

    # list.sh sources $CONFIG_FILE at source time. If its own `source
    # common.sh` had reset the sandbox, this would read the host's real
    # /etc/github-runners.conf — absent here — and TEMPLATE_ID would be empty.
    stub_lenient
    load_lib list.sh

    [[ "$CONFIG_FILE" == "$STUB_DIR"/* ]]
    [ "$TEMPLATE_ID" = "9000" ]
}

@test "org config lands in the sandbox" {
    load_lib

    write_org_config acme
    run list_orgs
    [ "$output" = "acme" ]
}
