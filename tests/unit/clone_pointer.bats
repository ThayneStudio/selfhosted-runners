#!/usr/bin/env bats
# clone_runner re-reads TEMPLATE_ID after the shared pool lock, honors the
# promotion pause file (return 3, not clone.failed), and tags from the cloned
# VMID's generation record.
#
# write_infra_config still defaults MIN_VMID=500, which overlaps the
# generation band, so tests set 9001.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    # clone_runner renders each VM's cloud-init snippet from the installed
    # runner-user-data.yaml, so point INSTALL_DIR at the repo copy. Must precede
    # load_lib: common.sh only defaults INSTALL_DIR when the caller sets nothing.
    INSTALL_DIR="$REPO_ROOT"
    load_lib generations.sh
    MIN_VMID=9001
    TEMPLATE_ID=9000
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    VLAN_TAG="${VLAN_TAG:-}"
    DNS_SERVERS="${DNS_SERVERS:-}"
    # Skip the ~130s pause wait unless a test is proving the retry itself.
    CLONE_PAUSE_RETRY_MAX_SECONDS=0
    # clone_runner mints a single-use JIT config on the host before cloning and
    # refuses to run without the org config loaded. Give it both; the mint call
    # itself is not what these tests are about, so stand in at that seam.
    write_org_config acme ghp_test acme-org
    load_org_config acme
    fetch_jit_config() { printf 'AAAAjitconfigAAAA'; }
    stub_clone_success
}

stub_clone_success() {
    stub_out qm 'clone *' < /dev/null
    stub_out qm 'config *' < /dev/null
    stub_out qm 'set *' < /dev/null
    stub_out qm 'start *' < /dev/null
}

# Point the on-disk pointer at 8900 while leaving the in-shell TEMPLATE_ID
# at 9000, so a missed re-read clones the stale value.
write_pointer() {
    local vmid="$1"
    {
        printf 'NETWORK_BRIDGE="%s"\n' "$NETWORK_BRIDGE"
        printf 'VM_STORAGE="%s"\n' "$VM_STORAGE"
        printf 'TEMPLATE_ID="%s"\n' "$vmid"
        printf 'MIN_VMID="%s"\n' "$MIN_VMID"
    } > "$CONFIG_FILE"
}

@test "clone_runner re-reads TEMPLATE_ID after the shared lock" {
    [ "$TEMPLATE_ID" = "9000" ]
    write_pointer 8900

    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]
    assert_called qm 'clone 8900 *'
    refute_called qm 'clone 9000 *'
}

@test "clone_runner tags the clone gen-N from the cloned VMID's record" {
    gen_store_init
    gen_create 8900 \
        GEN_ID=5 \
        GEN_STATE=superseded \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0
    gen_create 8901 \
        GEN_ID=9 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=newdigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0

    TEMPLATE_ID=8901
    write_pointer 8900

    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]
    assert_called qm 'clone 8900 *'
    assert_called qm 'set 9001 --tags runner,gen-5'
    refute_called qm 'set * --tags runner,gen-9'
}

# The security invariant this whole clone path exists to hold: the guest gets a
# single-use JIT config and never the org PAT.
@test "clone_runner points the clone at a per-VM snippet holding the JIT config, not the PAT" {
    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]

    snippet="$SNIPPETS_DIR/runner-9001-user-acme.yaml"
    [ -f "$snippet" ]
    grep -q 'JIT_CONFIG="AAAAjitconfigAAAA"' "$snippet"
    grep -q 'GITHUB_ORG="acme-org"' "$snippet"
    ! grep -q 'ghp_test' "$snippet"
    ! grep -q '{{' "$snippet"
    assert_called qm 'set 9001 --cicustom user=local:snippets/runner-9001-user-acme.yaml,meta=local:snippets/runner-9001-meta.yaml'
    refute_called qm 'set * --cicustom user=local:snippets/runner-user-data-*'
}

@test "clone_runner returns 3 without cloning when PROMOTION_PAUSE_FILE remains" {
    mkdir -p "$(dirname "$PROMOTION_PAUSE_FILE")"
    exec 211>"$PROMOTION_PAUSE_FILE"
    flock -n 211

    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 3 ]
    refute_called qm 'clone *'
    refute_called qm 'set *'
    refute_called qm 'start *'
    exec 211>&- 2>/dev/null || true
}

@test "acquire_clone_slot returns 3 when promotion pause file exists" {
    : > "$PROMOTION_PAUSE_FILE"
    run acquire_clone_slot
    [ "$status" -eq 3 ]
}

@test "clone_runner returns 3 when acquire_clone_slot sees a pause" {
    acquire_clone_slot() { return 3; }
    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 3 ]
    refute_called qm 'clone *'
    refute_called qm 'start *'
}

@test "clone_runner starts when the cloned VMID has no generation record" {
    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]
    assert_called qm 'start *'
    refute_called qm 'set * --tags *'
}

@test "clone_runner clones the re-read TEMPLATE_ID when the pause file clears mid-wait" {
    : > "$PROMOTION_PAUSE_FILE"
    [ "$TEMPLATE_ID" = "9000" ]
    write_pointer 9000
    CLONE_PAUSE_RETRY_MAX_SECONDS=4
    sleep() {
        rm -f "$PROMOTION_PAUSE_FILE"
        write_pointer 8900
    }

    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]
    assert_called qm 'clone 8900 *'
    refute_called qm 'clone 9000 *'
}

@test "reclone does not notify clone.failed when clone_runner returns 3" {
    notify() { printf '%s\n' "$*" >> "$STUB_DIR/notify.log"; }
    load_org_config() { :; }
    clone_runner() { return 3; }
    NAME="runner-1"
    ORG="acme"
    VMID="9001"
    local block
    block=$(awk '/^# Clone replacement/,0' "$REPO_ROOT/lib/reclone.sh")
    [ -n "$block" ]

    run --separate-stderr eval "set -euo pipefail
$block"
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/notify.log" ]
    [[ "$stderr" == *"promotion in progress, will retry"* ]]
}

@test "reclone notifies clone.failed when clone_runner returns 1" {
    notify() { printf '%s\n' "$*" >> "$STUB_DIR/notify.log"; }
    load_org_config() { :; }
    clone_runner() { return 1; }
    NAME="runner-1"
    ORG="acme"
    VMID="9001"
    local block
    block=$(awk '/^# Clone replacement/,0' "$REPO_ROOT/lib/reclone.sh")
    [ -n "$block" ]

    run --separate-stderr eval "set -euo pipefail
$block"
    [ "$status" -eq 1 ]
    grep -q 'error clone.failed' "$STUB_DIR/notify.log"
}

@test "watch does not record a failed slot when clone_runner returns 3" {
    clone_runner() { return 3; }
    slot="runner-1"
    org="acme"
    FAILED_SLOTS="$STUB_DIR/watch-failed"
    rm -f "$FAILED_SLOTS"
    local block
    block=$(awk '
        /clone_rc=0/ { p=1 }
        p { print }
        p && /^        fi$/ { exit }
    ' "$REPO_ROOT/lib/watch.sh")
    [ -n "$block" ]
    [[ "$block" == *"clone_rc"* ]]

    run --separate-stderr eval "set -euo pipefail
$block"
    [ "$status" -eq 0 ]
    [ ! -s "$FAILED_SLOTS" ]
    [[ "$stderr" == *"promotion in progress, will retry"* ]]
}

@test "clone_runner fails closed when qm set --tags fails for a known generation" {
    gen_store_init
    gen_create 9000 \
        GEN_ID=7 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=abc \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0

    stub_out qm 'config *' <<'EOF'
name: runner-acme-1
EOF
    stub_status qm 'set * --tags *' 1
    stub_out qm 'destroy *' < /dev/null
    stub_out pvesm 'list *' <<'EOF'
Volid Format
EOF

    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 1 ]
    refute_called qm 'start *'
    assert_called qm 'destroy *'
}

@test "create.sh treats clone_runner rc=3 as retry not Clone failed" {
    grep -A20 'clone_runner' "$REPO_ROOT/lib/create.sh" | grep -q 'clone_rc'
    grep -A20 'clone_runner' "$REPO_ROOT/lib/create.sh" | grep -q -- '-eq 3'
    grep -A20 'clone_runner' "$REPO_ROOT/lib/create.sh" | grep -q 'not creating'
    grep -A20 'clone_runner' "$REPO_ROOT/lib/create.sh" | grep -q 'exit 3'
    ! grep -A25 'clone_runner' "$REPO_ROOT/lib/create.sh" | grep -q 'clone.failed'
}

@test "watch records a failed slot when clone_runner returns 1" {
    clone_runner() { return 1; }
    slot="runner-1"
    org="acme"
    FAILED_SLOTS="$STUB_DIR/watch-failed"
    rm -f "$FAILED_SLOTS"
    local block
    block=$(awk '
        /clone_rc=0/ { p=1 }
        p { print }
        p && /^        fi$/ { exit }
    ' "$REPO_ROOT/lib/watch.sh")
    [ -n "$block" ]

    run --separate-stderr eval "set -euo pipefail
$block"
    [ "$status" -eq 0 ]
    [ -s "$FAILED_SLOTS" ]
    grep -qx 'runner-1' "$FAILED_SLOTS"
}
