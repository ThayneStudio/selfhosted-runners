#!/usr/bin/env bats
# Canary label isolation (spec 7.1 / issue #21).
#
# A canary that also carries self-hosted/Linux/X64 is handed production jobs
# while it waits for its dispatch. These tests prove the guest config.sh
# invocation, the per-VM vendor-data snippet, clone_runner's canary-only
# cicustom/tags, and snippet cleanup on destroy.

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
    CLONE_PAUSE_RETRY_MAX_SECONDS=0
    stub_clone_success
}

stub_clone_success() {
    stub_out qm 'clone *' < /dev/null
    stub_out qm 'config *' < /dev/null
    stub_out qm 'set *' < /dev/null
    stub_out qm 'start *' < /dev/null
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"
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

# Guest-side register-runner.sh lives inside the cloud-config write_files
# body. Strip the YAML indent so the script can be executed.
extract_register_runner() {
    awk '
        $0 == "  - path: /opt/register-runner.sh" { want = 1 }
        want && $0 == "    content: |" { body = 1; next }
        body {
            if (substr($0, 1, 6) == "      ") { print substr($0, 7); next }
            if ($0 == "") { print; next }
            exit
        }
    ' "$REPO_ROOT/templates/runner-user-data.yaml"
}

# Run the extracted guest script against a fake root. Absolute guest paths
# are rewritten into $STUB_DIR/guest so the test never touches the host.
run_register_runner() {
    local guest="$STUB_DIR/guest"
    local script="$guest/opt/register-runner.sh"
    mkdir -p "$guest/etc/github-runner" "$guest/opt" \
        "$guest/home/runner/actions-runner" "$STUB_DIR/guest-bin"

    extract_register_runner | sed \
        -e "s|/etc/github-runner|$guest/etc/github-runner|g" \
        -e "s|/home/runner/actions-runner|$guest/home/runner/actions-runner|g" \
        -e "s|/opt/.runner-ready|$guest/opt/.runner-ready|g" \
        > "$script"
    [ -s "$script" ]
    grep -q 'config.sh' "$script"

    cat > "$guest/etc/github-runner/config.env" <<'EOF'
GITHUB_PAT="ghp_test"
GITHUB_ORG="acme"
RUNNER_LABELS="self-hosted,linux,x64"
DOCKER_MIRROR_URL=""
EOF

    cat > "$guest/home/runner/actions-runner/config.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$STUB_DIR/config.args"
printf '%s\n' "\$@" > "$STUB_DIR/config.argv"
exit 0
EOF
    cat > "$guest/home/runner/actions-runner/run.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "$guest/home/runner/actions-runner/config.sh" \
        "$guest/home/runner/actions-runner/run.sh"

    cat > "$STUB_DIR/guest-bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF
    chmod 755 "$STUB_DIR/guest-bin/sudo"
    ln -sf "$REPO_ROOT/tests/stubs/bin/_stub" "$STUB_DIR/guest-bin/shutdown"
    ln -sf "$REPO_ROOT/tests/stubs/bin/_stub" "$STUB_DIR/guest-bin/hostname"
    ln -sf "$REPO_ROOT/tests/stubs/bin/_stub" "$STUB_DIR/guest-bin/ip"
    ln -sf "$REPO_ROOT/tests/stubs/bin/_stub" "$STUB_DIR/guest-bin/resolvectl"

    stub_out shutdown '*' < /dev/null
    stub_out hostname '*' <<'EOF'
canary-gen5
EOF
    stub_out ip 'route' <<'EOF'
default via 192.168.1.1 dev eth0
EOF
    stub_out resolvectl 'status eth0' <<'EOF'
DNS Servers: 1.1.1.1
EOF
    stub_out systemctl 'is-active --quiet docker' < /dev/null
    stub_out curl '*' <<'EOF'
{"token":"reg-token"}
EOF
    stub_out jq '*' <<'EOF'
reg-token
EOF

    PATH="$STUB_DIR/guest-bin:$PATH" bash "$script"
}

# ---------------------------------------------------------------------------
# register-runner.sh / --no-default-labels
# ---------------------------------------------------------------------------

@test "production user-data still ships self-hosted,linux,x64 labels" {
    grep -q 'RUNNER_LABELS="self-hosted,linux,x64"' \
        "$REPO_ROOT/templates/runner-user-data.yaml"
}

@test "register-runner.sh sources labels.env before configuring" {
    extract_register_runner > "$STUB_DIR/register-runner.sh"
    awk '
        /source \/etc\/github-runner\/config.env/ { cfg = NR }
        /source \/etc\/github-runner\/labels.env/ { lab = NR }
        /sudo -u .* \.\/config.sh/ && !seen { seen = NR }
        END {
            if (!cfg || !lab || !seen) exit 1
            if (!(cfg < lab && lab < seen)) exit 1
        }
    ' "$STUB_DIR/register-runner.sh"
}

@test "register-runner.sh does not pass --no-default-labels without RUNNER_NO_DEFAULT_LABELS" {
    run --separate-stderr run_register_runner
    [ "$status" -eq 0 ]
    [ -f "$STUB_DIR/config.argv" ]
    ! grep -qx -- '--no-default-labels' "$STUB_DIR/config.argv"
    grep -q 'self-hosted,linux,x64' "$STUB_DIR/config.args"
}

@test "register-runner.sh passes --no-default-labels when RUNNER_NO_DEFAULT_LABELS=true" {
    mkdir -p "$STUB_DIR/guest/etc/github-runner"
    # run_register_runner overwrites config.env; drop labels.env in after the
    # first mkdir by creating it before the call — run_register_runner does not
    # delete an existing labels.env.
    mkdir -p "$STUB_DIR/guest/etc/github-runner"
    cat > "$STUB_DIR/guest/etc/github-runner/labels.env" <<'EOF'
RUNNER_LABELS="gen-5-canary"
RUNNER_NO_DEFAULT_LABELS=true
EOF

    run --separate-stderr run_register_runner
    [ "$status" -eq 0 ]
    grep -qx -- '--no-default-labels' "$STUB_DIR/config.argv"
    grep -q 'gen-5-canary' "$STUB_DIR/config.args"
    ! grep -q 'self-hosted' "$STUB_DIR/config.args"
}

# ---------------------------------------------------------------------------
# vendor-data snippet writer
# ---------------------------------------------------------------------------

@test "write_canary_vendor_snippet emits labels.env for gen-N-canary" {
    run write_canary_vendor_snippet 9001 7
    [ "$status" -eq 0 ]
    local snippet="$SNIPPETS_DIR/runner-9001-vendor.yaml"
    [ -f "$snippet" ]
    [ "$(file_mode "$snippet")" = "600" ]
    grep -q '^#cloud-config' "$snippet"
    grep -q '/etc/github-runner/labels.env' "$snippet"
    grep -q 'RUNNER_LABELS="gen-7-canary"' "$snippet"
    grep -q 'RUNNER_NO_DEFAULT_LABELS=true' "$snippet"
}

@test "write_canary_vendor_snippet fails closed on a non-numeric gen id" {
    run write_canary_vendor_snippet 9001 'not-a-number'
    [ "$status" -ne 0 ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
}

@test "write_canary_vendor_snippet fails closed on a non-numeric vmid" {
    run write_canary_vendor_snippet 'vmid' 7
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# clone_runner: production path stays byte-identical
# ---------------------------------------------------------------------------

@test "normal clone_runner cicustom is user= and meta= only" {
    seed_generation 9000 5
    run --separate-stderr clone_runner runner-acme-1 acme
    [ "$status" -eq 0 ]
    [ "$output" = "9001" ]
    assert_called qm 'set 9001 --cicustom user=local:snippets/runner-user-data-acme.yaml,meta=local:snippets/runner-9001-meta.yaml'
    refute_called qm 'set * --cicustom *vendor=*'
    [ -f "$SNIPPETS_DIR/runner-9001-meta.yaml" ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
    assert_called qm 'set 9001 --tags runner,gen-5'
    refute_called qm 'set * --tags *runner-canary*'
}

@test "production clone call sites do not pass --canary" {
    ! grep -E 'clone_runner[[:space:]].*--canary' \
        "$REPO_ROOT/lib/create.sh" \
        "$REPO_ROOT/lib/watch.sh" \
        "$REPO_ROOT/lib/reclone.sh"
    grep -q 'clone_runner "\$RUNNER_NAME" "\$SELECTED_ORG"' "$REPO_ROOT/lib/create.sh"
    grep -q 'clone_runner "\$slot" "\$org"' "$REPO_ROOT/lib/watch.sh"
    grep -q 'clone_runner "\$NAME" "\$ORG"' "$REPO_ROOT/lib/reclone.sh"
}

@test "clone_runner --template without --canary is rejected" {
    seed_generation 8901 9 candidate
    run --separate-stderr clone_runner --template 8901 runner-acme-1 acme
    [ "$status" -ne 0 ]
    refute_called qm 'clone *'
}

# ---------------------------------------------------------------------------
# clone_runner --canary / clone_canary_runner
# ---------------------------------------------------------------------------

@test "clone_runner --canary attaches vendor cicustom and tags runner-canary" {
    seed_generation 9000 5
    run --separate-stderr clone_runner --canary canary-gen5 acme
    [ "$status" -eq 0 ]
    [ "$output" = "9001" ]
    [ -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
    grep -q 'RUNNER_LABELS="gen-5-canary"' "$SNIPPETS_DIR/runner-9001-vendor.yaml"
    assert_called qm 'set 9001 --cicustom user=local:snippets/runner-user-data-acme.yaml,meta=local:snippets/runner-9001-meta.yaml,vendor=local:snippets/runner-9001-vendor.yaml'
    assert_called qm 'set 9001 --tags runner,gen-5,runner-canary'
    refute_called qm 'set * --tags runner,gen-5'
}

@test "clone_canary_runner clones the candidate template not TEMPLATE_ID" {
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
    grep -q 'RUNNER_LABELS="gen-9-canary"' "$SNIPPETS_DIR/runner-9001-vendor.yaml"
}

@test "clone_runner --canary fails closed without a generation record" {
    run --separate-stderr clone_runner --canary canary-gen1 acme
    [ "$status" -ne 0 ]
    refute_called qm 'clone *'
    refute_called qm 'start *'
    refute_called qm 'destroy *'
}

@test "clone_canary_runner fails closed on a missing template VMID" {
    seed_generation 9000 5
    run --separate-stderr clone_canary_runner canary-gen5 acme
    [ "$status" -ne 0 ]
    refute_called qm 'clone *'
}

@test "failed canary clone cleans the vendor snippet and does not destroy TEMPLATE_ID" {
    seed_generation 9000 5
    stub_out qm 'config *' <<'EOF'
name: canary-gen5
EOF
    stub_status qm 'start *' 1
    stub_out qm 'destroy *' < /dev/null
    stub_out pvesm 'list *' <<'EOF'
Volid Format
EOF
    # Leave a vendor file that _fail must remove even if write raced.
    mkdir -p "$SNIPPETS_DIR"
    : > "$SNIPPETS_DIR/runner-9001-vendor.yaml"
    : > "$SNIPPETS_DIR/runner-9001-meta.yaml"

    run --separate-stderr clone_runner --canary canary-gen5 acme
    [ "$status" -eq 1 ]
    refute_called qm 'destroy 9000*'
    assert_called qm 'destroy 9001*'
    [ ! -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-meta.yaml" ]
}

# ---------------------------------------------------------------------------
# destroy / reclone cleanup
# ---------------------------------------------------------------------------

@test "cleanup_clone_snippets removes meta and vendor files" {
    mkdir -p "$SNIPPETS_DIR"
    : > "$SNIPPETS_DIR/runner-9001-meta.yaml"
    : > "$SNIPPETS_DIR/runner-9001-vendor.yaml"
    : > "$SNIPPETS_DIR/runner-9002-vendor.yaml"

    run cleanup_clone_snippets 9001
    [ "$status" -eq 0 ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-meta.yaml" ]
    [ ! -f "$SNIPPETS_DIR/runner-9001-vendor.yaml" ]
    [ -f "$SNIPPETS_DIR/runner-9002-vendor.yaml" ]
}

@test "destroy.sh and reclone.sh clean vendor snippets via cleanup_clone_snippets" {
    grep -q 'cleanup_clone_snippets' "$REPO_ROOT/lib/destroy.sh"
    grep -q 'cleanup_clone_snippets' "$REPO_ROOT/lib/reclone.sh"
    # Both reclone destroy paths (rapid-death deferral and the real destroy)
    # must drop the vendor snippet, otherwise a later occupant of the VMID
    # could inherit gen-N-canary labels.
    local hits
    hits=$(grep -c 'cleanup_clone_snippets' "$REPO_ROOT/lib/reclone.sh")
    [ "$hits" -ge 2 ]
}
