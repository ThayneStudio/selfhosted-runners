#!/usr/bin/env bats
# Host paths must be constants, not literals.
#
# The test harness sandboxes by repointing shell variables, so a literal path
# inside a function body escapes it entirely -- a unit test run on the real
# Proxmox host would then take a real lock or read real config. Spec section 16
# makes this a requirement; this file is what enforces it.

load test_helper

# No setup: these tests only read the repo's own source, so they need neither
# the stub PATH nor a sandbox.

# Directories the platform writes to on a host. /etc/github-runners{,.d} and
# /var/lib/vz/snippets are included: they are just as unsandboxable.
HOST_PATH_RE='"(/run/|/var/lib/|/var/log/|/var/cache/|/etc/pve/|/etc/github-runners)'

@test "no lib script outside common.sh spells a host path as a literal" {
    local offenders=""
    local f
    for f in "$REPO_ROOT"/lib/*.sh; do
        [[ "$(basename "$f")" == "common.sh" ]] && continue
        # Strip comments before matching: a path named in prose is fine, and
        # several comments legitimately explain which path a constant points at.
        local hits
        hits=$(grep -nE "$HOST_PATH_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
        [[ -n "$hits" ]] && offenders+="$(basename "$f"):"$'\n'"$hits"$'\n'
    done
    if [[ -n "$offenders" ]]; then
        printf 'Host paths must be declared in lib/common.sh and referenced by\n' >&2
        printf 'name, so tests/test_helper.bash can sandbox them. Found:\n%s' "$offenders" >&2
        return 1
    fi
}

@test "common.sh declares host paths only in its constants block" {
    # Everything below ensure_state_dir is code; a literal there is the same
    # bug, just in the file that owns the constants.
    local first_fn
    first_fn=$(grep -n '^require_root()' "$REPO_ROOT/lib/common.sh" | head -1 | cut -d: -f1)
    [ -n "$first_fn" ]
    local hits
    hits=$(awk -v start="$first_fn" 'NR >= start' "$REPO_ROOT/lib/common.sh" \
        | grep -nE "$HOST_PATH_RE" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if [[ -n "$hits" ]]; then
        printf 'Literal host path below the constants block in common.sh:\n%s\n' "$hits" >&2
        return 1
    fi
}

@test "sourcing common.sh does not clobber a caller's INSTALL_DIR" {
    # install.sh sets INSTALL_DIR before sourcing us -- it extracts the tarball
    # we come out of -- and reads it back afterwards. An unconditional
    # assignment in common.sh would relocate the installer mid-run.
    run env INSTALL_DIR=/opt/elsewhere bash -c \
        'source "$1/lib/common.sh"; printf "%s" "$INSTALL_DIR"' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/elsewhere" ]
}

@test "common.sh still defaults INSTALL_DIR when the caller sets nothing" {
    run env -u INSTALL_DIR bash -c \
        'source "$1/lib/common.sh"; printf "%s" "$INSTALL_DIR"' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/selfhosted-runners" ]
}
