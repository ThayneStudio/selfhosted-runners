#!/usr/bin/env bats
# Thin promote: rewrite TEMPLATE_ID, skip-canary confirm, candidate → active.
#
# write_infra_config still defaults MIN_VMID=500, which overlaps the
# generation band, so tests set 9001.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib promote.sh
    MIN_VMID=9001
    TEMPLATE_ID=9000
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=9000
    apply_generation_defaults
    notify() {
        printf '%s\n' "$*" >> "$STUB_DIR/notify.log"
    }
    stub_out qm 'config *' <<'EOF'
template: 1
EOF
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"
}

# What lib/canary.sh stamps on a generation whose canary run concluded
# success, and what --canary-passed checks for.
record_canary_pass() {
    gen_update "$1" \
        GEN_CANARY_ATTEMPTS=1 \
        GEN_CANARY_RUN_URL=https://github.com/acme-org/canary-repo/actions/runs/9911
}

seed_active_and_candidate() {
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=candidate \
        GEN_TEMPLATE_DIGEST=newdigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0
}

@test "lib/promote.sh is syntactically valid" {
    bash -n "$REPO_ROOT/lib/promote.sh"
}

@test "runner dispatches the promote verb" {
    grep -Eq '^[[:space:]]*promote\)' "$REPO_ROOT/runner"
}

@test "rewrite_template_id changes only TEMPLATE_ID and preserves DOCKER_MIRROR_URL" {
    {
        printf 'NETWORK_BRIDGE="vmbr0"\n'
        printf 'VM_STORAGE="local-zfs"\n'
        printf 'TEMPLATE_ID="9000"\n'
        printf 'MIN_VMID="9001"\n'
        printf 'DOCKER_MIRROR_URL="http://mirror.example:8080"\n'
        printf 'VLAN_TAG="20"\n'
    } > "$CONFIG_FILE"

    run rewrite_template_id 8900
    [ "$status" -eq 0 ]

    grep -q '^TEMPLATE_ID="8900"$' "$CONFIG_FILE"
    grep -q 'DOCKER_MIRROR_URL="http://mirror.example:8080"' "$CONFIG_FILE"
    grep -q 'NETWORK_BRIDGE="vmbr0"' "$CONFIG_FILE"
    grep -q 'VM_STORAGE="local-zfs"' "$CONFIG_FILE"
    grep -q 'MIN_VMID="9001"' "$CONFIG_FILE"
    grep -q 'VLAN_TAG="20"' "$CONFIG_FILE"
    ! grep -qE '^TEMPLATE_ID=["'\'']?9000["'\'']?$' "$CONFIG_FILE"
    [ "$(file_mode "$CONFIG_FILE")" = "600" ]
}

@test "rewrite_template_id preserves an unquoted TEMPLATE_ID line" {
    {
        printf 'NETWORK_BRIDGE="vmbr0"\n'
        printf 'VM_STORAGE="local-zfs"\n'
        printf 'TEMPLATE_ID=9000\n'
        printf 'MIN_VMID="9001"\n'
    } > "$CONFIG_FILE"

    run rewrite_template_id 8900
    [ "$status" -eq 0 ]
    grep -q '^TEMPLATE_ID=8900$' "$CONFIG_FILE"
    ! grep -q 'TEMPLATE_ID="8900"' "$CONFIG_FILE"
}

@test "rewrite_template_id preserves a single-quoted TEMPLATE_ID line" {
    {
        printf 'NETWORK_BRIDGE="vmbr0"\n'
        printf 'VM_STORAGE="local-zfs"\n'
        printf "TEMPLATE_ID='9000'\n"
        printf 'MIN_VMID="9001"\n'
        printf 'DOCKER_MIRROR_URL="http://mirror.example:8080"\n'
    } > "$CONFIG_FILE"

    run rewrite_template_id 8900
    [ "$status" -eq 0 ]
    grep -q "^TEMPLATE_ID='8900'$" "$CONFIG_FILE"
    grep -q 'DOCKER_MIRROR_URL="http://mirror.example:8080"' "$CONFIG_FILE"
    ! grep -q "TEMPLATE_ID='9000'" "$CONFIG_FILE"
}

@test "rewrite_template_id fails closed when CONFIG_FILE has no TEMPLATE_ID line" {
    printf 'DOCKER_MIRROR_URL="http://mirror.example:8080"\n' > "$CONFIG_FILE"
    run rewrite_template_id 8900
    [ "$status" -ne 0 ]
    grep -q 'DOCKER_MIRROR_URL="http://mirror.example:8080"' "$CONFIG_FILE"
    ! grep -q 'TEMPLATE_ID=' "$CONFIG_FILE"
}

@test "promote --skip-canary without --yes on a non-tty fails" {
    seed_active_and_candidate

    run --separate-stderr promote_generation 2 --skip-canary </dev/null
    [ "$status" -ne 0 ]

    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
}

@test "promote --skip-canary without --yes refuses a piped y on a non-tty" {
    seed_active_and_candidate

    run --separate-stderr promote_generation 2 --skip-canary <<<'y'
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
}

@test "promote lock timeout notifies warn and does not rewrite TEMPLATE_ID" {
    seed_active_and_candidate
    PROMOTE_LOCK_WAIT_SECONDS=0
    mkdir -p "$(dirname "$POOL_ACTIVITY_LOCK_FILE")"
    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    flock -n -x 202

    run --separate-stderr promote_generation 2 --skip-canary --yes
    [ "$status" -ne 0 ]
    grep -q 'warn promote.timeout' "$STUB_DIR/notify.log"
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
}

@test "promote lock wait defaults to 120 seconds" {
    grep -q 'PROMOTE_LOCK_WAIT_SECONDS:-120' "$REPO_ROOT/lib/promote.sh"
}

@test "promote lock-timeout notify runs after pause is released" {
    awk '
        /Timed out waiting for the pool activity lock/ { t = NR }
        t && /_promote_release/ && !r { r = NR }
        t && /notify warn promote.timeout/ { n = NR }
        END {
            if (!t || !r || !n) exit 1
            if (!(r < n)) exit 1
        }
    ' "$REPO_ROOT/lib/promote.sh"
}

@test "promote --skip-canary --yes moves candidate to active and previous active to superseded" {
    seed_active_and_candidate

    run --separate-stderr promote_generation 2 --skip-canary --yes
    [ "$status" -eq 0 ]

    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    [ -n "$GEN_PROMOTED_AT" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
    [ -n "$GEN_SUPERSEDED_AT" ]
    [ ! -e "$PROMOTION_PAUSE_FILE" ]

    grep -q 'generation.promoted' "$STUB_DIR/notify.log"
}

@test "promote does not leave TEMPLATE_ID pointing at the old VMID" {
    seed_active_and_candidate
    printf 'DOCKER_MIRROR_URL="http://mirror.example:8080"\n' >> "$CONFIG_FILE"

    run --separate-stderr promote_generation 2 --skip-canary --yes
    [ "$status" -eq 0 ]

    grep -qE '^TEMPLATE_ID=["'\'']?8900["'\'']?$' "$CONFIG_FILE"
    ! grep -qE '^TEMPLATE_ID=["'\'']?9000["'\'']?$' "$CONFIG_FILE"
    grep -q 'DOCKER_MIRROR_URL="http://mirror.example:8080"' "$CONFIG_FILE"

    run --separate-stderr reload_active_template_id
    [ "$status" -eq 0 ]
    [ "$output" = "8900" ]
}

@test "promote of an already-active generation is a no-op success" {
    seed_active_and_candidate

    run --separate-stderr promote_generation 1 --skip-canary --yes
    [ "$status" -eq 0 ]

    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'generation.promoted' "$STUB_DIR/notify.log"
}

@test "promote of already-active generation with stale TEMPLATE_ID rewrites the pointer" {
    # Crash after gen_transition active but before rewrite_template_id: both
    # records are active, pointer still names the old VMID. Retry must not
    # no-op — clones would keep the old image, and maintain would demote N.
    gen_store_init
    gen_create 8900 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=newdigest \
        GEN_IMAGE_SHA256=def \
        GEN_RUNNER_VERSION=2.336.0
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_TEMPLATE_DIGEST=olddigest \
        GEN_IMAGE_SHA256=abc \
        GEN_RUNNER_VERSION=2.335.0

    run --separate-stderr promote_generation 2 --skip-canary --yes
    [ "$status" -eq 0 ]

    grep -qE '^TEMPLATE_ID=["'\'']?8900["'\'']?$' "$CONFIG_FILE"
    ! grep -qE '^TEMPLATE_ID=["'\'']?9000["'\'']?$' "$CONFIG_FILE"
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
}

@test "promote fails closed when gen_list active cannot be read" {
    seed_active_and_candidate
    printf 'garbage\n' >> "$GENERATIONS_DIR/9000.conf"

    run --separate-stderr promote_generation 2 --skip-canary --yes
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
}

@test "promote refuses a non-candidate generation" {
    gen_store_init
    gen_create 8900 GEN_ID=2 GEN_STATE=baking

    run --separate-stderr promote_generation 2 --skip-canary --yes
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "baking" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
}

@test "promote refuses a VMID that is not a Proxmox template" {
    seed_active_and_candidate
    stub_out qm 'config *' <<'EOF'
name: leftover-bake
ostype: l26
EOF

    run --separate-stderr promote_generation 2 --skip-canary --yes
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a template"* ]]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
    [ ! -f "$STUB_DIR/notify.log" ] || ! grep -q 'generation.promoted' "$STUB_DIR/notify.log"
}

@test "promote_generation traps EXIT to clear PROMOTION_PAUSE_FILE before flock waits" {
    # Write pause, then trap EXIT only, then exclusive flock. INT/TERM must
    # not be in this trap: a handler that returns lets promote continue with
    # pause and lock already dropped. SIGINT/SIGTERM abort the process and
    # still run EXIT. Proven against source order because a live SIGINT
    # during flock -w 120 is too slow/flaky for the suite.
    awk '
        /exec 211>"\$PROMOTION_PAUSE_FILE"/ { pause = NR }
        /trap '\''_promote_release'\'' EXIT[[:space:]]*$/ { trapline = NR }
        /flock -w .* -x 202/ { flock = NR }
        END {
            if (!pause || !trapline || !flock) exit 1
            if (!(pause < trapline && trapline < flock)) exit 1
        }
    ' "$REPO_ROOT/lib/promote.sh"
}

@test "_promote_release clears the EXIT trap" {
    # A leftover EXIT trap would re-run _promote_release when the process
    # later exits (setup after bootstrap promote, or bats run subshell).
    grep -A8 '^_promote_release()' "$REPO_ROOT/lib/promote.sh" \
        | grep -qE "^[[:space:]]*trap - EXIT[[:space:]]*$"
}

# The canary gate (#22) is the other way into promotion: it has just watched a
# real job succeed on this image, so there is nothing left to confirm.
@test "promote without a canary tells the operator to run the gate" {
    seed_active_and_candidate

    run --separate-stderr promote_generation 2 </dev/null
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"runner canary 2"* ]]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
}

# --canary-passed skips both the canary requirement and the confirmation, so
# it has to be backed by evidence rather than by the caller's word: the gate
# stamps GEN_CANARY_RUN_URL and GEN_CANARY_ATTEMPTS on the record before it
# promotes (lib/canary.sh), and this refuses the flag without them.
@test "promote --canary-passed refuses a generation with no recorded canary run" {
    seed_active_and_candidate

    run --separate-stderr promote_generation 2 --canary-passed </dev/null
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"no canary evidence"* ]]
    [[ "$stderr" == *"runner canary 2"* ]]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
    gen_read 9000
    [ "$GEN_STATE" = "active" ]
    grep -q 'TEMPLATE_ID="9000"' "$CONFIG_FILE"
    [ ! -e "$PROMOTION_PAUSE_FILE" ]
}

@test "promote --canary-passed refuses a run URL with no attempt recorded" {
    seed_active_and_candidate
    gen_update 8900 GEN_CANARY_RUN_URL=https://github.com/o/r/actions/runs/1

    run --separate-stderr promote_generation 2 --canary-passed </dev/null
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
}

@test "promote --canary-passed refuses an attempt with no run URL" {
    seed_active_and_candidate
    gen_update 8900 GEN_CANARY_ATTEMPTS=1

    run --separate-stderr promote_generation 2 --canary-passed </dev/null
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "candidate" ]
}

@test "promote --canary-passed notifies that a canary, not a human, cleared it" {
    seed_active_and_candidate
    record_canary_pass 8900

    run --separate-stderr promote_generation 2 --canary-passed </dev/null
    [ "$status" -eq 0 ]
    grep -q 'info promote.canary_passed' "$STUB_DIR/notify.log"
    grep -q 'runs/9911' "$STUB_DIR/notify.log"
}

@test "promote --canary-passed promotes without a tty confirmation" {
    seed_active_and_candidate
    record_canary_pass 8900

    run --separate-stderr promote_generation 2 --canary-passed </dev/null
    [ "$status" -eq 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "active" ]
    gen_read 9000
    [ "$GEN_STATE" = "superseded" ]
    grep -qE '^TEMPLATE_ID=["'\'']?8900["'\'']?$' "$CONFIG_FILE"
    grep -q 'generation.promoted' "$STUB_DIR/notify.log"
}

@test "promote --canary-passed still refuses a non-candidate generation" {
    gen_store_init
    gen_create 8900 GEN_ID=2 GEN_STATE=baking
    record_canary_pass 8900

    run --separate-stderr promote_generation 2 --canary-passed </dev/null
    [ "$status" -ne 0 ]
    gen_read 8900
    [ "$GEN_STATE" = "baking" ]
}
