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
#     cicustom: user=local:snippets/runner-user-data-acme.yaml
#     EOF
#         run get_vm_org 501
#         [ "$output" = "acme" ]
#         assert_called qm 'config 501'
#     }
#
# What loading this file does, once per test:
#
#   * Prepends tests/stubs/bin to PATH, so qm/pvesm/pvesh/zfs/curl/jq/logger
#     resolve to fakes. See tests/stubs/bin/_stub.
#   * Appends tests/compat/bin to PATH, which fills in GNU tools missing on
#     BSD userland (macOS). Real coreutils always win.
#   * Creates a private $STUB_DIR for this test's stub rules and call log.
#   * Turns on strict stubbing: a call no rule matches fails the test rather
#     than succeeding silently.
#
# Adding a fake for another command is one symlink:
#
#     ln -s _stub tests/stubs/bin/systemctl
#
# Do not fake flock. reserve_vmid and the clone slot allocator are contention
# loops; a flock that always succeeds would validate them against semantics
# that cannot occur on a real host. The sandbox below points every lock path
# at a temp directory, so real flock calls are already harmless.

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

# Host paths lib/common.sh defines and the sandbox moves. Each one must still
# exist after load_lib: a rename upstream fails the suite loudly instead of
# quietly leaving a test pointed at the real /etc or /run.
HARNESS_SANDBOXED_CONSTANTS=(
    CONFIG_FILE
    ORG_CONFIG_DIR
    SNIPPETS_DIR
    PVE_NODES_DIR
    POOL_DRAIN_FILE
    POOL_ACTIVITY_LOCK_FILE
    VMID_LOCK_FILE
    VMID_RESERVATION_LOCK_PREFIX
    CLONE_SLOT_LOCK_PREFIX
    RUNNER_SLOT_LOCK_PREFIX
    RECLONE_STATE_PREFIX
    SYSTEMD_UNIT_DIR
    LOGROTATE_DIR
)

# --- Loading code under test ---------------------------------------------

# Source a library file, then repoint its host paths into the test sandbox.
# Defaults to lib/common.sh. Call from setup().
load_lib() {
    local rel="${1:-common.sh}"
    [[ "$rel" == */* ]] || rel="lib/$rel"

    # Order matters. Every lib script except common.sh runs top-level code at
    # source time — reading $CONFIG_FILE, taking locks — so the sandbox has to
    # be in force before that code runs, not after. common.sh is idempotent
    # (RUNNER_COMMON_LOADED), which is what stops the script's own
    # `source common.sh` from resetting these paths back to /etc and /run.
    # shellcheck source=../lib/common.sh
    source "$REPO_ROOT/lib/common.sh"
    sandbox_host_paths

    if [[ "$rel" != "lib/common.sh" ]]; then
        # shellcheck source=/dev/null  # path is chosen by the caller
        source "$REPO_ROOT/$rel"
        # Again, for constants the script defines itself.
        sandbox_host_paths
    fi
}

# Rewrite every host path constant to sit under a throwaway directory, so a
# test cannot read the developer's config or take a lock a real reclone.sh
# would then skip on. Runs automatically from load_lib.
#
# This covers shell constants only. A path written as a literal inside a
# function body is invisible here — keep host paths in the constants block at
# the top of lib/common.sh. Demonstrated by "every known host path constant is
# sandboxed" in tests/unit/harness_smoke.bats.
sandbox_host_paths() {
    HOST_SANDBOX="$STUB_DIR/host"
    mkdir -p "$HOST_SANDBOX"

    local name decl
    local -a missing=() frozen=()
    for name in "${HARNESS_SANDBOXED_CONSTANTS[@]}"; do
        decl=$(declare -p "$name" 2>/dev/null) || { missing+=("$name"); continue; }
        # A readonly constant cannot be rewritten, and the sweep below skips
        # readonly names rather than dying. Catch that here instead of letting
        # it read as "sandboxed".
        [[ "$decl" =~ ^declare\ -[a-zA-Z]*r ]] && frozen+=("$name")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf 'harness: lib/common.sh no longer defines: %s\n' "${missing[*]}" >&2
        printf 'harness: update HARNESS_SANDBOXED_CONSTANTS in tests/test_helper.bash\n' >&2
        return 1
    fi
    if [[ ${#frozen[@]} -gt 0 ]]; then
        printf 'harness: cannot sandbox readonly constant(s): %s\n' "${frozen[*]}" >&2
        return 1
    fi

    # Sweeping by value rather than by name covers constants added by later
    # work, including ones derived from another constant at source time.
    while IFS= read -r name; do
        _sandbox_one_path "$name"
    done < <(compgen -v | grep -E '^[A-Z][A-Z0-9_]*$')
}

_sandbox_one_path() {
    local name="$1" decl value
    decl=$(declare -p "$name" 2>/dev/null) || return 0
    # Exported means it came from the environment (PATH, HOME, BATS_*), not
    # from the library. Arrays hold no single path, and readonly cannot be
    # rewritten — sandbox_host_paths rejects a readonly one it knows about.
    [[ "$decl" =~ ^declare\ -[a-zA-Z]*[xaAr] ]] && return 0

    value="${!name}"
    [[ "$value" == "$HOST_SANDBOX"* ]] && return 0
    case "$value" in
        /etc/*|/run/*|/var/lib/*|/var/log/*|/var/cache/*|/var/spool/*) ;;
        *) return 0 ;;
    esac

    printf -v "$name" '%s' "$HOST_SANDBOX$value"
    mkdir -p "$(dirname "$HOST_SANDBOX$value")"
    [[ "$name" == *_DIR ]] && mkdir -p "$HOST_SANDBOX$value"
    return 0
}

# Write the infra config load_infra_config requires, and set the same values in
# this shell. Without it, anything reading $VM_STORAGE or $TEMPLATE_ID dies on
# `set -u` instead of testing what you meant to test. Override by assigning the
# variables before the call.
write_infra_config() {
    NETWORK_BRIDGE="${NETWORK_BRIDGE:-vmbr0}"
    VM_STORAGE="${VM_STORAGE:-local-zfs}"
    TEMPLATE_ID="${TEMPLATE_ID:-9000}"
    MIN_VMID="${MIN_VMID:-500}"
    {
        printf 'NETWORK_BRIDGE="%s"\n' "$NETWORK_BRIDGE"
        printf 'VM_STORAGE="%s"\n' "$VM_STORAGE"
        printf 'TEMPLATE_ID="%s"\n' "$TEMPLATE_ID"
        printf 'MIN_VMID="%s"\n' "$MIN_VMID"
    } > "$CONFIG_FILE"
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

# Default. An unmatched call fails, printing what was called and the call log.
stub_strict() {
    STUB_STRICT=1
    export STUB_STRICT
}

# Opt out for a test where the calls genuinely do not matter. Destructive verbs
# (qm destroy/stop, pvesm free, zfs destroy) still require an explicit rule —
# see tests/stubs/bin/_stub.
stub_lenient() {
    STUB_STRICT=0
    export STUB_STRICT
}

stub_strict

# Nothing asserts on syslog output, and reclone.sh logs on most paths.
# Pre-registered so strict mode does not turn a log line into a failure; a test
# that cares can register its own rule, which wins, and refute_called still
# works.
stub_out logger '*' < /dev/null

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
