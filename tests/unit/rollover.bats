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

# Every clone minted since the JIT refactor carries the per-VM snippet name
# instead of the legacy per-org one. If rollover_cfg_org only knew the legacy
# name, rollover would see an empty inventory and silently never roll anything.
@test "inventory recognises clones carrying the per-VM JIT snippet" {
    qm_stub() {
        case "$1 ${2:-}" in
            "list ")
                printf 'VMID NAME STATUS\n9001 old-a running\n9002 new-a running\n'
                ;;
            "config 9001") printf 'name: old-a\ntags: runner;gen-1\ncicustom: user=local:snippets/runner-9001-user-acme.yaml,meta=local:snippets/runner-9001-meta.yaml\n' ;;
            "config 9002") printf 'name: new-a\ntags: runner;gen-2\ncicustom: user=local:snippets/runner-9002-user-acme.yaml,meta=local:snippets/runner-9002-meta.yaml\n' ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    rollover_age() { printf '3h4m\n'; }

    run rollover_collect 2
    [ "$status" -eq 0 ]
    [ "$output" = 'old-a|9001|1|acme|running|3h4m' ]
}

@test "rollover_cfg_org reads both the per-VM JIT snippet and the legacy one" {
    run rollover_cfg_org 'name: old-a
cicustom: user=local:snippets/runner-9001-user-acme.yaml,meta=local:snippets/runner-9001-meta.yaml'
    [ "$status" -eq 0 ]
    [ "$output" = "acme" ]

    run rollover_cfg_org 'name: old-a
cicustom: user=local:snippets/runner-user-data-acme.yaml'
    [ "$status" -eq 0 ]
    [ "$output" = "acme" ]

    run rollover_cfg_org 'name: leftover
cicustom: user=local:snippets/some-other-user-data.yaml'
    [ "$status" -ne 0 ]
}

# The pending-rollover recovery path re-identifies a VM before destroying it.
# Failing to match the per-VM snippet name would strand every new-style clone
# in $ROLLOVER_PENDING_DIR forever.
@test "pending identity matches a VM carrying the per-VM JIT snippet" {
    stub_out qm 'config 9001' <<'EOF'
name: old-a
cicustom: user=local:snippets/runner-9001-user-acme.yaml,meta=local:snippets/runner-9001-meta.yaml
tags: runner;gen-1;rollover-abc123
EOF

    run rollover_pending_identity_matches 9001 old-a acme 1 abc123
    [ "$status" -eq 0 ]

    run rollover_pending_identity_matches 9001 old-a other-org 1 abc123
    [ "$status" -ne 0 ]
}

@test "pending identity still matches a VM carrying the legacy per-org snippet" {
    stub_out qm 'config 9001' <<'EOF'
name: old-a
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1;rollover-abc123
EOF

    run rollover_pending_identity_matches 9001 old-a acme 1 abc123
    [ "$status" -eq 0 ]
}

@test "pending identity fails closed for a VM with no runner snippet at all" {
    stub_out qm 'config 9001' <<'EOF'
name: old-a
tags: runner;gen-1;rollover-abc123
EOF

    run rollover_pending_identity_matches 9001 old-a acme 1 abc123
    [ "$status" -ne 0 ]
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

@test "a durable pending residual also opens capacity for the final deferred runner" {
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
            "set 9001") return 0 ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    rollover_serving_count() { printf '1\n'; }
    rollover_quiesce_guest() { ROLLOVER_FROZEN_CGROUP=/runner.slice/old-a; printf 'quiesce %s\n' "$1" >> "$STUB_DIR/protocol"; }
    rollover_wait_offline_idle() { printf '42\n'; }
    rollover_resume_guest() { printf 'resume %s\n' "$1" >> "$STUB_DIR/protocol"; }
    rollover_mark_identity() { ROLLOVER_IDENTITY_NONCE=test-nonce; ROLLOVER_ORIGINAL_TAGS='runner;gen-1'; }
    rollover_pending_identity_matches() { return 0; }
    rollover_destroy_vm() { printf 'destroy %s\n' "$1" >> "$STUB_DIR/actions"; }
    github_runner_deregister_id() { printf 'deregister %s %s\n' "$1" "$2" >> "$STUB_DIR/actions"; }
}

@test "force never destroys when the frozen guest contains a worker" {
    setup_destroy_candidate
    rollover_quiesce_guest() {
        cut -d '|' -f1 "$ROLLOVER_PENDING_DIR/9001.pending" > "$STUB_DIR/phase-at-invocation"
        ROLLOVER_QUIESCE_UNCHANGED=true
        return 2
    }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 2 ]
    [ ! -e "$STUB_DIR/actions" ]
    [ "$(cat "$STUB_DIR/phase-at-invocation")" = preparing ]
    ! grep -q '^resume 9001$' "$STUB_DIR/protocol"
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "force safely clears preparing state when Listener topology is ambiguous" {
    setup_destroy_candidate
    rollover_quiesce_guest() { ROLLOVER_QUIESCE_UNCHANGED=true; return 3; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 2 ]
    [ ! -e "$STUB_DIR/actions" ]
    ! grep -q '^resume 9001$' "$STUB_DIR/protocol"
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "BUSY state from one candidate cannot suppress thaw for the next candidate" {
    qm_stub() {
        case "$1 $2" in
            "config 9001") printf 'name: old-a\ntags: runner;gen-1\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            "config 9002") printf 'name: old-b\ntags: runner;gen-1\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            "status 9001"|"status 9002") printf 'status: running\n' ;;
            "set 9001"|"set 9002") return 0 ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    rollover_serving_count() { printf '1\n'; }
    rollover_mark_identity() {
        ROLLOVER_IDENTITY_NONCE="nonce-$1"
        ROLLOVER_ORIGINAL_TAGS='runner;gen-1'
    }
    rollover_pending_identity_matches() { return 0; }
    rollover_quiesce_guest() {
        if [[ "$1" == 9001 ]]; then
            ROLLOVER_QUIESCE_UNCHANGED=true
            return 2
        fi
        # Deliberately do not reset the flag here: candidate/arm isolation must.
        ROLLOVER_FROZEN_CGROUP=/runner-b
        return 0
    }
    rollover_wait_offline_idle() { return 1; }
    rollover_resume_guest() {
        printf 'resume %s %s\n' "$1" "$ROLLOVER_FROZEN_CGROUP" >> "$STUB_DIR/resumes"
    }
    sequential_candidates() {
        local rc
        rc=0; rollover_destroy_one old-a 9001 1 acme || rc=$?
        [[ "$rc" -eq 2 ]] || return 1
        rc=0; rollover_destroy_one old-b 9002 1 acme || rc=$?
        [[ "$rc" -eq 2 ]]
    }

    run sequential_candidates
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_DIR/resumes")" = 'resume 9002 /runner-b' ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9002.pending" ]
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
    write_org_config acme
    printf 'RUNNER_COUNT="2"\n' >> "$ORG_CONFIG_DIR/acme.conf"
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
    github_runners_snapshot() {
        printf 'old-a\t41\tfalse\tonline\n'
        printf 'new-a\t42\tfalse\toffline\n'
    }

    run rollover_serving_count acme old-a
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
}

@test "capacity uses one paginated org snapshot for multiple local runners" {
    qm_stub() {
        case "$1 ${2:-}" in
            "list ") printf 'VMID NAME STATUS\n9001 old-a running\n9002 new-a running\n9003 new-b running\n' ;;
            "config 9001") printf 'name: old-a\ntags: runner;gen-1\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            "config 9002") printf 'name: new-a\ntags: runner;gen-2\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            "config 9003") printf 'name: new-b\ntags: runner;gen-2\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    github_runners_snapshot() {
        echo call >> "$STUB_DIR/snapshots"
        printf 'new-a\t42\tfalse\tonline\nnew-b\t43\tfalse\tonline\n'
    }
    run rollover_serving_count acme old-a
    [ "$status" -eq 0 ]
    [ "$output" = 2 ]
    [ "$(wc -l < "$STUB_DIR/snapshots" | tr -d ' ')" -eq 1 ]
}

@test "singleton force refuses before mutation when no online peer exists" {
    setup_destroy_candidate
    write_org_config acme
    printf 'RUNNER_COUNT="1"\n' >> "$ORG_CONFIG_DIR/acme.conf"
    rollover_serving_count() { printf '0\n'; }
    rollover_mark_identity() { : > "$STUB_DIR/mutated"; }
    rollover_quiesce_guest() { : > "$STUB_DIR/mutated"; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 5 ]
    [ ! -e "$STUB_DIR/mutated" ]
    [ ! -e "$STUB_DIR/actions" ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
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

@test "destroy failure leaves durable committed recovery so its slot can refill" {
    setup_destroy_candidate
    rollover_destroy_vm() { return 1; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 4 ]
    grep -q '^deregister acme 42$' "$STUB_DIR/actions"
    [ -f "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "quiescence protocol freezes the Listener cgroup before checking workers" {
    freeze_line=$(grep -n 'echo 1 >.*cgroup.freeze' "$REPO_ROOT/lib/rollover.sh" | head -1 | cut -d: -f1)
    worker_line=$(grep -n 'Runner.Worker' "$REPO_ROOT/lib/rollover.sh" | head -1 | cut -d: -f1)
    [ "$freeze_line" -lt "$worker_line" ]
    grep -q 'frozen 1' "$REPO_ROOT/lib/rollover.sh"
    grep -q 'pgrep -x Runner.Listener' "$REPO_ROOT/lib/rollover.sh"
    ! grep -q 'actions.runner' "$REPO_ROOT/lib/rollover.sh"
    grep -q 'rollover_wait_offline_idle' "$REPO_ROOT/lib/rollover.sh"
}

@test "quiesce honors qm guest-exec JSON exitcode and acknowledgement" {
    jq() { /usr/bin/jq "$@"; }
    qm_stub() { printf '{"exitcode":1,"out-data":"FROZEN:/runner\\n"}\n'; }
    export -f qm_stub
    run rollover_quiesce_guest 9001
    [ "$status" -eq 1 ]

    qm_stub() { printf '{"exitcode":0,"out-data":"BUSY_UNFROZEN\\n"}\n'; }
    export -f qm_stub
    run rollover_quiesce_guest 9001
    [ "$status" -eq 2 ]

    qm_stub() { printf '{"exitcode":0,"out-data":"FROZEN:/runner\\n"}\n'; }
    export -f qm_stub
    run rollover_quiesce_guest 9001
    [ "$status" -eq 0 ]
}

@test "direct run.sh Listener cgroup is discovered frozen and persisted" {
    mkdir -p "$STUB_DIR/proc/123" "$STUB_DIR/cgroup/runner"
    printf '0::/runner\n' > "$STUB_DIR/proc/123/cgroup"
    printf '0\n' > "$STUB_DIR/cgroup/runner/cgroup.freeze"
    printf 'frozen 1\n' > "$STUB_DIR/cgroup/runner/cgroup.events"
    pgrep() {
        [[ "$2" == Runner.Listener ]] && { printf '123\n'; return 0; }
        [[ "$2" == Runner.Worker ]] && return 1
        return 1
    }
    export -f pgrep
    qm_stub() {
        [[ "$1 $2 $4" == 'guest exec --' ]] || return 1
        local out rc
        out=$(RUNNER_PROC_ROOT="$STUB_DIR/proc" RUNNER_CGROUP_ROOT="$STUB_DIR/cgroup" \
            RUNNER_ROLLOVER_MARKER="$STUB_DIR/marker" /bin/bash -c "$7") && rc=0 || rc=$?
        /usr/bin/jq -n --argjson rc "$rc" --arg out "$out" '{exitcode:$rc,"out-data":($out + "\n")}'
    }
    export -f qm_stub
    jq() { /usr/bin/jq "$@"; }

    rollover_quiesce_guest 9001
    [ "$ROLLOVER_FROZEN_CGROUP" = /runner ]
    [ "$(cat "$STUB_DIR/cgroup/runner/cgroup.freeze")" = 1 ]
    [ "$(cat "$STUB_DIR/marker")" = /runner ]
}

@test "quiescence fails closed for ambiguous Listener processes" {
    pgrep() { [[ "$2" == Runner.Listener ]] && printf '123\n456\n'; }
    export -f pgrep
    qm_stub() {
        local out rc
        out=$(/bin/bash -c "$7") && rc=0 || rc=$?
        /usr/bin/jq -n --argjson rc "$rc" --arg out "$out" '{exitcode:$rc,"out-data":($out + "\n")}'
    }
    export -f qm_stub
    jq() { /usr/bin/jq "$@"; }
    run rollover_quiesce_guest 9001
    [ "$status" -ne 0 ]
}

@test "direct run.sh quiescence detects a Worker and thaws immediately" {
    mkdir -p "$STUB_DIR/proc/123" "$STUB_DIR/cgroup/runner"
    printf '0::/runner\n' > "$STUB_DIR/proc/123/cgroup"
    printf '0\n' > "$STUB_DIR/cgroup/runner/cgroup.freeze"
    printf 'frozen 1\n' > "$STUB_DIR/cgroup/runner/cgroup.events"
    pgrep() {
        [[ "$2" == Runner.Listener ]] && { printf '123\n'; return 0; }
        [[ "$2" == Runner.Worker ]] && { printf '124\n'; return 0; }
        return 1
    }
    export -f pgrep
    qm_stub() {
        local out rc
        out=$(RUNNER_PROC_ROOT="$STUB_DIR/proc" RUNNER_CGROUP_ROOT="$STUB_DIR/cgroup" \
            RUNNER_ROLLOVER_MARKER="$STUB_DIR/marker" /bin/bash -c "$7") && rc=0 || rc=$?
        /usr/bin/jq -n --argjson rc "$rc" --arg out "$out" '{exitcode:$rc,"out-data":($out + "\n")}'
    }
    export -f qm_stub
    jq() { /usr/bin/jq "$@"; }

    run rollover_quiesce_guest 9001
    [ "$status" -eq 2 ]
    [ "$(cat "$STUB_DIR/cgroup/runner/cgroup.freeze")" = 0 ]
    [ ! -e "$STUB_DIR/marker" ]
}

@test "resume guest program verifies identity and thaws the Listener cgroup" {
    mkdir -p "$STUB_DIR/proc/123" "$STUB_DIR/cgroup/runner"
    printf '0::/runner\n' > "$STUB_DIR/proc/123/cgroup"
    mkdir -p "$STUB_DIR/cgroup/runner"
    printf '1\n' > "$STUB_DIR/cgroup/runner/cgroup.freeze"
    printf '/runner\n' > "$STUB_DIR/marker"
    pgrep() { [[ "$2" == Runner.Listener ]] && printf '123\n'; }
    export -f pgrep
    qm_stub() {
        [[ "$1 $2 $4" == 'guest exec --' ]] || return 1
        local out rc
        out=$(RUNNER_PROC_ROOT="$STUB_DIR/proc" RUNNER_CGROUP_ROOT="$STUB_DIR/cgroup" \
            RUNNER_ROLLOVER_MARKER="$STUB_DIR/marker" /bin/bash -c "$7" "$8" "$9") && rc=0 || rc=$?
        /usr/bin/jq -n --argjson rc "$rc" --arg out "$out" '{exitcode:$rc,"out-data":($out + "\n")}'
    }
    export -f qm_stub
    jq() { /usr/bin/jq "$@"; }

    ROLLOVER_FROZEN_CGROUP=/runner
    run rollover_resume_guest 9001
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_DIR/cgroup/runner/cgroup.freeze")" = 0 ]
    [ ! -e "$STUB_DIR/marker" ]
}

@test "resume refuses a stale cgroup identity and leaves ownership marker" {
    mkdir -p "$STUB_DIR/proc/123" "$STUB_DIR/cgroup/current"
    printf '0::/current\n' > "$STUB_DIR/proc/123/cgroup"
    printf '1\n' > "$STUB_DIR/cgroup/current/cgroup.freeze"
    printf '/previous\n' > "$STUB_DIR/marker"
    pgrep() { [[ "$2" == Runner.Listener ]] && printf '123\n'; }
    export -f pgrep
    qm_stub() {
        local out rc
        out=$(RUNNER_PROC_ROOT="$STUB_DIR/proc" RUNNER_CGROUP_ROOT="$STUB_DIR/cgroup" \
            RUNNER_ROLLOVER_MARKER="$STUB_DIR/marker" /bin/bash -c "$7" "$8" "$9") && rc=0 || rc=$?
        /usr/bin/jq -n --argjson rc "$rc" --arg out "$out" '{exitcode:$rc,"out-data":($out + "\n")}'
    }
    export -f qm_stub
    jq() { /usr/bin/jq "$@"; }

    run resume_runner_cgroup 9001 /previous
    [ "$status" -ne 0 ]
    [ "$(cat "$STUB_DIR/cgroup/current/cgroup.freeze")" = 1 ]
    [ "$(cat "$STUB_DIR/marker")" = /previous ]
}

@test "resume requires guest-exec exitcode zero and explicit THAWED ack" {
    qm_stub() { printf '{"exitcode":1,"out-data":"THAWED\\n"}\n'; }
    export -f qm_stub
    run resume_runner_cgroup 9001
    [ "$status" -ne 0 ]

    qm_stub() { printf '{"exitcode":0,"out-data":""}\n'; }
    export -f qm_stub
    run resume_runner_cgroup 9001
    [ "$status" -ne 0 ]

    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'owned|9001|old-a|acme|1|0|nonce-a\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    rollover_pending_identity_matches() { return 0; }
    qm_stub() {
        [[ "$1 $2" == 'status 9001' ]] && return 0
        [[ "$1 $2" == 'guest exec' ]] && printf '{"exitcode":0,"out-data":""}\n'
    }
    export -f qm_stub
    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ -f "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "EXIT cleanup thaws an owned freeze but preserves a committed one" {
    rollover_resume_guest() { printf 'thaw %s\n' "$1" >> "$STUB_DIR/thaws"; }
    rollover_pending_identity_matches() { return 0; }
    run rollover_arm_cleanup 9001 old-a acme 1
    [ "$status" -eq 0 ]
    grep -q '^thaw 9001$' "$STUB_DIR/thaws"

    rm -f "$STUB_DIR/thaws"
    committed_arm() { rollover_arm_cleanup 9002 old-b acme 1; ROLLOVER_FROZEN_COMMITTED=true; }
    run committed_arm
    [ "$status" -eq 0 ]
    [ ! -e "$STUB_DIR/thaws" ]
}

@test "cleanup retains durable ownership when thaw cannot be verified" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'owned|9001|old-a|acme|1|0|nonce-a\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    rollover_resume_guest() { return 1; }
    qm_stub() { [[ "$1 $2" == 'status 9001' ]]; }
    export -f qm_stub
    failed_cleanup() {
        rollover_arm_cleanup 9001 old-a acme 1
        ROLLOVER_PENDING_FILE="$ROLLOVER_PENDING_DIR/9001.pending"
        rollover_cleanup_frozen
        rollover_disarm_cleanup
    }
    run failed_cleanup
    [ "$status" -eq 0 ]
    [ -f "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "committed pending destroy survives failure and is retried to cleanup" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'committed|9001|old-a|acme|1|42|nonce-a\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    github_runner_deregister_id() { return 0; }
    rollover_pending_identity_matches() { return 0; }
    qm_stub() {
        case "$1 $2" in
            "status 9001") printf 'status: stopped\n' ;;
            "destroy 9001") [[ ! -e "$STUB_DIR/destroy-fails" ]] ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    : > "$STUB_DIR/destroy-fails"
    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ -e "$ROLLOVER_PENDING_DIR/9001.pending" ]

    rm -f "$STUB_DIR/destroy-fails"
    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "durable pre-quiesce ownership thaws after an untrappable process death" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'owned|9001|old-a|acme|1|0|nonce-a|/runner\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    runner_rollover_marker_state() { printf '/runner\n'; }
    resume_runner_cgroup() { printf 'thaw %s\n' "$1" >> "$STUB_DIR/thaws"; }
    rollover_clear_identity_nonce() { return 0; }
    rollover_pending_identity_matches() { return 0; }
    qm_stub() { [[ "$1 $2" == 'status 9001' ]]; }
    export -f qm_stub

    run recover_rollover_pending
    [ "$status" -eq 0 ]
    grep -q '^thaw 9001$' "$STUB_DIR/thaws"
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "owned recovery accepts an absent marker only after a positive guest query" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'owned|9001|old-a|acme|1|0|nonce-a|/runner\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    runner_rollover_marker_state() { printf 'absent\n'; }
    resume_runner_cgroup() { return 1; }
    rollover_pending_identity_matches() { return 0; }
    rollover_clear_identity_nonce() { return 0; }
    qm_stub() { [[ "$1 $2" == 'status 9001' ]]; }
    export -f qm_stub

    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "preparing recovery clears a nonce when crash happened before guest invocation" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'preparing|9001|old-a|acme|1|0|nonce-a|\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    rollover_pending_identity_matches() { return 0; }
    runner_rollover_marker_state() { printf 'absent\n'; }
    rollover_clear_identity_nonce() { printf 'clear %s %s\n' "$1" "$5" >> "$STUB_DIR/recovery"; }
    resume_runner_cgroup() { printf 'unexpected thaw\n' >> "$STUB_DIR/recovery"; return 1; }
    qm_stub() { [[ "$1 $2" == 'status 9001' ]]; }
    export -f qm_stub

    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
    [ "$(cat "$STUB_DIR/recovery")" = 'clear 9001 nonce-a' ]
}

@test "preparing recovery thaws marker after crash before frozen phase advance" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'preparing|9001|old-a|acme|1|0|nonce-a|\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    rollover_pending_identity_matches() { return 0; }
    runner_rollover_marker_state() { printf '/runner\n'; }
    resume_runner_cgroup() { printf 'thaw %s %s\n' "$1" "$2" >> "$STUB_DIR/recovery"; }
    rollover_clear_identity_nonce() { printf 'clear %s %s\n' "$1" "$5" >> "$STUB_DIR/recovery"; }
    qm_stub() { [[ "$1 $2" == 'status 9001' ]]; }
    export -f qm_stub

    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
    [ "$(sed -n '1p' "$STUB_DIR/recovery")" = 'thaw 9001 /runner' ]
    [ "$(sed -n '2p' "$STUB_DIR/recovery")" = 'clear 9001 nonce-a' ]
}

@test "preparing recovery retains ownership on guest transport uncertainty" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'preparing|9001|old-a|acme|1|0|nonce-a|\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    rollover_pending_identity_matches() { return 0; }
    runner_rollover_marker_state() { return 1; }
    rollover_clear_identity_nonce() { return 0; }
    qm_stub() { [[ "$1 $2" == 'status 9001' ]]; }
    export -f qm_stub

    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "pending recovery survives initial destroy failure" {
    setup_destroy_candidate
    rollover_destroy_vm() { return 1; }

    run rollover_destroy_one old-a 9001 1 acme
    [ "$status" -eq 4 ]
    [ -f "$ROLLOVER_PENDING_DIR/9001.pending" ]
    grep -q '^committed|9001|old-a|acme|1|42|test-nonce|/runner.slice/old-a$' "$ROLLOVER_PENDING_DIR/9001.pending"
    run rollover_vmid_is_committed_pending 9001
    [ "$status" -eq 0 ]
    grep -q 'rollover_vmid_is_committed_pending' "$REPO_ROOT/lib/watch.sh"

    github_runner_deregister_id() { return 0; }
    qm_stub() {
        [[ "$1 $2" == 'status 9001' ]] && { printf 'status: stopped\n'; return; }
        [[ "$1 $2" == 'destroy 9001' ]]
    }
    export -f qm_stub
    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
}

@test "stale pending record never destroys a reused VMID" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'committed|9001|old-a|acme|1|42|nonce-a\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    qm_stub() {
        case "$1 $2" in
            "status 9001") printf 'status: stopped\n' ;;
            "config 9001") printf 'name: intruder\ntags: runner;gen-1;rollover-other\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n' ;;
            "destroy 9001") echo destroyed >> "$STUB_DIR/actions" ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ -f "$ROLLOVER_PENDING_DIR/9001.pending" ]
    [ ! -e "$STUB_DIR/actions" ]
}

@test "pending identity requires exact name org generation and nonce tag" {
    qm_stub() {
        [[ "$1 $2" == 'config 9001' ]] || return 1
        printf 'name: old-a\ntags: runner;gen-1;rollover-nonce-a\ncicustom: user=local:snippets/runner-user-data-acme.yaml\n'
    }
    export -f qm_stub
    run rollover_pending_identity_matches 9001 old-a acme 1 nonce-a
    [ "$status" -eq 0 ]
    run rollover_pending_identity_matches 9001 old-a acme 1 nonce-b
    [ "$status" -ne 0 ]
    run rollover_pending_identity_matches 9001 other acme 1 nonce-a
    [ "$status" -ne 0 ]
}

@test "committed recovery stops a running frozen VM before bounded destroy and retries stop failure" {
    mkdir -p "$ROLLOVER_PENDING_DIR"
    printf 'committed|9001|old-a|acme|1|42|nonce-a\n' > "$ROLLOVER_PENDING_DIR/9001.pending"
    rollover_pending_identity_matches() { return 0; }
    github_runner_deregister_id() { return 0; }
    qm_stub() {
        case "$1 $2" in
            "status 9001") [[ -e "$STUB_DIR/stopped" ]] && printf 'status: stopped\n' || printf 'status: running\n' ;;
            "stop 9001")
                printf '%s\n' "$*" >> "$STUB_DIR/stops"
                [[ ! -e "$STUB_DIR/stop-fails" ]] && : > "$STUB_DIR/stopped"
                [[ ! -e "$STUB_DIR/stop-fails" ]]
                ;;
            "destroy 9001") printf destroy >> "$STUB_DIR/actions" ;;
            *) return 1 ;;
        esac
    }
    export -f qm_stub
    : > "$STUB_DIR/stop-fails"
    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ -f "$ROLLOVER_PENDING_DIR/9001.pending" ]
    [ ! -e "$STUB_DIR/actions" ]

    rm -f "$STUB_DIR/stop-fails"
    run recover_rollover_pending
    [ "$status" -eq 0 ]
    [ ! -e "$ROLLOVER_PENDING_DIR/9001.pending" ]
    grep -q '^stop 9001 --timeout 30$' "$STUB_DIR/stops"
    [ "$(cat "$STUB_DIR/actions")" = destroy ]
}

@test "guard reclone and manual destroy share the org capacity lock" {
    grep -q 'ROLLOVER_ORG_LOCK_PREFIX' "$REPO_ROOT/lib/guard.sh"
    grep -q 'ROLLOVER_ORG_LOCK_PREFIX' "$REPO_ROOT/lib/reclone.sh"
    grep -q 'ROLLOVER_ORG_LOCK_PREFIX' "$REPO_ROOT/lib/destroy.sh"
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
