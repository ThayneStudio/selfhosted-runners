# Shared bats harness for tests/unit.
#
# Usage from a test file in tests/unit:
#
#     load test_helper
#
#     setup() {
#         load_lib            # sources lib/common.sh
#     }
#
#     @test "get_vm_org reads the org out of cicustom" {
#         stub_out qm 'config 501' <<'EOF'
#     name: runner-a
#     cicustom: user=local:snippets/runner-user-data-acme.yaml
#     EOF
#         run get_vm_org 501
#         [ "$output" = "acme" ]
#         assert_called qm 'config 501'
#     }
#
# What loading this file does, once per test:
#
#   * Prepends tests/stubs/bin to PATH. qm/pvesm/pvesh/zfs there are fakes; see
#     tests/stubs/bin/_stub. Nothing in a unit test may reach a real Proxmox.
#   * Appends tests/compat/bin to PATH, which fills in GNU tools missing on
#     BSD userland (macOS). Real coreutils always win.
#   * Creates a private $STUB_DIR for this test's stub rules and call log.
#
# Adding a stub for another command (flock, curl, systemctl, ...) is one
# symlink: `ln -s _stub tests/stubs/bin/<name>`. The dispatcher keys off its
# own argv[0], so no other change is needed.

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_HARNESS_DIR/.." && pwd)"
export REPO_ROOT

# Stubs first so they shadow anything real; compat last so it only fills gaps.
if [[ ":$PATH:" != *":$_HARNESS_DIR/stubs/bin:"* ]]; then
    PATH="$_HARNESS_DIR/stubs/bin:$PATH:$_HARNESS_DIR/compat/bin"
    export PATH
fi

# bats sources the test file once per test, so this is per-test even where
# BATS_TEST_TMPDIR is not yet set. Everything lands under a tmpdir bats reaps
# at the end of the run.
STUB_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}}/runner-stubs.XXXXXX")"
export STUB_DIR

# --- Loading code under test ---------------------------------------------

# Source a library file, then repoint its host paths into the test sandbox.
# Defaults to lib/common.sh. Call from setup().
load_lib() {
    local rel="${1:-common.sh}"
    [[ "$rel" == */* ]] || rel="lib/$rel"
    # shellcheck source=/dev/null  # path is chosen by the caller
    source "$REPO_ROOT/$rel"
    sandbox_host_paths
}

# Redirect the /etc, /run and /var/lib constants at a throwaway directory so a
# test can never read the developer's real config or take a real lock. Runs
# automatically from load_lib; call it again after sourcing anything that
# re-defines these.
# shellcheck disable=SC2034  # every assignment here is consumed by lib/*.sh
sandbox_host_paths() {
    HOST_SANDBOX="$STUB_DIR/host"
    mkdir -p "$HOST_SANDBOX/etc/github-runners.d" \
             "$HOST_SANDBOX/run/lock" \
             "$HOST_SANDBOX/snippets"

    CONFIG_FILE="$HOST_SANDBOX/etc/github-runners.conf"
    ORG_CONFIG_DIR="$HOST_SANDBOX/etc/github-runners.d"
    SNIPPETS_DIR="$HOST_SANDBOX/snippets"
    POOL_DRAIN_FILE="$HOST_SANDBOX/run/lock/github-runner-drain"
    POOL_ACTIVITY_LOCK_FILE="$HOST_SANDBOX/run/lock/github-runner-pool.lock"
    VMID_LOCK_FILE="$HOST_SANDBOX/run/lock/runner-vmid.lock"
    VMID_RESERVATION_LOCK_PREFIX="$HOST_SANDBOX/run/lock/runner-vmid-reserve"
    CLONE_SLOT_LOCK_PREFIX="$HOST_SANDBOX/run/lock/runner-clone-slot"
}

# Write an org config into the sandbox, as `runner add-org` would.
write_org_config() {
    local org="$1" pat="${2:-ghp_test}" github_org="${3:-$1}"
    printf 'GITHUB_ORG="%s"\nGITHUB_PAT="%s"\n' "$github_org" "$pat" \
        > "$ORG_CONFIG_DIR/${org}.conf"
}

# --- Programming the stubs -----------------------------------------------

# stub_out <cmd> <arg-pattern> [exit-status]
# Registers the stdout (read from this function's stdin) that <cmd> produces
# when its arguments glob-match <arg-pattern>. Use '*' for "any arguments".
# The most recently registered matching rule wins.
stub_out() {
    local cmd="$1" pattern="$2" rc="${3:-0}"
    local rules="$STUB_DIR/$cmd/rules" seq
    mkdir -p "$rules"
    seq=$(printf '%03d' "$(find "$rules" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')")
    mkdir -p "$rules/$seq"
    printf '%s' "$pattern" > "$rules/$seq/pattern"
    printf '%s' "$rc" > "$rules/$seq/rc"
    cat > "$rules/$seq/out"
}

# stub_status <cmd> <arg-pattern> <exit-status>
# Same as stub_out with no stdout — for "this call fails".
stub_status() {
    stub_out "$1" "$2" "$3" < /dev/null
}

# --- Inspecting what was called ------------------------------------------

# Every invocation of a stub, one "$*" per line, in order.
stub_calls() {
    local log="$STUB_DIR/$1/calls"
    [[ -f "$log" ]] && cat "$log"
    return 0
}

# Number of invocations of <cmd>, optionally only those glob-matching <pattern>.
call_count() {
    local cmd="$1" pattern="${2:-*}" line count=0
    while IFS= read -r line; do
        # shellcheck disable=SC2053  # glob match, see tests/stubs/bin/_stub
        [[ $line == $pattern ]] && count=$((count + 1))
    done < <(stub_calls "$cmd")
    printf '%s\n' "$count"
}

assert_called() {
    local cmd="$1" pattern="$2"
    if [[ "$(call_count "$cmd" "$pattern")" -eq 0 ]]; then
        printf 'expected %s to be called with: %s\ncalls were:\n%s\n' \
            "$cmd" "$pattern" "$(stub_calls "$cmd")" >&2
        return 1
    fi
}

refute_called() {
    local cmd="$1" pattern="${2:-*}"
    if [[ "$(call_count "$cmd" "$pattern")" -ne 0 ]]; then
        printf 'expected %s NOT to be called with: %s\ncalls were:\n%s\n' \
            "$cmd" "$pattern" "$(stub_calls "$cmd")" >&2
        return 1
    fi
}
