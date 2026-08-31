#!/usr/bin/env bats
# Safe old-generation reporting and forced rollover.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib rollover.sh
    TEMPLATE_ID=8901
    MIN_VMID=9000
    write_infra_config
    TEMPLATE_ID=8901
    apply_generation_defaults
    gen_store_init
    gen_create 8900 GEN_ID=1 GEN_STATE=superseded GEN_RUNNER_VERSION=2.335.0
    gen_create 8901 GEN_ID=2 GEN_STATE=active GEN_RUNNER_VERSION=2.336.0
    ROLLOVER_DESTROY_DELAY_SECONDS=0
}

@test "lib/rollover.sh is syntactically valid and runner dispatches it" {
    bash -n "$REPO_ROOT/lib/rollover.sh"
    grep -Eq '^[[:space:]]*rollover\)' "$REPO_ROOT/runner"
}

@test "report-only lists old clones and changes nothing" {
    rollover_collect() { printf 'old-a|9001|1|acme|running|2h3m\n'; }
    rollover_busy() { printf 'false\n'; }
    rollover_destroy_one() { printf 'destroy called\n' >> "$STUB_DIR/actions"; }

    run rollover_main
    [ "$status" -eq 0 ]
    [[ "$output" == *old-a* ]]
    [[ "$output" == *gen-1* ]]
    [[ "$output" == *acme* ]]
    [[ "$output" == *2h3m* ]]
    [[ "$output" == *false* ]]
    [ ! -e "$STUB_DIR/actions" ]
}

@test "inventory selects managed old-generation clones and excludes active and foreign VMs" {
    qm_stub() {
        case "$1 ${2:-}" in
            "list ")
                printf 'VMID NAME STATUS\n9001 old-a running\n9002 new-a running\n9003 foreign running\n8902 old-template stopped\n'
                ;;
            "config 9001") printf 'name: old-a\ntags: runner;gen-1\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            "config 9002") printf 'name: new-a\ntags: runner;gen-2\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            "config 9003") printf 'name: foreign\ntags: gen-1\n' ;;
            "config 8902") printf 'name: old-template\ntemplate: 1\ntags: runner;gen-1\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    rollover_age() { printf '3h4m\n'; }

    run rollover_collect 2
    [ "$status" -eq 0 ]
    [ "$output" = 'old-a|9001|1|acme|running|3h4m' ]
}

@test "report shows unknown when GitHub state cannot be verified" {
    rollover_collect() { printf 'old-a|9001|1|acme|running|2h3m\n'; }
    rollover_busy() { printf 'unknown\n'; return 1; }

    run rollover_main
    [ "$status" -eq 0 ]
    [[ "$output" == *unknown* ]]
}

@test "GitHub lookup returns the authoritative id and boolean busy state" {
    write_org_config acme ghp_test acme-org
    curl() { printf '{"total_count":1,"runners":[{"id":42,"name":"old-a","busy":false,"status":"online"}]}\n'; }
    jq() { /usr/bin/jq "$@"; }

    run github_runner_lookup acme old-a
    [ "$status" -eq 0 ]
    [ "$output" = $'42\tfalse' ]
}

@test "GitHub lookup fails closed for a missing runner or malformed busy state" {
    write_org_config acme ghp_test acme-org
    jq() { /usr/bin/jq "$@"; }
    curl() { printf '{"total_count":0,"runners":[]}\n'; }
    run github_runner_lookup acme old-a
    [ "$status" -ne 0 ]

    curl() { printf '{"total_count":1,"runners":[{"id":42,"name":"old-a","busy":"false","status":"online"}]}\n'; }
    run github_runner_lookup acme old-a
    [ "$status" -ne 0 ]
}

@test "GitHub lookup scans every page and rejects duplicate exact names" {
    write_org_config acme ghp_test acme-org
    jq() { /usr/bin/jq "$@"; }
    curl() {
        case "${*: -1}" in
            *page=1) printf '{"total_count":101,"runners":[{"id":7,"name":"other","busy":false,"status":"online"}]}\n' ;;
            *page=2) printf '{"total_count":101,"runners":[{"id":42,"name":"old-a","busy":false,"status":"offline"}]}\n' ;;
        esac
    }
    run github_runner_lookup_details acme old-a
    [ "$status" -eq 0 ]
    [ "$output" = $'42\tfalse\toffline' ]

    curl() {
        case "${*: -1}" in
            *page=1) printf '{"total_count":101,"runners":[{"id":41,"name":"old-a","busy":false,"status":"online"}]}\n' ;;
            *page=2) printf '{"total_count":101,"runners":[{"id":42,"name":"old-a","busy":false,"status":"offline"}]}\n' ;;
        esac
    }
    run github_runner_lookup_details acme old-a
    [ "$status" -ne 0 ]
}

@test "GitHub lookup fails closed when inventory changes between pages" {
    write_org_config acme ghp_test acme-org
    jq() { /usr/bin/jq "$@"; }
    curl() {
        case "${*: -1}" in
            *page=1) printf '{"total_count":101,"runners":[]}\n' ;;
            *page=2) printf '{"total_count":100,"runners":[{"id":42,"name":"old-a","busy":false,"status":"offline"}]}\n' ;;
        esac
    }
    run github_runner_lookup_details acme old-a
    [ "$status" -ne 0 ]
}

@test "force delegates every candidate to the safety re-check" {
    rollover_collect() {
        printf 'old-a|9001|1|acme|running|2h3m\n'
        printf 'old-b|9002|1|acme|running|1h2m\n'
    }
    rollover_busy() { printf 'false\n'; }
    rollover_destroy_one() { printf '%s\n' "$*" >> "$STUB_DIR/actions"; }

    run rollover_main --force
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$STUB_DIR/actions" | tr -d ' ')" -eq 2 ]
    grep -q '^old-a 9001 1 acme$' "$STUB_DIR/actions"
    grep -q '^old-b 9002 1 acme$' "$STUB_DIR/actions"
}

@test "force revisits the final capacity-deferred old runner after a destroy" {
    rollover_collect() {
        printf 'old-a|9001|1|acme|running|2h3m\n'
        printf 'old-b|9002|1|acme|running|1h2m\n'
    }
    rollover_busy() { printf 'false\n'; }
    rollover_destroy_one() {
        printf '%s\n' "$1" >> "$STUB_DIR/attempts"
        if [[ "$1" == old-b && "$(grep -c '^old-b$' "$STUB_DIR/attempts")" -eq 1 ]]; then return 3; fi
        return 0
    }
    ROLLOVER_REPLACEMENT_WAIT_SECONDS=0

    run rollover_main --force
    [ "$status" -eq 0 ]
    [ "$(grep -c '^old-b$' "$STUB_DIR/attempts")" -eq 2 ]
    [[ "$output" == *"destroyed 2"* ]]
}

@test "a quarantined residual also opens capacity for the final deferred runner" {
    rollover_collect() {
        printf 'old-a|9001|1|acme|running|2h3m\n'
        printf 'old-b|9002|1|acme|running|1h2m\n'
    }
    rollover_busy() { printf 'false\n'; }
    rollover_destroy_one() {
        printf '%s\n' "$1" >> "$STUB_DIR/attempts"
        [[ "$1" == old-a ]] && return 4
        [[ "$(grep -c '^old-b$' "$STUB_DIR/attempts")" -eq 1 ]] && return 3
        return 0
    }
    ROLLOVER_REPLACEMENT_WAIT_SECONDS=0

    run rollover_main --force
    [ "$status" -ne 0 ]
    [ "$(grep -c '^old-b$' "$STUB_DIR/attempts")" -eq 2 ]
    [[ "$output" == *"destroyed 1"* ]]
    [[ "$output" == *"failed 1"* ]]
}

@test "rollover refuses report and force while maintenance drain is active" {
    mkdir -p "$(dirname "$POOL_DRAIN_FILE")"
    : > "$POOL_DRAIN_FILE"
    rollover_collect() { printf 'old-a|9001|1|acme|running|2h3m\n'; }

    run --separate-stderr rollover_main
    [ "$status" -ne 0 ]
    [[ "$stderr" == *maintenance* ]]
    refute_called qm '*'
}

setup_destroy_candidate() {
    qm_stub() {
        case "$1 $2" in
            "config 9001")
                printf 'name: old-a\ntags: runner;gen-1\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n'
                ;;
            "status 9001") printf 'status: running\n' ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    rollover_serving_count() { printf '1\n'; }
    rollover_quiesce_guest() { printf 'quiesce %s\n' "$1" >> "$STUB_DIR/protocol"; }
    rollover_wait_offline_idle() { printf '42\n'; }
    rollover_resume_guest() { printf 'resume %s\n' "$1" >> "$STUB_DIR/protocol"; }
    rollover_destroy_vm() { printf 'destroy %s\n' "$1" >> "$STUB_DIR/actions"; }
    github_runner_deregister_id() { printf 'deregister %s %s\n' "$1" "$2" >> "$STUB_DIR/actions"; }
}

@test "force never destroys when the frozen guest contains a worker" {
    setup_destroy_candidate
    rollover_quiesce_guest() { return 2; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 2 ]
    [ ! -e "$STUB_DIR/actions" ]
    grep -q '^resume 9001$' "$STUB_DIR/protocol"
}

@test "force skips on GitHub API uncertainty" {
    setup_destroy_candidate
    rollover_wait_offline_idle() { return 1; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 2 ]
    [ ! -e "$STUB_DIR/actions" ]
}

@test "force defers without a verified online replacement for the org" {
    setup_destroy_candidate
    rollover_serving_count() { printf '0\n'; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 3 ]
    [ ! -e "$STUB_DIR/actions" ]
}

@test "capacity counts GitHub-online service, not merely running Proxmox VMs" {
    qm_stub() {
        case "$1 ${2:-}" in
            "list ") printf 'VMID NAME STATUS\n9001 old-a running\n9002 new-a running\n' ;;
            "config 9001") printf 'name: old-a\ntags: runner;gen-1\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            "config 9002") printf 'name: new-a\ntags: runner;gen-2\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    github_runner_lookup_details() {
        case "$2" in
            old-a) printf '41\tfalse\tonline\n' ;;
            new-a) printf '42\tfalse\toffline\n' ;;
        esac
    }

    run rollover_serving_count acme old-a
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
}

@test "force skips destruction if deregistration fails" {
    setup_destroy_candidate
    github_runner_deregister_id() { return 1; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 2 ]
    [ ! -e "$STUB_DIR/actions" ]
    grep -q '^resume 9001$' "$STUB_DIR/protocol"
}

@test "force rechecks replacement capacity after offline acknowledgement" {
    setup_destroy_candidate
    rollover_serving_count() {
        local count_file="$STUB_DIR/capacity-checks" count=0
        [[ -f "$count_file" ]] && count=$(cat "$count_file")
        count=$((count + 1)); printf '%s\n' "$count" > "$count_file"
        [[ "$count" -eq 1 ]] && printf '1\n' || printf '0\n'
    }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 2 ]
    [ ! -e "$STUB_DIR/actions" ]
    grep -q '^resume 9001$' "$STUB_DIR/protocol"
}

@test "force deregisters then destroys an idle old-generation runner" {
    setup_destroy_candidate

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$STUB_DIR/actions")" = "deregister acme 42" ]
    [ "$(sed -n '2p' "$STUB_DIR/actions")" = "destroy 9001" ]
    [ "$(sed -n '1p' "$STUB_DIR/protocol")" = "quiesce 9001" ]
}

@test "destroy failure quarantines a deregistered VM so its slot can refill" {
    setup_destroy_candidate
    rollover_destroy_vm() { return 1; }
    rollover_quarantine_vm() { printf 'quarantine %s %s\n' "$1" "$2" >> "$STUB_DIR/actions"; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 4 ]
    grep -q '^deregister acme 42$' "$STUB_DIR/actions"
    grep -q '^quarantine 9001 1$' "$STUB_DIR/actions"
}

@test "quarantine renames the residual before best-effort retagging" {
    qm_stub() { printf '%s\n' "$*" >> "$STUB_DIR/qm-actions"; }
    export -f qm_stub

    run rollover_quarantine_vm 9001 1
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$STUB_DIR/qm-actions")" = 'set 9001 --name retired-rollover-9001' ]
    [ "$(sed -n '2p' "$STUB_DIR/qm-actions")" = 'set 9001 --tags runner-retired,gen-1' ]
}

@test "quiescence protocol freezes the service cgroup before checking workers" {
    freeze_line=$(grep -n 'echo 1 >.*cgroup.freeze' "$REPO_ROOT/lib/rollover.sh" | head -1 | cut -d: -f1)
    worker_line=$(grep -n 'Runner.Worker' "$REPO_ROOT/lib/rollover.sh" | head -1 | cut -d: -f1)
    [ "$freeze_line" -lt "$worker_line" ]
    grep -q 'frozen 1' "$REPO_ROOT/lib/rollover.sh"
    grep -q 'rollover_wait_offline_idle' "$REPO_ROOT/lib/rollover.sh"
}

@test "force skips when VM identity changed before the busy re-check" {
    setup_destroy_candidate
    qm_stub() {
        case "$1 $2" in
            "config 9001") printf 'name: replacement\ntags: runner;gen-2\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 2 ]
    [ ! -e "$STUB_DIR/actions" ]
}
