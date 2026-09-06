#!/usr/bin/env bats
# Canary label isolation (issue #21).
#
# A canary carrying the production labels (self-hosted/Linux/X64) would be
# handed real jobs while it waits for its own dispatch, run one on an
# unvalidated image, then destroy itself (--ephemeral) and leave the canary
# dispatch with no runner.
#
# Runner registration is JIT (PR #1, merged into integration ahead of this
# branch): fetch_jit_config mints a single-use config on the Proxmox host
# with a labels array baked in, and GitHub does not add default labels to a
# JIT-registered runner. There is no guest-side config.sh step any more and
# nothing in the guest reads a labels.env, so this branch's original
# vendor-data snippet (write_canary_vendor_snippet, a cicustom vendor=
# element, and register-runner.sh's --no-default-labels) would have no
# effect and has been removed rather than kept as dead code.
#
# clone_runner --canary isolates a canary's labels host-side instead: it
# shadows RUNNER_LABELS with a local before calling fetch_jit_config (bash
# locals are visible to everything called from that point in the stack), so
# the minted JIT config carries only gen-<N>-canary. These tests prove that
# seam, clone_runner's canary-only tags/cicustom, and snippet cleanup on
# destroy/reclone.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    # clone_runner renders each VM's cloud-init snippet from the installed
    # runner-user-data.yaml, so point INSTALL_DIR at the repo copy. Must
    # precede load_lib: common.sh only defaults INSTALL_DIR when unset.
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
    CLONE_PAUSE_RETRY_MAX_SECONDS=0
    # clone_runner mints a single-use JIT config on the host before cloning and
    # refuses to run without the org config loaded.
    write_org_config acme ghp_test acme-org
    load_org_config acme
    stub_clone_success
}

stub_clone_success() {
    stub_out qm 'clone *' < /dev/null
    stub_out qm 'config *' < /dev/null
    stub_out qm 'set *' < /dev/null
    stub_out qm 'start *' < /dev/null
}

seed_generation() {
    local vmid="${1:-9000}" gid="${2:-5}" state="${3:-active}"
    gen_store_init
    gen_create "$vmid" \
        GEN_ID="$gid" \
        GEN_STATE="$state" \
        GEN_TEMPLATE_DIGEST=abc \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
}

write_pointer() {
    local vmid="$1"
    {
        printf 'NETWORK_BRIDGE="%s"\n' "$NETWORK_BRIDGE"
        printf 'VM_STORAGE="%s"\n' "$VM_STORAGE"
        printf 'TEMPLATE_ID="%s"\n' "$vmid"
        printf 'MIN_VMID="%s"\n' "$MIN_VMID"
    } > "$CONFIG_FILE"
}

# Stand in for the real GitHub mint call (same seam tests/unit/clone_pointer.bats
# stubs) and record the RUNNER_LABELS clone_runner handed it, so a test can prove
# what the minted config would have carried without making a real HTTP call.
record_jit_labels() {
    fetch_jit_config() {
        printf '%s' "${RUNNER_LABELS-<unset>}" > "$STUB_DIR/jit-labels-seen"
        printf 'AAAAjitconfigAAAA'
    }
}

# ---------------------------------------------------------------------------
# fetch_jit_config itself, unstubbed: the jq encoding that turns RUNNER_LABELS
# into the generate-jitconfig request body, and the response-side invariant
# check, are both real code paths that record_jit_labels above never touches
# (it replaces fetch_jit_config wholesale). These tests call the real
# function against a stubbed curl instead.
# ---------------------------------------------------------------------------

# tests/stubs/bin/jq is a fake (strict-stub) like every other command here;
# shadow it with a function that shells out to the real binary so
# fetch_jit_config's actual jq expressions run for real. Same convention as
# tests/unit/rollover.bats.
use_real_jq() {
    jq() { /usr/bin/jq "$@"; }
}

# Stand in for curl at fetch_jit_config's only two call sites: the
# generate-jitconfig POST (has -o and --data) and, when the label-invariant
# check below fails a canary, the deregister DELETE (has neither). Captures
# the POST's --data payload to $STUB_DIR/jit-request-body.json so a test can
# inspect exactly what was requested, and serves the response prepared at
# $STUB_DIR/jit-response.json. The DELETE call is left to the normal stub
# call-log (assert_called curl 'pattern') since curl_stub runs after that log
# line, not instead of it.
stub_jit_mint_curl() {
    curl_stub() {
        local args=("$@") i out_file=""
        for ((i = 0; i < ${#args[@]}; i++)); do
            case "${args[$i]}" in
                -o) out_file="${args[$((i + 1))]}" ;;
                --data) printf '%s' "${args[$((i + 1))]}" > "$STUB_DIR/jit-request-body.json" ;;
            esac
        done
        if [[ -n "$out_file" ]]; then
            cp "$STUB_DIR/jit-response.json" "$out_file"
            printf '201'
            return 0
        fi
        # No -o file means this is the deregister DELETE, not the mint POST.
        # A test can make it fail by touching $STUB_DIR/jit-delete-fails.
        [[ -f "$STUB_DIR/jit-delete-fails" ]] && return 1
        return 0
    }
    export -f curl_stub
}

# Write a generate-jitconfig-shaped response: a runner id, its labels (each
# {name}, mirroring GitHub's real {id,name,type} per-label shape), and a
# fixed encoded_jit_config. Extra label names beyond what a test requested
# simulate GitHub attaching a read-only default.
write_jit_response() {
    local runner_id="$1"; shift
    local labels_json='[]'
    if [[ $# -gt 0 ]]; then
        labels_json=$(printf '%s\n' "$@" | /usr/bin/jq -R '{name: .}' | /usr/bin/jq -s '.')
    fi
    /usr/bin/jq -n --argjson id "$runner_id" --argjson labels "$labels_json" \
        '{runner: {id: $id, labels: $labels}, encoded_jit_config: "AAAAjitconfigAAAA"}' \
        > "$STUB_DIR/jit-response.json"
}

# ---------------------------------------------------------------------------
# The old vendor-data/config.sh mechanism is gone, not dead code
# ---------------------------------------------------------------------------

# A bare `! command` line does not trip `set -e` (POSIX: a pipeline negated
# with ! is exempt from errexit), so these negative assertions have to run
# under `run` and check $status explicitly -- a bare `!`-prefixed line here
# would assert nothing beyond "the test function's last statement passed".
# Scoped to non-comment lines (`^[[:space:]]*[^#[:space:]]`) because the
# explanatory comment a few lines above this in runner-user-data.yaml names
# config.sh/labels.env/no-default-labels to say they are NOT used -- an
# unscoped grep would match that comment and pass even if a real config.sh
# invocation were reintroduced.
@test "register-runner.sh has no config.sh step and reads no labels.env" {
    run grep -E '^[[:space:]]*[^#[:space:]].*config\.sh' "$REPO_ROOT/templates/runner-user-data.yaml"
    [ "$status" -ne 0 ]
    run grep -E '^[[:space:]]*[^#[:space:]].*labels\.env' "$REPO_ROOT/templates/runner-user-data.yaml"
    [ "$status" -ne 0 ]
    run grep -E '^[[:space:]]*[^#[:space:]].*no-default-labels' "$REPO_ROOT/templates/runner-user-data.yaml"
    [ "$status" -ne 0 ]
    run grep -E '^[[:space:]]*[^#[:space:]].*RUNNER_NO_DEFAULT_LABELS' "$REPO_ROOT/templates/runner-user-data.yaml"
    [ "$status" -ne 0 ]
}

@test "write_canary_vendor_snippet no longer exists" {
    run declare -F write_canary_vendor_snippet
    [ "$status" -ne 0 ]
    run grep -rq 'write_canary_vendor_snippet' "$REPO_ROOT/lib"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# clone_runner: production path is unaffected
# ---------------------------------------------------------------------------

@test "normal clone_runner does not shadow RUNNER_LABELS" {
    record_jit_labels
    seed_generation 9000 5
    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]
    [ "$output" = "9001" ]
    [ "$(cat "$STUB_DIR/jit-labels-seen")" = "<unset>" ]
    assert_called qm 'set 9001 --cicustom user=local:snippets/runner-9001-user-acme.yaml,meta=local:snippets/runner-9001-meta.yaml'
    refute_called qm 'set * --cicustom *vendor=*'
    [ ! -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
    assert_called qm 'set 9001 --tags runner,gen-5'
    refute_called qm 'set * --tags *runner-canary*'
}

@test "normal clone_runner leaves an org's own RUNNER_LABELS untouched" {
    record_jit_labels
    seed_generation 9000 5
    RUNNER_LABELS="self-hosted,linux,x64,gpu"
    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_DIR/jit-labels-seen")" = "self-hosted,linux,x64,gpu" ]
}

@test "production clone call sites do not pass --canary" {
    # A bare `!` here would assert nothing (see the comment above the
    # config.sh test) -- a production call site that DID pass --canary must
    # actually fail this test, so enforce $status explicitly.
    run grep -E 'clone_runner[[:space:]].*--canary' \
        "$REPO_ROOT/lib/create.sh" \
        "$REPO_ROOT/lib/watch.sh" \
        "$REPO_ROOT/lib/reclone.sh"
    [ "$status" -ne 0 ]
    grep -q 'clone_runner "\$RUNNER_NAME" "\$SELECTED_ORG"' "$REPO_ROOT/lib/create.sh"
    grep -q 'clone_runner "\$slot" "\$org"' "$REPO_ROOT/lib/watch.sh"
    grep -q 'clone_runner "\$NAME" "\$ORG"' "$REPO_ROOT/lib/reclone.sh"
}

@test "clone_runner --template without --canary is rejected" {
    record_jit_labels
    seed_generation 8901 9 candidate
    run --separate-stderr clone_runner --template 8901 runner-acme-1 acme
    [ "$status" -ne 0 ]
    refute_called qm 'clone *'
}

# ---------------------------------------------------------------------------
# fetch_jit_config, unstubbed: the request-body encoding record_jit_labels
# never exercises.
# ---------------------------------------------------------------------------

@test "fetch_jit_config's real request body carries the production default labels" {
    use_real_jq
    stub_jit_mint_curl
    write_jit_response 1 self-hosted linux x64
    run --separate-stderr fetch_jit_config runner-acme-1
    [ "$status" -eq 0 ]
    [ "$output" = "AAAAjitconfigAAAA" ]
    run /usr/bin/jq -c '.labels' "$STUB_DIR/jit-request-body.json"
    [ "$output" = '["self-hosted","linux","x64"]' ]
}

@test "fetch_jit_config's real request body carries only gen-5-canary for a canary mint" {
    use_real_jq
    stub_jit_mint_curl
    write_jit_response 1 gen-5-canary
    RUNNER_LABELS="gen-5-canary"
    run --separate-stderr fetch_jit_config canary-gen5
    [ "$status" -eq 0 ]
    [ "$output" = "AAAAjitconfigAAAA" ]
    run /usr/bin/jq -c '.labels' "$STUB_DIR/jit-request-body.json"
    [ "$output" = '["gen-5-canary"]' ]
}

# ---------------------------------------------------------------------------
# JIT_ENFORCE_EXACT_LABELS: enforcing, not assuming, that GitHub adds no
# default labels to a JIT-registered runner.
# ---------------------------------------------------------------------------

@test "fetch_jit_config succeeds when the response labels match the canary request exactly" {
    use_real_jq
    stub_jit_mint_curl
    write_jit_response 42 gen-5-canary
    RUNNER_LABELS="gen-5-canary"
    JIT_ENFORCE_EXACT_LABELS=1
    run --separate-stderr fetch_jit_config canary-gen5
    [ "$status" -eq 0 ]
    [ "$output" = "AAAAjitconfigAAAA" ]
    refute_called curl '*DELETE*'
}

@test "fetch_jit_config deregisters and fails closed when GitHub attaches an unrequested label" {
    use_real_jq
    stub_jit_mint_curl
    write_jit_response 42 gen-5-canary self-hosted
    RUNNER_LABELS="gen-5-canary"
    JIT_ENFORCE_EXACT_LABELS=1
    run --separate-stderr fetch_jit_config canary-gen5
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"self-hosted"* ]]
    assert_called curl '*DELETE*runners/42*'
}

@test "fetch_jit_config never applies the label check to a production mint" {
    use_real_jq
    stub_jit_mint_curl
    # A response that adds a label beyond the requested set (self-hosted,
    # linux, x64) would fail closed on the canary path -- prove production
    # is not subject to that check at all: JIT_ENFORCE_EXACT_LABELS is unset
    # here, so this must succeed even though the response is not exact.
    write_jit_response 7 self-hosted linux x64 gpu-node
    run --separate-stderr fetch_jit_config runner-acme-1
    [ "$status" -eq 0 ]
    [ "$output" = "AAAAjitconfigAAAA" ]
    refute_called curl '*DELETE*'
}

# A deregister that fails, or that never runs because the response carried no
# usable runner id, must not leave the operator thinking the canary is
# isolated -- the preceding log_error already says "refusing to start an
# unisolated canary", which is only true once the GitHub-side registration is
# actually gone.
@test "fetch_jit_config warns distinctly when the deregister DELETE itself fails" {
    use_real_jq
    stub_jit_mint_curl
    : > "$STUB_DIR/jit-delete-fails"
    write_jit_response 42 gen-5-canary self-hosted
    RUNNER_LABELS="gen-5-canary"
    JIT_ENFORCE_EXACT_LABELS=1
    run --separate-stderr fetch_jit_config canary-gen5
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"unexpected label"* ]]
    [[ "$stderr" == *"failed to deregister runner 42"* ]]
    [[ "$stderr" == *"remove it manually"* ]]
    assert_called curl '*DELETE*runners/42*'
}

@test "fetch_jit_config warns distinctly when the response carries no usable runner id" {
    use_real_jq
    stub_jit_mint_curl
    # write_jit_response with no runner_id argument the code can parse as
    # numeric -- omit .runner.id entirely.
    /usr/bin/jq -n --argjson labels '[{"name":"gen-5-canary"},{"name":"self-hosted"}]' \
        '{runner: {labels: $labels}, encoded_jit_config: "AAAAjitconfigAAAA"}' \
        > "$STUB_DIR/jit-response.json"
    RUNNER_LABELS="gen-5-canary"
    JIT_ENFORCE_EXACT_LABELS=1
    run --separate-stderr fetch_jit_config canary-gen5
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"unexpected label"* ]]
    [[ "$stderr" == *"failed to deregister runner <unknown>"* ]]
    [[ "$stderr" == *"remove it manually"* ]]
    refute_called curl '*DELETE*'
}

# clone_runner declares JIT_ENFORCE_EXACT_LABELS=0 unconditionally (not just
# inside the canary branch) precisely so that this cannot happen for real:
# an org .conf or an inherited exported env var must never subject a
# production mint to the canary-only check. Uses the real fetch_jit_config
# (via use_real_jq/stub_jit_mint_curl) because a stubbed one would not
# exercise the check either way -- this has to prove the leak is actually
# closed, not just that clone_runner still returns 0.
@test "an org conf exporting JIT_ENFORCE_EXACT_LABELS=1 does not subject a production mint to the label check" {
    use_real_jq
    stub_jit_mint_curl
    printf 'GITHUB_ORG="acme-org"\nGITHUB_PAT="ghp_test"\nJIT_ENFORCE_EXACT_LABELS=1\n' \
        > "$ORG_CONFIG_DIR/acme.conf"
    load_org_config acme
    seed_generation 9000 5
    # A response beyond the production defaults would fail closed if the
    # canary-only check applied here.
    write_jit_response 7 self-hosted linux x64 gpu-node
    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]
    [ "$output" = "9001" ]
    refute_called curl '*DELETE*'
}

# ---------------------------------------------------------------------------
# clone_runner --canary / clone_canary_runner
# ---------------------------------------------------------------------------

@test "clone_runner --canary mints a JIT config carrying only gen-N-canary" {
    record_jit_labels
    seed_generation 9000 5
    # Even when the org config sets its own production RUNNER_LABELS, a
    # canary clone must not inherit it.
    RUNNER_LABELS="self-hosted,linux,x64"
    run --separate-stderr clone_runner --canary canary-gen5 acme
    [ "$status" -eq 0 ]
    [ "$output" = "9001" ]
    [ "$(cat "$STUB_DIR/jit-labels-seen")" = "gen-5-canary" ]
}

@test "clone_runner --canary cicustom stays user=+meta=, no vendor snippet" {
    record_jit_labels
    seed_generation 9000 5
    run --separate-stderr clone_runner --canary canary-gen5 acme
    [ "$status" -eq 0 ]
    assert_called qm 'set 9001 --cicustom user=local:snippets/runner-9001-user-acme.yaml,meta=local:snippets/runner-9001-meta.yaml'
    refute_called qm 'set * --cicustom *vendor=*'
    [ ! -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
}

@test "clone_runner --canary tags runner-canary alongside gen-N" {
    record_jit_labels
    seed_generation 9000 5
    run --separate-stderr clone_runner --canary canary-gen5 acme
    [ "$status" -eq 0 ]
    assert_called qm 'set 9001 --tags runner,gen-5,runner-canary'
    refute_called qm 'set * --tags runner,gen-5'
}

@test "clone_canary_runner clones the candidate template not TEMPLATE_ID" {
    record_jit_labels
    seed_generation 9000 1 active
    gen_create 8901 \
        GEN_ID=9 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0
    [ "$TEMPLATE_ID" = "9000" ]
    write_pointer 9000

    run --separate-stderr clone_canary_runner canary-gen9 acme 8901
    [ "$status" -eq 0 ]
    [ "$output" = "9001" ]
    assert_called qm 'clone 8901 9001 --name canary-gen9'
    refute_called qm 'clone 9000 *'
    assert_called qm 'set 9001 --tags runner,gen-9,runner-canary'
    [ "$(cat "$STUB_DIR/jit-labels-seen")" = "gen-9-canary" ]
}

@test "clone_runner --canary fails closed without a generation record" {
    record_jit_labels
    run --separate-stderr clone_runner --canary canary-gen1 acme
    [ "$status" -ne 0 ]
    refute_called qm 'clone *'
    refute_called qm 'start *'
    refute_called qm 'destroy *'
}

@test "clone_canary_runner fails closed on a missing template VMID" {
    record_jit_labels
    seed_generation 9000 5
    run --separate-stderr clone_canary_runner canary-gen5 acme
    [ "$status" -ne 0 ]
    refute_called qm 'clone *'
}

@test "failed canary clone cleans meta/user snippets and does not destroy TEMPLATE_ID" {
    record_jit_labels
    seed_generation 9000 5
    stub_out qm 'config *' <<'EOF'
name: canary-gen5
EOF
    stub_status qm 'start *' 1
    stub_out qm 'destroy *' < /dev/null
    stub_out pvesm 'list *' <<'EOF'
Volid Format
EOF
    # Leave stale snippets that _fail must remove even if a write raced.
    mkdir -p "$SNIPPETS_DIR"
    : > "$SNIPPETS_DIR/runner-9001-vendor.yaml"
    : > "$SNIPPETS_DIR/runner-9001-meta.yaml"
    : > "$SNIPPETS_DIR/runner-9001-user-acme.yaml"

    run --separate-stderr clone_runner --canary canary-gen5 acme
    [ "$status" -eq 1 ]
    refute_called qm 'destroy 9000*'
    assert_called qm 'destroy 9001*'
    [ ! -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-meta.yaml" ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-user-acme.yaml" ]
}

# ---------------------------------------------------------------------------
# destroy / reclone cleanup
# ---------------------------------------------------------------------------

@test "cleanup_clone_snippets removes meta, user, and vendor files" {
    mkdir -p "$SNIPPETS_DIR"
    : > "$SNIPPETS_DIR/runner-9001-meta.yaml"
    : > "$SNIPPETS_DIR/runner-9001-user-acme.yaml"
    : > "$SNIPPETS_DIR/runner-9001-vendor.yaml"
    : > "$SNIPPETS_DIR/runner-9002-vendor.yaml"

    run cleanup_clone_snippets 9001
    [ "$status" -eq 0 ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-meta.yaml" ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-user-acme.yaml" ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
    [ -f "$SNIPPETS_DIR/runner-9002-vendor.yaml" ]
}

@test "destroy.sh and reclone.sh clean snippets via cleanup_clone_snippets" {
    grep -q 'cleanup_clone_snippets' "$REPO_ROOT/lib/destroy.sh"
    grep -q 'cleanup_clone_snippets' "$REPO_ROOT/lib/reclone.sh"
    # Both reclone destroy paths (rapid-death deferral and the real destroy)
    # must drop the snippet, otherwise a later occupant of the VMID could
    # inherit gen-N-canary labels.
    local hits
    hits=$(grep -c 'cleanup_clone_snippets' "$REPO_ROOT/lib/reclone.sh")
    [ "$hits" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Tag composition: a canary must count toward its generation's refcount
# ---------------------------------------------------------------------------

@test "a canary's runner,gen-N,runner-canary tag is attributed to generation N" {
    gen_store_init
    gen_create 9000 \
        GEN_ID=5 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=abc \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.336.0
    TEMPLATE_ID=9000

    stub_out qm 'config 9000' <<'EOF'
name: github-runner-gen-5
scsi0: local-zfs:base-9000-disk-0,size=30G
template: 1
tags: runner;gen-5
EOF
    stub_out qm 'config 9500' <<'EOF'
name: canary-gen5
tags: runner,gen-5,runner-canary
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid Format
local-zfs:base-9000-disk-0 raw
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 github-runner-gen-5  stopped    8192              30.00 0
      9500 canary-gen5          running    2048              30.00 1234
EOF

    run generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}
