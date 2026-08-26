#!/usr/bin/env bats
# Generation VMID band vs MIN_VMID: overlap and MIN_VMID=0 are hard errors.

load test_helper
bats_require_minimum_version 1.5.0

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
        /validate_generation_band/ { z = NR }
        /printf '\''MIN_VMID=%q/ { w = NR }
        END {
            if (!r || !z || !w) exit 1
            if (!(r < z && z < w)) exit 1
        }
    ' "$REPO_ROOT/lib/setup.sh"
}

@test "non-numeric MIN_VMID is a hard error" {
    MIN_VMID=abc
    TEMPLATE_BAND_MIN=8900
    TEMPLATE_BAND_MAX=8999
    run validate_generation_band
    [ "$status" -eq 1 ]
    [[ "$output" == *"MIN_VMID"* ]]
    [[ "$output" == *"abc"* ]]
}

@test "install.sh validates the generation band after sourcing conf and before enabling maintain.timer" {
    awk '
        /source \/etc\/github-runners.conf/ { src = NR }
        /apply_generation_defaults/ { if (src && !d) d = NR }
        /validate_generation_band/ { if (d && !v) v = NR }
        /enable --now github-runner-maintain.timer/ { if (!e) e = NR }
        /Install aborted/ { abort = NR }
        /exit 1/ { if (v && !x) x = NR }
        END {
            if (!src || !d || !v || !e || !abort || !x) exit 1
            if (!(src < d && d <= v && v < x && x < e && abort < e)) exit 1
        }
    ' "$REPO_ROOT/install.sh"
}

@test "install.sh existing-conf upgrade exits 1 on MIN_VMID=0 without enabling maintain.timer" {
    local conf="$STUB_DIR/github-runners.conf"
    printf 'NETWORK_BRIDGE="vmbr0"\nVM_STORAGE="local-zfs"\nTEMPLATE_ID="9000"\nMIN_VMID="0"\n' > "$conf"

    local snippet="$STUB_DIR/install-upgrade-gate.sh"
    awk -v conf="$conf" '
        /source \/etc\/github-runners.conf/ { p=1 }
        p {
            gsub(/\/etc\/github-runners.conf/, conf)
            print
        }
        /Install aborted/ { aborted=1 }
        aborted && /^    fi$/ { exit }
    ' "$REPO_ROOT/install.sh" > "$snippet"
    grep -q 'validate_generation_band' "$snippet"
    grep -q 'exit 1' "$snippet"
    grep -q 'fi' "$snippet"
    ! grep -q 'enable --now github-runner-maintain.timer' "$snippet"

    run --separate-stderr bash -c '
        set -euo pipefail
        source "$1/lib/common.sh"
        source "$2"
    ' _ "$REPO_ROOT" "$snippet"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"MIN_VMID"* ]]
    [[ "$stderr" == *"9000"* ]]
    [[ "$stderr" == *"github-runner-maintain.timer was not enabled"* ]]
}
