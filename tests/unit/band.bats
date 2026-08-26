#!/usr/bin/env bats
# Generation VMID band vs MIN_VMID: overlap and MIN_VMID=0 are hard errors.

load test_helper

setup() {
    load_lib
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_BAND_MIN=8900
    TEMPLATE_BAND_MAX=8999
}

@test "current deployment band 8900-8999 with MIN_VMID=9001 validates" {
    run validate_generation_band
    [ "$status" -eq 0 ]
}

@test "band overlapping MIN_VMID is a hard error naming both values" {
    MIN_VMID=8900
    run validate_generation_band
    [ "$status" -eq 1 ]
    [[ "$output" == *8900* ]]
    [[ "$output" == *TEMPLATE_BAND* || "$output" == *band* ]]
}

@test "MIN_VMID=0 is rejected with suggested TEMPLATE_BAND_MAX+1" {
    MIN_VMID=0
    TEMPLATE_BAND_MAX=8999
    run validate_generation_band
    [ "$status" -eq 1 ]
    [[ "$output" == *9000* ]]
}

@test "load_infra_config rejects MIN_VMID=0" {
    MIN_VMID=0
    printf 'NETWORK_BRIDGE="vmbr0"\nVM_STORAGE="local-zfs"\nTEMPLATE_ID="9000"\nMIN_VMID="0"\n' > "$CONFIG_FILE"
    run load_infra_config
    [ "$status" -ne 0 ]
}

@test "setup wizard refuses MIN_VMID=0 with TEMPLATE_BAND_MAX+1 before writing config" {
    # Operator typing 0 must log_error naming the suggested floor and exit 1
    # after the read, before printf MIN_VMID= into CONFIG_FILE. "0 = auto" is
    # no longer offered.
    ! grep -q '0 = auto' "$REPO_ROOT/lib/setup.sh"
    awk '
        /read -rp .*Minimum VM ID/ { r = NR }
        /MIN_VMID" -eq 0/ { z = NR }
        /TEMPLATE_BAND_MAX/ { if (z && !t) t = NR }
        /printf '\''MIN_VMID=%q/ { w = NR }
        END {
            if (!r || !z || !t || !w) exit 1
            if (!(r < z && z <= t && t < w)) exit 1
        }
    ' "$REPO_ROOT/lib/setup.sh"
}
