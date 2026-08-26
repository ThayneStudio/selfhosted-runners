#!/usr/bin/env bats
# clone_runner re-reads TEMPLATE_ID after the shared pool lock, honors the
# promotion pause file, and tags from the cloned VMID's generation record.
#
# write_infra_config still defaults MIN_VMID=500, which overlaps the
# generation band, so tests set 9001.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib generations.sh
    MIN_VMID=9001
    TEMPLATE_ID=9000
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    VLAN_TAG="${VLAN_TAG:-}"
    DNS_SERVERS="${DNS_SERVERS:-}"
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

@test "clone_runner returns 1 without cloning when PROMOTION_PAUSE_FILE exists" {
    : > "$PROMOTION_PAUSE_FILE"

    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 1 ]
    refute_called qm 'clone *'
    refute_called qm 'set *'
    refute_called qm 'start *'
}
