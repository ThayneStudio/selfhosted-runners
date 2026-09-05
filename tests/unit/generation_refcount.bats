#!/usr/bin/env bats
# generation_refcount counts live VM configs attributed to a generation by
# tag or origin (spec 5). Untagged clones with no origin go to the active
# generation. write_infra_config still defaults MIN_VMID=500, which overlaps
# the generation band, so tests set 9001.
#
# generation_disk_usage (spec 13 / issue #16) reports per-generation storage
# use for the `runner generations` CLI. It has no tag/origin logic of its
# own, so its tests below stub only pvesm list.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    load_lib generations.sh
    MIN_VMID=9001
    TEMPLATE_ID=8901
    write_infra_config
    MIN_VMID=9001
    TEMPLATE_ID=8901
    apply_generation_defaults
}

# Two generations: 5 (superseded, VMID 8900) and 9 (active, VMID 8901).
create_two_gens() {
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
}

stub_template_configs() {
    stub_out qm 'config 8900' <<'EOF'
name: gen-5-template
scsi0: local-zfs:base-8900-disk-0,size=30G
template: 1
tags: runner;gen-5
EOF
    stub_out qm 'config 8901' <<'EOF'
name: gen-9-template
scsi0: local-zfs:base-8901-disk-0,size=30G
template: 1
tags: runner;gen-9
EOF
}

# No linked-clone children: dir/lvm without nested volids, or empty storage.
stub_empty_origin() {
    stub_out pvesm 'list *' <<'EOF'
Volid Format
local-zfs:base-8900-disk-0 raw
local-zfs:base-8901-disk-0 raw
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF
}

qm_list() {
    local body="$1"
    stub_out qm 'list' <<EOF
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      8900 gen-5-template       stopped    8192              30.00 0
      8901 gen-9-template       stopped    8192              30.00 0
$body
EOF
}

@test "generation_refcount counts VMs tagged gen-N and excludes the template" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      9001 acme-1               running    8192              30.00 1234
      9002 acme-2               running    8192              30.00 1235"
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-5
EOF
    stub_out qm 'config 9002' <<'EOF'
name: acme-2
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-9
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run --separate-stderr generation_ref_vmids 5
    [ "$status" -eq 0 ]
    [ "$output" = "9001" ]
    refute_called qm 'destroy *'
    refute_called pvesm 'free *'
}

@test "generation_refcount is zero when no clones exist" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list ""

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "generation_refcount counts an untagged clone via ZFS origin" {
    create_two_gens
    stub_template_configs
    qm_list "      9003 acme-3               running    8192              30.00 1236"
    stub_out qm 'config 9003' <<'EOF'
name: acme-3
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-8900-disk-0                     raw     images     32212254720 8900
local-zfs:base-8901-disk-0                     raw     images     32212254720 8901
local-zfs:vm-9003-disk-0                       raw     images     32212254720 9003
EOF
    stub_out pvesm 'path local-zfs:base-8900-disk-0' <<'EOF'
/dev/zvol/tank/base-8900-disk-0
EOF
    stub_out pvesm 'path local-zfs:base-8901-disk-0' <<'EOF'
/dev/zvol/tank/base-8901-disk-0
EOF
    stub_out pvesm 'path local-zfs:vm-9003-disk-0' <<'EOF'
/dev/zvol/tank/vm-9003-disk-0
EOF
    stub_out zfs 'list -H -o name *' < /dev/null
    stub_out zfs 'get -H -o value origin tank/vm-9003-disk-0' <<'EOF'
tank/base-8900-disk-0@__base__
EOF
    stub_out zfs 'get -H -o value origin tank/base-8900-disk-0' <<'EOF'
-
EOF
    stub_out zfs 'get -H -o value origin tank/base-8901-disk-0' <<'EOF'
-
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "generation_refcount counts an untagged clone via nested volid origin" {
    create_two_gens
    stub_template_configs
    qm_list "      9003 acme-3               running    8192              30.00 1236"
    stub_out qm 'config 9003' <<'EOF'
name: acme-3
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-8900-disk-0                     raw     images     32212254720 8900
local-zfs:base-8901-disk-0                     raw     images     32212254720 8901
local-zfs:base-8900-disk-0/vm-9003-disk-0      raw     images     32212254720 9003
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "untagged clone with no origin is attributed to the active generation with a warning" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      9004 acme-4               running    8192              30.00 1237"
    stub_out qm 'config 9004' <<'EOF'
name: acme-4
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"[WARN]"* ]]
    [[ "$stderr" == *"9004"* ]]
    [[ "$stderr" == *"untagged"* ]]
    [[ "$stderr" == *"active"* ]]
}

# Same shape as above with the per-VM JIT snippet name, which is what every
# clone minted since the token refactor carries. If generation_cfg_is_runner
# stopped recognising it, this VM would read as a non-runner leftover, the
# refcount would drop to 0 and GC would be free to reclaim a generation whose
# clones are still running.
@test "untagged clone with a per-VM JIT snippet is attributed to the active generation" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      9004 acme-4               running    8192              30.00 1237"
    stub_out qm 'config 9004' <<'EOF'
name: acme-4
cicustom: user=local:snippets/runner-9004-user-acme.yaml,meta=local:snippets/runner-9004-meta.yaml
EOF

    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"9004"* ]]
    [[ "$stderr" == *"untagged"* ]]
}

@test "untagged clone with no origin is not counted for a superseded generation" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      9004 acme-4               running    8192              30.00 1237"
    stub_out qm 'config 9004' <<'EOF'
name: acme-4
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    [[ "$stderr" == *"[WARN]"* ]]
    [[ "$stderr" == *"untagged"* ]]
}

@test "a non-runner VM with no tag and no origin is not attributed" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      777 leftover             running    8192              30.00 1"
    stub_out qm 'config 777' <<'EOF'
name: leftover
EOF

    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    [[ "$stderr" != *"untagged"* ]]
}

@test "tag vs origin disagreement warns and counts the VM for both generations" {
    create_two_gens
    stub_template_configs
    qm_list "      9005 acme-5               running    8192              30.00 1238"
    stub_out qm 'config 9005' <<'EOF'
name: acme-5
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-5
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-8900-disk-0                     raw     images     32212254720 8900
local-zfs:base-8901-disk-0                     raw     images     32212254720 8901
local-zfs:base-8901-disk-0/vm-9005-disk-0      raw     images     32212254720 9005
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"[WARN]"* ]]
    [[ "$stderr" == *"disagrees"* ]]
    run --separate-stderr generation_refcount 9
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"disagrees"* ]]
}

@test "two disks on one clone count as one VM" {
    create_two_gens
    stub_template_configs
    qm_list "      9001 acme-1               running    8192              30.00 1234"
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-5
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-8900-disk-0                     raw     images     32212254720 8900
local-zfs:base-8901-disk-0                     raw     images     32212254720 8901
local-zfs:base-8900-disk-0/vm-9001-disk-0      raw     images     32212254720 9001
local-zfs:base-8900-disk-0/vm-9001-disk-1      raw     images     32212254720 9001
EOF
    stub_out pvesm 'path *' <<'EOF'
/dev/dm-3
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "generation_refcount fails closed when linked-clone listing fails" {
    create_two_gens
    stub_template_configs
    stub_status pvesm 'list *' 1
    qm_list "      9001 acme-1               running    8192              30.00 1234"
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
tags: runner;gen-5
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -ne 0 ]
    [ "$output" != "0" ]
    [ "$output" != "1" ]
}

@test "generation_refcount fails closed when qm list fails" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    stub_status qm 'list' 1

    run --separate-stderr generation_refcount 5
    [ "$status" -ne 0 ]
    [ "$output" != "0" ]
}

@test "generation_refcount fails closed when a listed VM config is unreadable" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      9001 acme-1               running    8192              30.00 1234"
    stub_status qm 'config 9001' 2

    run --separate-stderr generation_refcount 5
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"Failed to read config for listed VMID 9001"* ]]
}

@test "generation_refcount fails closed when a possible ZFS clone origin is unreadable" {
    create_two_gens
    stub_template_configs
    qm_list "      9001 acme-1               running    8192              30.00 1234"
    stub_out qm 'config 9001' <<'EOF'
name: acme-1
tags: runner;gen-5
EOF
    stub_out pvesm 'list *' <<'EOF'
Volid Format
local-zfs:base-8900-disk-0 raw
local-zfs:base-8901-disk-0 raw
local-zfs:vm-9001-disk-0 raw
EOF
    stub_out pvesm 'path local-zfs:base-8900-disk-0' <<'EOF'
/dev/zvol/tank/base-8900-disk-0
EOF
    stub_out pvesm 'path local-zfs:base-8901-disk-0' <<'EOF'
/dev/zvol/tank/base-8901-disk-0
EOF
    stub_out pvesm 'path local-zfs:vm-9001-disk-0' <<'EOF'
/dev/zvol/tank/vm-9001-disk-0
EOF
    stub_out zfs 'list -H -o name *' < /dev/null
    stub_status zfs 'get -H -o value origin tank/vm-9001-disk-0' 2

    run --separate-stderr generation_refcount 5
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"Cannot read ZFS origin"* ]]
}

@test "generation_refcount fails for an unknown generation id" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list ""

    run --separate-stderr generation_refcount 99
    [ "$status" -ne 0 ]
}

@test "generation_refcount fails closed on an unreadable generation record" {
    create_two_gens
    printf 'garbage\n' >> "$GENERATIONS_DIR/8900.conf"
    stub_template_configs
    stub_empty_origin
    qm_list ""

    run --separate-stderr generation_refcount 9
    [ "$status" -ne 0 ]
}

@test "a Proxmox template that is not a generation record is not counted" {
    create_two_gens
    stub_template_configs
    stub_empty_origin
    qm_list "      8800 other-template       stopped    8192              30.00 0"
    stub_out qm 'config 8800' <<'EOF'
name: other-template
template: 1
tags: runner;gen-5
EOF

    run --separate-stderr generation_refcount 5
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# The tests below are carried over from the original issue-16 branch, which
# was written against a simpler, tag-only, non-origin-aware generation_refcount
# (predating #17's ZFS/nested-origin cross-check above). They exercise a
# different single/two-generation fixture shape (TEMPLATE_ID 9000) than
# create_two_gens above; kept for that distinct coverage, adapted to the
# current implementation:
#   - each now stubs pvesm (stub_empty_origin) since generation_ref_vmids
#     always attempts origin tracing, even when every VM is already tagged;
#   - the untagged-attribution warning text changed from "missing gen-*" to
#     "untagged ... no resolvable origin" (see generation_ref_vmids).
# ---------------------------------------------------------------------------

make_active() {
    TEMPLATE_ID=9000
    gen_store_init
    gen_create 9000 \
        GEN_ID=1 \
        GEN_STATE=active \
        GEN_RUNNER_VERSION=2.334.0 \
        GEN_TEMPLATE_DIGEST=abc \
        GEN_IMAGE_SHA256=abc \
        GEN_CREATED_AT=2026-08-22T00:00:00Z
}

@test "generation_refcount counts tagged clones and excludes the template VMID" {
    make_active
    stub_empty_origin
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1234
      9002 runner-2             running    8192              30.00 1235
EOF
    stub_out qm 'config 9000' <<'EOF'
name: ubuntu-cloud-template
template: 1
tags: runner;gen-1
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF
    stub_out qm 'config 9002' <<'EOF'
name: runner-2
cicustom: user=local:snippets/runner-user-data-acme.yaml
tags: runner;gen-1
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
    refute_called qm 'set *'
    refute_called qm 'clone *'
    refute_called qm 'destroy *'
}

@test "generation_refcount attributes untagged runners to the active generation and warns" {
    make_active
    stub_empty_origin
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1234
EOF
    stub_out qm 'config 9000' <<'EOF'
name: ubuntu-cloud-template
template: 1
tags: runner;gen-1
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [[ "$stderr" == *"untagged"* ]]
    [[ "$stderr" == *"9001"* ]]
}

@test "generation_refcount does not attribute untagged runners to a superseded generation" {
    TEMPLATE_ID=9000
    gen_store_init
    gen_create 8900 \
        GEN_ID=1 \
        GEN_STATE=superseded \
        GEN_RUNNER_VERSION=2.333.0 \
        GEN_TEMPLATE_DIGEST=old \
        GEN_IMAGE_SHA256=abc \
        GEN_CREATED_AT=2026-08-01T00:00:00Z
    gen_create 9000 \
        GEN_ID=2 \
        GEN_STATE=active \
        GEN_RUNNER_VERSION=2.334.0 \
        GEN_TEMPLATE_DIGEST=new \
        GEN_IMAGE_SHA256=def \
        GEN_CREATED_AT=2026-08-22T00:00:00Z
    stub_empty_origin

    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      8900 github-runner-gen-1  stopped    8192              30.00 0
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      9001 runner-1             running    8192              30.00 1234
EOF
    stub_out qm 'config 8900' <<'EOF'
name: github-runner-gen-1
template: 1
tags: runner;gen-1
EOF
    stub_out qm 'config 9000' <<'EOF'
name: ubuntu-cloud-template
template: 1
tags: runner;gen-2
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run --separate-stderr generation_refcount 2
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "generation_refcount ignores untagged non-runner VMs" {
    make_active
    stub_empty_origin
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9000 ubuntu-cloud-template stopped   8192              30.00 0
      777  other                running    8192              30.00 9
EOF
    stub_out qm 'config 9000' <<'EOF'
name: ubuntu-cloud-template
template: 1
tags: runner;gen-1
EOF
    stub_out qm 'config 777' <<'EOF'
name: other
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    [[ "$stderr" != *"untagged"* ]]
}

# The original (pre-#17) generation_refcount silently reported 0 for an id
# with no matching record at all. The current implementation resolves the id
# via gen_vmid_for_id first and fails closed when it does not exist (see
# "generation_refcount fails for an unknown generation id" above) -- an
# unknown id is now always a hard error, matching "never report 0 on a failed
# listing". The `runner generations` CLI itself does not regress: an empty
# store short-circuits in generations_print_table (gen_list is empty) before
# generation_refcount is ever called, so "no generation records" still
# degrades to "(no generations)" rather than an error.
@test "generation_refcount fails closed when the store has no generation records at all" {
    stub_out qm 'list' <<'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
      9001 runner-1             running    8192              30.00 1234
EOF
    stub_out qm 'config 9001' <<'EOF'
name: runner-1
cicustom: user=local:snippets/runner-user-data-acme.yaml
EOF

    run --separate-stderr generation_refcount 1
    [ "$status" -ne 0 ]
}

@test "generation_refcount refuses a non-numeric id" {
    run --separate-stderr generation_refcount abc
    [ "$status" -eq 1 ]
}

@test "generation_disk_usage reports pvesm Size as GiB" {
    stub_out pvesm 'list local-zfs' <<'EOF'
Volid                                          Format  Type              Size VMID
local-zfs:base-9000-disk-0                     raw     images     32212254720 9000
local-zfs:vm-9001-disk-0                       raw     images     32212254720 9001
EOF

    run generation_disk_usage 9000
    [ "$status" -eq 0 ]
    [ "$output" = "30G" ]
}

@test "generation_disk_usage is dash when pvesm list fails" {
    stub_status pvesm 'list local-zfs' 1

    run generation_disk_usage 9000
    [ "$status" -eq 0 ]
    [ "$output" = "-" ]
}
