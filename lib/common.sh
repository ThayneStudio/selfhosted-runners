#!/bin/bash
set -euo pipefail
# Common functions and constants shared across all runner scripts

# Sourcing twice in one process is a no-op. In production nothing does that —
# every `runner` subcommand is its own process — so this guard never fires on
# the host. The unit harness relies on it: it sources this file, repoints the
# host paths below at a sandbox, and then sources a lib script that would
# otherwise re-source this file and reset them to the real /etc and /run.
# Demonstrated by "sourcing a lib script keeps the sandbox in force" in
# tests/unit/harness_smoke.bats.
if [[ -n "${RUNNER_COMMON_LOADED:-}" ]]; then
    return 0
fi
RUNNER_COMMON_LOADED=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
# shellcheck disable=SC2034  # consumed by sourcing scripts (lib/list-orgs.sh)
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1" >&2; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2; }

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC2034  # consumed by sourcing scripts (lib/setup.sh)
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"

# Path constants. Every host path the scripts touch belongs here rather than
# inline: the unit harness repoints these at a sandbox, and a literal path in
# a lib script would take a real lock or read real config during a test run.
CONFIG_FILE="/etc/github-runners.conf"
ORG_CONFIG_DIR="/etc/github-runners.d"
# Where Proxmox keeps per-VM configs; the node name is a wildcard.
PVE_NODES_DIR="/etc/pve/nodes"
SNIPPETS_DIR="/var/lib/vz/snippets"
# Honours a value already set by the caller. install.sh sets this BEFORE it
# sources us -- it has to, since it uses it to extract the tarball we come out
# of -- and everything it does afterwards reads it back. An unconditional
# assignment here would silently relocate the installer mid-run the moment
# anyone made its INSTALL_DIR overridable.
# shellcheck disable=SC2034  # consumed by sourcing scripts (lib/setup.sh, lib/add-org.sh)
INSTALL_DIR="${INSTALL_DIR:-/opt/selfhosted-runners}"
# Persistent platform state, as opposed to the /run/lock files below, which are
# tmpfs and clear on reboot. This is the ONLY place the directory is spelled:
# everything persistent derives from it, so relocating the platform's state is a
# one-line change. Overridable only so unit tests can point at a temp directory;
# production always uses the default.
RUNNER_STATE_DIR="${RUNNER_STATE_DIR:-/var/lib/github-runners}"
GENERATIONS_DIR="${GENERATIONS_DIR:-$RUNNER_STATE_DIR/generations}"
# Optional last-sent notification line, written by notify if it ever records one.
# status reads this; it never creates it.
# shellcheck disable=SC2034  # consumed by lib/status.sh
LAST_NOTIFY_FILE="$RUNNER_STATE_DIR/last-notify"
# One mode for everything under RUNNER_STATE_DIR. `install -d -m` re-applies the
# mode to an existing directory, so two callers disagreeing about it would flip
# the permissions depending on which ran last.
STATE_DIR_MODE=700

# Maintenance flag. Lives under RUNNER_STATE_DIR so it survives a host reboot:
# the watcher timer stays enabled across a reboot, so a tmpfs flag meant
# rebooting between `runner stop` and `runner start` silently resumed runner
# creation.
POOL_DRAIN_FILE="$RUNNER_STATE_DIR/drain"
# Pre-upgrade tmpfs location. Read so upgrading mid-maintenance does not drop an
# active drain, and still written so a rollback to a release that only knows this
# path can both see and clear the drain. install.sh migrates it to the
# persistent path on upgrade; disable_pool_drain clears both.
POOL_DRAIN_FILE_LEGACY="${POOL_DRAIN_FILE_LEGACY:-/run/lock/github-runner-drain}"

# Where the lifetime guard records when it first saw a VM stopped. A stopped VM
# reports no uptime, so the observation has to come from the host. Per-boot
# state on purpose, unlike the rest of the platform's state: a reboot makes
# every VM freshly observed, which is exactly what it is.
# shellcheck disable=SC2034  # consumed by lib/guard.sh via this shared file
GUARD_STATE_DIR="/run/github-runner-guard"
# Shared/exclusive lock coordinating maintenance mode with in-flight clones.
# clone_runner holds a shared lock for its full lifecycle; runner stop takes an
# exclusive lock so it can wait until all clone activity is quiesced.
POOL_ACTIVITY_LOCK_FILE="/run/lock/github-runner-pool.lock"
# Linearizes maintenance entry with rollover's destructive transaction without
# putting network waits under the clone/promotion pool lock.
POOL_DRAIN_COORD_LOCK_FILE="/run/lock/github-runner-drain-coord.lock"
# Global lock serializing VMID allocation across reclone.sh/watch.sh/create.sh.
# Scope is narrow: "pick free VMID -> reserve it". A per-VMID reservation
# stays held until qm clone returns, so clone tasks can run with bounded
# parallelism without racing on the same VMID.
# pvesh get /cluster/nextid is not atomic and does not reserve, so without
# this lock two parallel clones reliably pick the same VMID.
VMID_LOCK_FILE="/run/lock/runner-vmid.lock"
VMID_RESERVATION_LOCK_PREFIX="/run/lock/runner-vmid-reserve"
CLONE_SLOT_LOCK_PREFIX="/run/lock/runner-clone-slot"
# Per-slot lock keeping lib/reclone.sh, lib/watch.sh and lib/guard.sh off the
# same runner name. reclone/watch hold it across a clone; the guard holds it
# around a single destroy. One definition on purpose: if these drifted apart the
# guard would stop coordinating with the clone path and destroy mid-clone.
# shellcheck disable=SC2034  # consumed by sourcing scripts (reclone.sh, watch.sh, guard.sh)
RUNNER_SLOT_LOCK_PREFIX="/run/lock/runner"
# Serializes capacity decisions and destruction within one organization.
# shellcheck disable=SC2034  # consumed by lib/rollover.sh
ROLLOVER_ORG_LOCK_PREFIX="/run/lock/github-runner-rollover-org"
ROLLOVER_PENDING_DIR="$RUNNER_STATE_DIR/rollover-pending"
# Per-slot reclone bookkeeping (last-processed timestamp, rapid-death streak).
# shellcheck disable=SC2034  # consumed by sourcing scripts (lib/reclone.sh)
RECLONE_STATE_PREFIX="/run/runner"
# Where watch.sh's parallel workers pool their clone failures so the run sends
# one notification instead of one per slot. Per-run: the PID is appended.
# shellcheck disable=SC2034  # consumed by sourcing scripts (lib/watch.sh)
WATCH_FAILURE_LIST_PREFIX="/run/github-runner-watch-failures"
DEFAULT_CLONE_MAX_PARALLEL=2
# Host-side termination guard (lib/guard.sh). The lifetime ceiling sits above
# the guest's own 6h `shutdown -h +360` so the cooperative path normally wins.
# shellcheck disable=SC2034  # consumed by lib/guard.sh and lib/setup.sh
DEFAULT_MAX_VM_LIFETIME_HOURS=8
# shellcheck disable=SC2034  # consumed by lib/guard.sh and lib/setup.sh
DEFAULT_STOPPED_REAP_MINUTES=10
# shellcheck disable=SC2034  # consumed by lib/setup.sh; empty = exclude nothing
DEFAULT_GUARD_EXCLUDE_VMIDS=""
# Floor under the guard's structural freshness check. A VM whose config was
# written this recently may be a clone still in flight, so it is never reaped —
# this is what lets the guard skip the global pool lock entirely.
# shellcheck disable=SC2034  # consumed by lib/guard.sh via this shared file
GUARD_MIN_CONFIG_AGE_SECONDS=60
# Consecutive runs a VM may be deferred on a busy slot lock before the guard
# stops treating it as normal churn and says so.
# shellcheck disable=SC2034  # consumed by lib/guard.sh via this shared file
GUARD_DEFER_WARN_RUNS=3

# Bake / maintain host paths and cloud-image identity. Lock and cache paths
# are absolute so the unit harness sandboxes them by value. Persistent files
# hang off RUNNER_STATE_DIR so relocating state relocates them too.
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
BAKE_LOCK_FILE="/run/lock/github-runner-bake.lock"
# Serializes manual and timer-driven garbage collection runs. GC makes several
# decisions from one generation snapshot; overlapping runs must not both try to
# destroy and archive the same record.
# shellcheck disable=SC2034  # consumed by lib/gc.sh
GC_LOCK_FILE="/run/lock/github-runner-gc.lock"
# shellcheck disable=SC2034  # consumed by bake, detect, promote, rollback, maintain
PROMOTION_PAUSE_FILE="/run/lock/github-runner-promote.pause"
IMG_CACHE_DIR="/var/cache/github-runners"
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
BAKE_LOG_DIR="/var/log/github-runners"
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
FAILED_DIGESTS_FILE="$RUNNER_STATE_DIR/failed-digests"
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
DETECT_FAIL_FILE="$RUNNER_STATE_DIR/detect-fail"
# Consecutive GitHub API failures for the drift alarm (lib/drift.sh).
# shellcheck disable=SC2034
DRIFT_FAIL_FILE="$RUNNER_STATE_DIR/drift-fail"
CLOUD_IMG="noble-server-cloudimg-amd64.img"
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/${CLOUD_IMG}"
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
CLOUD_IMG_CHECKSUM_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
CLOUD_IMG_PATH="$IMG_CACHE_DIR/$CLOUD_IMG"
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
MIN_CLOUD_IMG_BYTES=$((400 * 1024 * 1024))
# shellcheck disable=SC2034  # consumed by bake, detect, promote, maintain
GENERATION_VMID_LOCK_FILE="/run/lock/github-runner-gen-vmid.lock"
# Host unit/logrotate directories. Overridable so tests can sandbox them.
# shellcheck disable=SC2034
SYSTEMD_UNIT_DIR="/etc/systemd/system"
# shellcheck disable=SC2034
LOGROTATE_DIR="/etc/logrotate.d"

# Webhook notifications. Sourced here so every script that already sources
# common.sh can call `notify` (and `redact_secrets`) without extra wiring.
#
# Guarded, and tolerant of a source that fails halfway: install.sh unpacks the
# tarball file by file, so there is a window where this file exists and
# notify.sh does not, or exists half-written. Everything that sources common.sh
# in that window — including the hookscript's drain check, which fails *open*
# and re-clones during maintenance if it cannot source us — would otherwise
# break. A library whose whole premise is "never break the caller" does not get
# to take the CLI down on its way in. Both fallbacks degrade to silence rather
# than to leaking: notify does nothing, redact_secrets withholds.
if [[ -r "$LIB_DIR/notify.sh" ]]; then
    # shellcheck source=notify.sh
    source "$LIB_DIR/notify.sh" || true
fi
if ! declare -F notify >/dev/null 2>&1; then
    notify() { :; }
fi
if ! declare -F redact_secrets >/dev/null 2>&1; then
    redact_secrets() { printf '%s' "[REDACTION UNAVAILABLE]"; }
fi

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command must be run as root"
        echo "Try: sudo runner ${1:-}" >&2
        exit 1
    fi
}

validate_org_name() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

load_infra_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration not found at $CONFIG_FILE"
        log_error "Run 'runner setup' first."
        exit 1
    fi
    # shellcheck source=/dev/null  # host config, written by setup at runtime
    source "$CONFIG_FILE"
    for var in NETWORK_BRIDGE VM_STORAGE TEMPLATE_ID; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Missing required config variable: $var"
            exit 1
        fi
    done
    apply_generation_defaults
    validate_generation_band
}

# Generation-model settings (spec 14). Defaulting them here rather than writing
# them into /etc/github-runners.conf keeps the upgrade a no-op: an existing
# config file stays valid and unedited, and an operator only adds a key to
# override it.
# Unsigned integer: empty → default; set but not a uint → log_warn and default.
_generation_uint_or_default() {
    local var="$1" default="$2" value
    value="${!var:-}"
    if [[ -z "$value" ]]; then
        printf -v "$var" '%s' "$default"
        return 0
    fi
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_warn "Invalid $var='$value' — falling back to default $default"
        printf -v "$var" '%s' "$default"
    fi
}

# Boolean: empty → default; case-normalize true/false; unrecognized → default.
_generation_bool_or_default() {
    local var="$1" default="$2" raw folded
    raw="${!var:-}"
    if [[ -z "$raw" ]]; then
        printf -v "$var" '%s' "$default"
        return 0
    fi
    folded=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$folded" in
        true|false)
            printf -v "$var" '%s' "$folded"
            ;;
        *)
            log_warn "Invalid $var='$raw' — falling back to default $default"
            printf -v "$var" '%s' "$default"
            ;;
    esac
}

apply_generation_defaults() {
    _generation_uint_or_default TEMPLATE_BAND_MIN 8900
    _generation_uint_or_default TEMPLATE_BAND_MAX 8999
    _generation_uint_or_default GENERATION_RETAIN 1
    _generation_uint_or_default FAILED_GEN_RETAIN_DAYS 7
    _generation_uint_or_default GC_STUCK_WARN_HOURS 12
    _generation_uint_or_default CANDIDATE_MAX_AGE_DAYS 3
    _generation_bool_or_default REBAKE_ENABLED true
    _generation_uint_or_default REBAKE_MAX_AGE_DAYS 7
    # Invalid REBAKE_WINDOW is left for in_rebake_window (fail-closed).
    REBAKE_WINDOW="${REBAKE_WINDOW:-02:00-06:00}"
    _generation_uint_or_default BAKE_TIMEOUT 5400
    _generation_uint_or_default BAKE_MIN_FREE_GB 60
    _generation_bool_or_default CANARY_ENABLED false
    _generation_uint_or_default DETECT_FAIL_WARN_HOURS 24
}

validate_generation_band() {
    local min_vmid="${MIN_VMID:-0}"
    local band_min="${TEMPLATE_BAND_MIN}"
    local band_max="${TEMPLATE_BAND_MAX}"

    if [[ ! "$band_min" =~ ^[0-9]+$ || ! "$band_max" =~ ^[0-9]+$ ]]; then
        log_error "TEMPLATE_BAND_MIN/MAX must be unsigned integers (got ${band_min:-<empty>}, ${band_max:-<empty>})"
        return 1
    fi
    if [[ ! "$min_vmid" =~ ^[0-9]+$ ]]; then
        log_error "MIN_VMID must be an unsigned integer (got ${min_vmid:-<empty>})"
        return 1
    fi
    if [[ "$band_min" -gt "$band_max" ]]; then
        log_error "TEMPLATE_BAND_MIN ($band_min) is greater than TEMPLATE_BAND_MAX ($band_max)"
        return 1
    fi
    if [[ "$min_vmid" -eq 0 ]]; then
        log_error "MIN_VMID=0 (auto) is incompatible with generations; set MIN_VMID to $((band_max + 1)) or higher"
        return 1
    fi
    if [[ "$band_max" -ge "$min_vmid" ]]; then
        log_error "Generation VMID band ${band_min}-${band_max} overlaps [MIN_VMID, ∞) (MIN_VMID=${min_vmid})"
        return 1
    fi
    return 0
}

# Replace only the TEMPLATE_ID= line in $CONFIG_FILE. Every other key, including
# DOCKER_MIRROR_URL, is left byte-for-byte. Fail closed if the line is missing
# so a truncated config cannot silently drop the pointer.
# Proven by "rewrite_template_id changes only TEMPLATE_ID and preserves DOCKER_MIRROR_URL"
# and "rewrite_template_id fails closed when CONFIG_FILE has no TEMPLATE_ID line".
rewrite_template_id() {
    local vmid="${1:-}" tmp

    if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
        log_error "rewrite_template_id: invalid VMID: ${vmid:-<empty>}"
        return 1
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "rewrite_template_id: $CONFIG_FILE not found"
        return 1
    fi
    if ! grep -q '^TEMPLATE_ID=' "$CONFIG_FILE"; then
        log_error "rewrite_template_id: $CONFIG_FILE has no TEMPLATE_ID= line"
        return 1
    fi

    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
    if ! awk -v vmid="$vmid" '
        BEGIN { found = 0 }
        /^TEMPLATE_ID="/ { print "TEMPLATE_ID=\"" vmid "\""; found = 1; next }
        /^TEMPLATE_ID='\''/ { print "TEMPLATE_ID='\''" vmid "'\''"; found = 1; next }
        /^TEMPLATE_ID=/ { print "TEMPLATE_ID=" vmid; found = 1; next }
        { print }
        END { if (!found) exit 1 }
    ' "$CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        log_error "rewrite_template_id: failed to rewrite TEMPLATE_ID in $CONFIG_FILE"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }
}

# Source $CONFIG_FILE in a subshell and print TEMPLATE_ID. clone_runner uses
# this after taking the shared pool lock so a promotion is visible before
# qm clone. Proven by "clone_runner re-reads TEMPLATE_ID after the shared lock".
reload_active_template_id() {
    local value

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "reload_active_template_id: $CONFIG_FILE not found"
        return 1
    fi
    value="$(
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        printf '%s' "${TEMPLATE_ID:-}"
    )" || {
        log_error "reload_active_template_id: failed to source $CONFIG_FILE"
        return 1
    }
    if [[ -z "$value" ]]; then
        log_error "reload_active_template_id: TEMPLATE_ID is empty in $CONFIG_FILE"
        return 1
    fi
    printf '%s\n' "$value"
}

load_org_config() {
    local org_name="$1"
    if ! validate_org_name "$org_name"; then
        log_error "Invalid organization name: $org_name"
        exit 1
    fi
    local org_file="$ORG_CONFIG_DIR/${org_name}.conf"
    if [[ ! -f "$org_file" ]]; then
        log_error "Organization '$org_name' not configured. Run 'runner add-org'."
        exit 1
    fi
    # shellcheck source=/dev/null  # per-org config, written by add-org at runtime
    source "$org_file"
    if [[ -z "${GITHUB_ORG:-}" || -z "${GITHUB_PAT:-}" ]]; then
        log_error "Invalid org config for '$org_name' — missing GITHUB_ORG or GITHUB_PAT"
        exit 1
    fi
}

pool_is_draining() {
    [[ -e "$POOL_DRAIN_FILE" || -e "$POOL_DRAIN_FILE_LEGACY" ]]
}

# Create a directory under RUNNER_STATE_DIR at the one mode the platform uses.
# Every persistent-state creator goes through here so the mode cannot drift.
ensure_state_dir() {
    install -d -m "$STATE_DIR_MODE" "${1:-$RUNNER_STATE_DIR}"
}

enable_pool_drain() {
    exec 212>"$POOL_DRAIN_COORD_LOCK_FILE"
    flock -x 212
    local state_dir
    state_dir="$(dirname "$POOL_DRAIN_FILE")"

    # This writes the root filesystem, not tmpfs, so it can genuinely fail on a
    # full host. Say so — the caller aborts before stopping the watcher, and a
    # bare `install:` error would leave the operator thinking the pool is
    # drained when the watcher is still cloning.
    if ! ensure_state_dir "$state_dir"; then
        log_error "Failed to create $state_dir — maintenance mode NOT entered"
        exec 212>&-
        return 1
    fi
    if ! : > "$POOL_DRAIN_FILE"; then
        log_error "Failed to write $POOL_DRAIN_FILE — maintenance mode NOT entered"
        exec 212>&-
        return 1
    fi

    # Write the legacy path too so every version ordering agrees on the drain:
    # a rollback to a release that only knows the tmpfs path can still see this
    # drain and still clear it. Best effort — the persistent flag above is the
    # authoritative one.
    if ! : > "$POOL_DRAIN_FILE_LEGACY" 2>/dev/null; then
        log_warn "Could not write $POOL_DRAIN_FILE_LEGACY — a rollback to an older release would not see this drain"
    fi
    exec 212>&-
}

disable_pool_drain() {
    # The legacy flag must go too — a drain set before the upgrade would
    # otherwise survive `runner start` with nothing left to clear it.
    rm -f "$POOL_DRAIN_FILE" "$POOL_DRAIN_FILE_LEGACY"
}

list_orgs() {
    if [[ -d "$ORG_CONFIG_DIR" ]]; then
        for f in "$ORG_CONFIG_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            basename "$f" .conf
        done
    fi
}

select_org() {
    local org_flag="${1:-}"
    local orgs
    mapfile -t orgs < <(list_orgs)

    if [[ ${#orgs[@]} -eq 0 ]]; then
        log_error "No organizations configured. Run 'runner add-org'."
        exit 1
    fi

    if [[ -n "$org_flag" ]]; then
        if ! validate_org_name "$org_flag"; then
            log_error "Invalid organization name: $org_flag"
            exit 1
        fi
        if [[ ! -f "$ORG_CONFIG_DIR/${org_flag}.conf" ]]; then
            log_error "Organization '$org_flag' not configured"
            exit 1
        fi
        echo "$org_flag"
        return
    fi

    if [[ ${#orgs[@]} -eq 1 ]]; then
        echo "${orgs[0]}"
        return
    fi

    echo "" >&2
    echo "Multiple organizations configured:" >&2
    for i in "${!orgs[@]}"; do
        echo "  $((i + 1))) ${orgs[$i]}" >&2
    done
    echo "" >&2

    while true; do
        echo -n "Select organization (number or name): " >&2
        read -r choice </dev/tty || { log_error "No input"; exit 1; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#orgs[@]} ]]; then
            echo "${orgs[$((choice - 1))]}"
            return
        fi
        for org in "${orgs[@]}"; do
            [[ "$org" == "$choice" ]] && { echo "$choice"; return; }
        done
        log_error "Invalid selection: $choice"
    done
}

# Org named by a runner VM's cloud-init snippet, given a `qm config` body or
# just its cicustom line. Single source of truth for the snippet naming, because
# rollover and the generation inventory have to recognise the same VMs this does.
#
# New per-VM snippet: runner-<vmid>-user-<org>.yaml (org has no dots).
# Legacy per-org snippet: runner-user-data-<org>.yaml (kept as a fallback so
# VMs created before the token refactor stay identifiable/destroyable).
# The two are mutually exclusive: legacy names have no digits after "runner-".
# Prints the org; returns 1 when the config names neither snippet.
org_from_vm_config() {
    local cfg="${1:-}"
    if [[ "$cfg" =~ runner-[0-9]+-user-([a-zA-Z0-9-]+)\.yaml ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$cfg" =~ runner-user-data-([^.]+)\.yaml ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

get_vm_org() {
    local cicustom org
    cicustom=$(qm config "$1" 2>/dev/null | grep "^cicustom:" || true)
    org=$(org_from_vm_config "$cicustom") || org="unknown"
    echo "$org"
}

# GEN_ID encoded in a Proxmox tags value (`runner;gen-5` or `runner,gen-5`).
# First well-formed gen-<digits> tag wins. Proven by
# "get_vm_generation reads gen-N from semicolon-separated tags" and
# "get_vm_generation ignores a gen- prefix that is not a generation id".
generation_id_from_tags() {
    local current="${1:-}" tag id
    local -a tags=()

    current="${current#tags:}"
    current="${current%$'\r'}"
    IFS=';,' read -ra tags <<< "$current"
    for tag in "${tags[@]}"; do
        tag="${tag//[[:space:]]/}"
        [[ -n "$tag" ]] || continue
        if [[ "$tag" =~ ^gen-([0-9]+)$ ]]; then
            id="${BASH_REMATCH[1]}"
            # Same bound as gen_is_uint: keep the value inside arithmetic.
            [[ ${#id} -le 18 ]] || continue
            printf '%s\n' "$((10#$id))"
            return 0
        fi
    done
    return 1
}

# GEN_ID from a VM's `tags:` line in `qm config`. Uniform across storage
# backends; the ZFS origin cross-check lives in generation_refcount.
# Proven by "get_vm_generation reads gen-N from semicolon-separated tags".
get_vm_generation() {
    local vmid="${1:-}" cfg tags_line

    [[ -n "$vmid" ]] || return 1
    cfg=$(qm config "$vmid" 2>/dev/null) || return 1
    tags_line=$(grep -m1 '^tags:' <<< "$cfg" || true)
    generation_id_from_tags "$tags_line"
}

vm_config_path() {
    local vmid="$1"
    compgen -G "$PVE_NODES_DIR/*/qemu-server/${vmid}.conf" | head -n 1
}

vmid_in_use() {
    [[ -n "$(vm_config_path "$1")" ]]
}

vmid_reservation_lock_file() {
    printf '%s-%s.lock\n' "$VMID_RESERVATION_LOCK_PREFIX" "$1"
}

reserve_vmid() {
    local vmid="${1:-}"
    local lock_file

    if [[ -z "$vmid" ]]; then
        if [[ "${MIN_VMID:-0}" -gt 0 ]]; then
            vmid="$MIN_VMID"
        else
            vmid=$(pvesh get /cluster/nextid) || return 1
        fi
    fi

    while true; do
        if vmid_in_use "$vmid"; then
            vmid=$((vmid + 1))
            continue
        fi

        lock_file=$(vmid_reservation_lock_file "$vmid")
        exec 203>"$lock_file"
        if flock -n 203; then
            if vmid_in_use "$vmid"; then
                exec 203>&-
                vmid=$((vmid + 1))
                continue
            fi
            RESERVED_VMID="$vmid"
            return 0
        fi
        exec 203>&-
        vmid=$((vmid + 1))
    done
}

release_vmid_reservation() {
    local vmid="${1:-${RESERVED_VMID:-}}"
    exec 203>&- 2>/dev/null || true
    [[ -n "$vmid" ]] && rm -f "$(vmid_reservation_lock_file "$vmid")" 2>/dev/null || true
}

clone_max_parallel() {
    local max="${CLONE_MAX_PARALLEL:-$DEFAULT_CLONE_MAX_PARALLEL}"
    if [[ ! "$max" =~ ^[0-9]+$ || "$max" -lt 1 ]]; then
        max="$DEFAULT_CLONE_MAX_PARALLEL"
    fi
    echo "$max"
}

acquire_clone_slot() {
    local max slot
    max=$(clone_max_parallel)

    while true; do
        pool_is_draining && return 1
        [[ -e "$PROMOTION_PAUSE_FILE" ]] && return 3
        for ((slot = 1; slot <= max; slot++)); do
            exec 204>"${CLONE_SLOT_LOCK_PREFIX}-${slot}.lock"
            if flock -n 204; then
                return 0
            fi
            exec 204>&-
        done
        sleep 1
    done
}

release_clone_slot() {
    exec 204>&- 2>/dev/null || true
}

# Base volume ids of a template VM. Defaults to the active TEMPLATE_ID so
# existing GC callers stay unchanged; generation_refcount passes a generation
# VMID to cross-check origin against a superseded template.
list_template_base_volids() {
    local vmid="${1:-$TEMPLATE_ID}"
    local config bases storage_list config_path

    if config=$(qm config "$vmid" 2>/dev/null); then
        bases=$(awk -F': ' -v storage="$VM_STORAGE:" '
            $1 ~ /^(ide|sata|scsi|virtio)[0-9]+$/ {
                split($2, parts, ",")
                if (index(parts[1], storage "base-") == 1) {
                    print parts[1]
                }
            }
        ' <<< "$config")
        if [[ -n "$bases" ]]; then
            printf '%s\n' "$bases"
            return 0
        fi
        # The config was read positively. A diskless/non-base config has no
        # linked-clone ancestry to report; ownership checks decide separately
        # whether it is a destroyable generation template.
        return 0
    fi

    # A config read failure is not proof of absence: quorum, permissions, or
    # an API fault can all make qm config fail for a live template. Only use
    # storage recovery when both the cluster config path and qm status say the
    # VM is absent.
    config_path=$(vm_config_path "$vmid")
    if [[ -n "$config_path" ]] || qm status "$vmid" >/dev/null 2>&1; then
        log_error "Cannot read config for live template VMID $vmid"
        return 1
    fi

    # A previous GC attempt may have removed the VM config before failing to
    # free every residual child. Recover the base name from storage so the next
    # run can finish instead of stranding the record and volumes forever.
    storage_list=$(pvesm list "$VM_STORAGE" 2>/dev/null) || return 1
    awk -v storage="$VM_STORAGE:" -v vmid="$vmid" '
        $1 ~ ("^" storage "([^/]+/)?base-" vmid "-disk-") { print $1 }
    ' <<< "$storage_list"
}

linked_clone_child_vmid() {
    local volid="$1"
    local child_name="${volid#*:}"
    child_name="${child_name##*/}"
    if [[ "$child_name" =~ ^vm-([0-9]+)-disk- ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

zfs_dataset_from_volid() {
    local volid="$1"
    local path dataset

    command -v zfs >/dev/null 2>&1 || return 1
    path=$(pvesm path "$volid" 2>/dev/null) || return 1
    [[ "$path" == /dev/zvol/* ]] || return 1

    dataset="${path#/dev/zvol/}"
    zfs list -H -o name "$dataset" >/dev/null 2>&1 || return 1
    printf '%s\n' "$dataset"
}

list_template_linked_clone_volids() {
    local template_vmid="${1:-$TEMPLATE_ID}"
    local storage_list base_list base_volid base_path prefix volid child_name base_dataset dataset origin path
    local -A seen=()

    if ! storage_list=$(pvesm list "$VM_STORAGE" 2>/dev/null); then
        log_error "Failed to list storage volumes on $VM_STORAGE"
        return 1
    fi
    base_list=$(list_template_base_volids "$template_vmid") || return 1
    [[ -n "$storage_list" ]] || return 0

    while read -r base_volid; do
        [[ -n "$base_volid" ]] || continue
        base_path="${base_volid#*:}"
        prefix="${VM_STORAGE}:${base_path}/"

        while read -r volid _; do
            [[ "$volid" == "$prefix"* ]] || continue
            child_name="${volid#"$prefix"}"
            [[ "$child_name" =~ ^vm-[0-9]+-disk- ]] || continue
            [[ -n "${seen[$volid]:-}" ]] && continue
            seen["$volid"]=1
            printf '%s\n' "$volid"
        done <<< "$storage_list"
    done <<< "$base_list"

    # ZFS linked clones are sibling zvols, not nested volids. They point at
    # the template base volume snapshot via the ZFS origin property.
    while read -r base_volid; do
        [[ -n "$base_volid" ]] || continue
        if ! path=$(pvesm path "$base_volid" 2>/dev/null); then
            log_error "Cannot resolve storage path for template volume $base_volid"
            return 1
        fi
        [[ "$path" == /dev/zvol/* ]] || continue
        if ! command -v zfs >/dev/null 2>&1; then
            log_error "Cannot inspect ZFS origin for template volume $base_volid"
            return 1
        fi
        base_dataset="${path#/dev/zvol/}"
        if ! zfs list -H -o name "$base_dataset" >/dev/null 2>&1; then
            log_error "Cannot inspect ZFS dataset $base_dataset for template volume $base_volid"
            return 1
        fi

        while read -r volid _; do
            [[ "$volid" == "$VM_STORAGE:vm-"* ]] || continue
            [[ -n "${seen[$volid]:-}" ]] && continue

            if ! path=$(pvesm path "$volid" 2>/dev/null); then
                log_error "Cannot resolve storage path for possible clone volume $volid"
                return 1
            fi
            [[ "$path" == /dev/zvol/* ]] || continue
            dataset="${path#/dev/zvol/}"
            if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
                log_error "Cannot inspect ZFS dataset $dataset for possible clone volume $volid"
                return 1
            fi
            if ! origin=$(zfs get -H -o value origin "$dataset" 2>/dev/null); then
                log_error "Cannot read ZFS origin for possible clone volume $volid"
                return 1
            fi
            [[ "$origin" == "$base_dataset@"* ]] || continue

            seen["$volid"]=1
            printf '%s\n' "$volid"
        done <<< "$storage_list"
    done <<< "$base_list"
}

cleanup_template_orphan_volumes() {
    local template_vmid="${1:-$TEMPLATE_ID}" child_vmid config_path volid
    shift 2>/dev/null || true
    local -a child_volids=()
    local -a blocked_volids=()
    local -a freed_volids=()

    local child_list=""
    if [[ $# -gt 0 ]]; then
        child_volids=("$@")
    else
        if ! child_list=$(list_template_linked_clone_volids "$template_vmid"); then
            return 1
        fi
        if [[ -n "$child_list" ]]; then
            mapfile -t child_volids <<< "$child_list"
        fi
    fi
    [[ ${#child_volids[@]} -gt 0 ]] || return 0

    log_info "Checking ${#child_volids[@]} linked-clone child volume(s) for template $template_vmid..."

    for volid in "${child_volids[@]}"; do
        child_vmid=$(linked_clone_child_vmid "$volid")
        config_path=""
        [[ -n "$child_vmid" ]] && config_path=$(vm_config_path "$child_vmid")

        if [[ -n "$config_path" ]]; then
            log_warn "Template child volume still has a VM config: $volid ($config_path)"
            blocked_volids+=("$volid")
            continue
        fi

        log_info "Freeing orphaned template child volume: $volid"
        if ! pvesm free "$volid"; then
            log_error "Failed to free orphaned template child volume: $volid"
            return 1
        fi
        freed_volids+=("$volid")
    done

    if [[ ${#freed_volids[@]} -gt 0 ]]; then
        log_info "Freed ${#freed_volids[@]} orphaned linked-clone volume(s) for template $template_vmid."
    fi

    if [[ ${#blocked_volids[@]} -gt 0 ]]; then
        log_error "Template $template_vmid still has linked-clone child volume(s) with VM configs."
        log_error "Destroy those VMs/templates before deleting the template."
        return 2
    fi

    return 0
}

# Sweep zvols on $VM_STORAGE whose VMID has no /etc/pve config — leftovers from
# clones that failed before writing config (or whose _fail cleanup couldn't
# fully reap). Holds the pool activity lock exclusive non-blocking so it can
# never race a clone in progress. Scoped to vmid >= MIN_VMID and != TEMPLATE_ID
# so non-runner VMs on the same storage are never touched.
cleanup_runner_orphan_volumes() {
    local min_vmid="${MIN_VMID:-$((TEMPLATE_ID + 1))}"

    exec 202>"$POOL_ACTIVITY_LOCK_FILE"
    if ! flock -n -x 202; then
        exec 202>&-
        return 0
    fi

    local volid vmid freed=0
    while IFS= read -r volid; do
        [[ -n "$volid" ]] || continue
        if [[ "$volid" =~ (:|/)vm-([0-9]+)-(disk-[0-9]+|cloudinit)$ ]]; then
            vmid="${BASH_REMATCH[2]}"
        else
            continue
        fi
        [[ "$vmid" -ge "$min_vmid" && "$vmid" -ne "$TEMPLATE_ID" ]] || continue
        [[ -z "$(vm_config_path "$vmid")" ]] || continue
        log_info "[orphan-sweep] freeing $volid (vmid $vmid has no config)"
        if pvesm free "$volid" 2>/dev/null; then
            freed=$((freed + 1))
        else
            log_warn "[orphan-sweep] pvesm free $volid failed"
        fi
    done < <(pvesm list "$VM_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}')

    [[ "$freed" -gt 0 ]] && log_info "[orphan-sweep] reaped $freed orphan volume(s)"
    exec 202>&-
}

github_runner_credentials() {
    local org="$1"
    validate_org_name "$org" || return 1
    local org_file="$ORG_CONFIG_DIR/${org}.conf"
    [[ -f "$org_file" ]] || return 1

    local pat="" github_org=""
    # shellcheck source=/dev/null  # per-org config, written by add-org at runtime
    pat=$(source "$org_file" && echo "$GITHUB_PAT") || return 1
    # shellcheck source=/dev/null  # per-org config, written by add-org at runtime
    github_org=$(source "$org_file" && echo "$GITHUB_ORG") || return 1
    [[ -n "$pat" && -n "$github_org" ]] || return 1
    printf '%s\t%s\n' "$github_org" "$pat"
}

# Print "<runner-id>\t<busy>\t<status>" after a complete paginated scan.
# Missing/duplicate names, malformed fields, API errors, and a changing
# total_count all fail closed.
# Emit name, id, busy, status for one stable paginated organization snapshot.
#
# This supersedes the ?name= single-shot lookup the JIT work added to
# deregister_runner: the full scan also reaches a stale runner that sits past
# page 1, and additionally fails closed on a duplicate exact name instead of
# picking one to DELETE. rollover needs the whole org snapshot anyway.
github_runners_snapshot() {
    local org="$1" credentials github_org pat auth_config json total="" page=1 pages page_total
    credentials=$(github_runner_credentials "$org") || return 1
    IFS=$'\t' read -r github_org pat <<< "$credentials"
    # The PAT goes to curl in a config read from stdin, never on argv, where
    # /proc/PID/cmdline hands it to any local user.
    #
    # A process-substitution fd would keep it off argv too, but it is the wrong
    # shape: bash forks the <( ) writer asynchronously and closes the read end
    # as soon as the command returns, so a curl that exits before it opens
    # /dev/fd/N leaves the writer holding a pipe with no reader. Where SIGPIPE
    # is fatal the writer dies silently; where it is ignored — everything under
    # systemd inherits that, IgnoreSIGPIPE=yes being the default, as do shell
    # steps under a CI runner — the write fails instead and bash prints
    # "printf: write error: Broken pipe" on the *caller's* stderr. The
    # 2>/dev/null below cannot suppress it, because the writer is forked during
    # word expansion, before this command's redirections are applied.
    #
    # A here-string has no writer to race: bash fills the redirection itself,
    # synchronously, before curl is exec'd. What bash backs it with — a pipe or
    # a temporary file it creates for this command alone and unlinks before the
    # command runs — varies by version and platform, and the guarantee here
    # does not rest on which: either way the PAT is never on argv, never in
    # curl's environment, and never reachable by another process through a
    # filesystem path.
    printf -v auth_config 'header = "Authorization: token %s"\n' "$pat"

    while :; do
        json=$(curl -sf --max-time 10 \
            -H "Accept: application/vnd.github+json" \
            --config - \
            "https://api.github.com/orgs/${github_org}/actions/runners?per_page=100&page=${page}" \
            2>/dev/null <<< "$auth_config") || return 1
        page_total=$(jq -er 'select((.total_count | type) == "number" and (.runners | type) == "array") | .total_count' <<< "$json" 2>/dev/null) || return 1
        [[ "$page_total" =~ ^[0-9]+$ ]] || return 1
        if [[ -z "$total" ]]; then
            total="$page_total"
            pages=$(((total + 99) / 100))
            (( pages > 0 )) || pages=1
        elif [[ "$page_total" != "$total" ]]; then
            return 1
        fi
        jq -e 'all(.runners[]; (.name | type) == "string" and (.id | type) == "number"
            and (.busy | type) == "boolean" and (.status == "online" or .status == "offline"))' \
            <<< "$json" >/dev/null 2>&1 || return 1
        jq -r '
            .runners[]
            | "\(.name)\t\(.id)\t\(.busy)\t\(.status)"
        ' <<< "$json" 2>/dev/null || return 1
        (( page >= pages )) && break
        page=$((page + 1))
    done
}

github_runner_lookup_details() {
    local org="$1" runner_name="$2" snapshot matches
    snapshot=$(github_runners_snapshot "$org") || return 1
    matches=$(awk -F '\t' -v n="$runner_name" '$1 == n {print $2 "\t" $3 "\t" $4}' <<< "$snapshot")

    [[ "$matches" =~ ^[0-9]+$'\t'(true|false)$'\t'(online|offline)$ ]] || return 1
    printf '%s\n' "$matches"
}

resume_runner_cgroup() {
    local vmid="$1" expected="${2:-}" result exitcode out ack
    if [[ -n "$expected" ]]; then
        [[ "$expected" =~ ^/[a-zA-Z0-9_./:@-]+$ && "$expected" != / && "$expected" != *'..'* && "$expected" != *$'\n'* ]] || return 1
    fi
    # shellcheck disable=SC2016  # guest-side program expands in the guest
    result=$(qm guest exec "$vmid" -- /bin/bash -c '
set -eu
cgroup_root=${RUNNER_CGROUP_ROOT:-/sys/fs/cgroup}
proc_root=${RUNNER_PROC_ROOT:-/proc}
marker=${RUNNER_ROLLOVER_MARKER:-/run/github-runner-rollover-cgroup}
expected=${1:-}
pids=$(pgrep -x Runner.Listener || true)
[ "$(printf "%s\n" "$pids" | sed "/^$/d" | wc -l)" -eq 1 ]
pid=$pids
lines=$(grep "^0::" "${proc_root}/${pid}/cgroup" || true)
[ "$(printf "%s\n" "$lines" | sed "/^$/d" | wc -l)" -eq 1 ]
cg=${lines#0::}
case "$cg" in /|*[!a-zA-Z0-9_./:@-]*|*..*) exit 1;; /*) ;; *) exit 1;; esac
[ -r "$marker" ]
saved=$(cat "$marker")
[ "$saved" = "$cg" ]
[ -z "$expected" ] || [ "$expected" = "$cg" ]
[ -w "${cgroup_root}${cg}/cgroup.freeze" ]
echo 0 > "${cgroup_root}${cg}/cgroup.freeze"
grep -q "^0$" "${cgroup_root}${cg}/cgroup.freeze"
rm -f "$marker"
echo "THAWED:${cg}"
' rollover-thaw "$expected" 2>/dev/null) || return 1
    exitcode=$(jq -er '.exitcode | select(type == "number")' <<< "$result" 2>/dev/null) || return 1
    out=$(jq -er '.["out-data"] | select(type == "string")' <<< "$result" 2>/dev/null) || return 1
    [[ "$exitcode" -eq 0 ]] || return 1
    ack=$(sed -n 's/^THAWED:\(\/[a-zA-Z0-9_./:@-]*\)$/\1/p' <<< "$out")
    [[ "$ack" =~ ^/[a-zA-Z0-9_./:@-]+$ && "$ack" != / && "$ack" != *'..'* && "$ack" != *$'\n'* ]] || return 1
    [[ -z "$expected" || "$ack" == "$expected" ]]
}

runner_rollover_marker_state() {
    local vmid="$1" result exitcode out state
    # shellcheck disable=SC2016  # guest-side program expands in the guest
    result=$(qm guest exec "$vmid" -- /bin/bash -c '
set -eu
marker=${RUNNER_ROLLOVER_MARKER:-/run/github-runner-rollover-cgroup}
if [ ! -e "$marker" ]; then echo MARKER_ABSENT; exit 0; fi
[ -f "$marker" ] && [ -r "$marker" ]
saved=$(cat "$marker")
case "$saved" in /|*[!a-zA-Z0-9_./:@-]*|*..*) exit 1;; /*) ;; *) exit 1;; esac
echo "MARKER:${saved}"
' 2>/dev/null) || return 1
    exitcode=$(jq -er '.exitcode | select(type == "number")' <<< "$result" 2>/dev/null) || return 1
    out=$(jq -er '.["out-data"] | select(type == "string")' <<< "$result" 2>/dev/null) || return 1
    [[ "$exitcode" -eq 0 ]] || return 1
    if [[ "$out" == MARKER_ABSENT || "$out" == $'MARKER_ABSENT\n' || "$out" == $'MARKER_ABSENT\r\n' ]]; then
        printf 'absent\n'
        return 0
    fi
    state=$(sed -n 's/^MARKER:\(\/[a-zA-Z0-9_./:@-]*\)$/\1/p' <<< "$out")
    [[ "$state" =~ ^/[a-zA-Z0-9_./:@-]+$ && "$state" != / && "$state" != *'..'* && "$state" != *$'\n'* ]] || return 1
    printf '%s\n' "$state"
}

rollover_clear_identity_nonce() {
    local vmid="$1" name="$2" org="$3" gen="$4" nonce="$5" cfg tags tag new=""
    rollover_pending_identity_matches "$vmid" "$name" "$org" "$gen" "$nonce" || return 1
    cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || return 1
    tags=$(awk -F ': ' '/^tags:/{print $2; exit}' <<< "$cfg")
    tags=${tags//;/,}
    while IFS= read -r tag; do
        tag=${tag#"${tag%%[![:space:]]*}"}; tag=${tag%"${tag##*[![:space:]]}"}
        [[ -n "$tag" && "$tag" != "rollover-${nonce}" ]] || continue
        new+="${new:+;}${tag}"
    done < <(tr ',' '\n' <<< "$tags")
    qm set "$vmid" --tags "$new" >/dev/null 2>&1
}

rollover_pending_identity_matches() {
    local vmid="$1" expected_name="$2" expected_org="$3" expected_gen="$4" nonce="$5"
    local cfg name org tags
    cfg=$(qm config "$vmid" 2>/dev/null </dev/null) || return 1
    name=$(awk '/^name:/{print $2; exit}' <<< "$cfg")
    org=$(org_from_vm_config "$cfg") || return 1
    tags=$(awk -F ': ' '/^tags:/{print $2; exit}' <<< "$cfg")
    [[ "$name" == "$expected_name" && "$org" == "$expected_org" ]] || return 1
    [[ ",$tags," =~ [,\;]gen-${expected_gen}([,\;]|$) ]] || return 1
    [[ ",$tags," =~ [,\;]rollover-${nonce}([,\;]|$) ]]
}

rollover_vmid_absent_verified() {
    local vmid="$1" all
    all=$(qm list 2>/dev/null) || return 1
    ! awk -v v="$vmid" 'NR > 1 && $1 == v {found=1} END {exit !found}' <<< "$all"
}

# Retry committed rollover destroys. A committed VM is already frozen and
# deregistered; leaving the record makes recovery durable across process/host
# crashes. Failure is non-fatal so the watcher can still refill its slot.
recover_rollover_pending() {
    local file phase vmid name org gen runner_id nonce cgroup status marker_state recovered
    [[ -d "$ROLLOVER_PENDING_DIR" ]] || return 0
    for file in "$ROLLOVER_PENDING_DIR"/*.pending; do
        [[ -f "$file" ]] || continue
        IFS='|' read -r phase vmid name org gen runner_id nonce cgroup < "$file" || continue
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        validate_org_name "$org" || continue
        exec 209>"${ROLLOVER_ORG_LOCK_PREFIX}-${org}.lock"
        flock -n 209 || { exec 209>&-; continue; }
        if ! qm status "$vmid" >/dev/null 2>&1; then
            rollover_vmid_absent_verified "$vmid" && rm -f "$file"
            exec 209>&-
            continue
        fi
        if ! rollover_pending_identity_matches "$vmid" "$name" "$org" "$gen" "$nonce"; then
            log_warn "[rollover-recovery] stale identity for pending VMID $vmid — leaving it untouched"
            exec 209>&-
            continue
        fi
        if [[ "$phase" == preparing ]]; then
            marker_state=$(runner_rollover_marker_state "$vmid") || { exec 209>&-; continue; }
            recovered=false
            if [[ "$marker_state" == absent ]]; then
                recovered=true
            elif resume_runner_cgroup "$vmid" "$marker_state"; then
                recovered=true
            fi
            if [[ "$recovered" == true ]] && rollover_clear_identity_nonce "$vmid" "$name" "$org" "$gen" "$nonce"; then
                rm -f "$file"
            fi
            exec 209>&-
            continue
        fi
        if [[ "$phase" == owned ]]; then
            marker_state=$(runner_rollover_marker_state "$vmid") || { exec 209>&-; continue; }
            recovered=false
            if [[ "$marker_state" == absent ]]; then
                recovered=true
            elif [[ "$marker_state" == "$cgroup" ]] && resume_runner_cgroup "$vmid" "$cgroup"; then
                recovered=true
            fi
            if [[ "$recovered" == true ]] \
                && rollover_clear_identity_nonce "$vmid" "$name" "$org" "$gen" "$nonce"; then
                rm -f "$file"
            fi
            exec 209>&-
            continue
        fi
        [[ "$phase" == committed ]] || { exec 209>&-; continue; }
        github_runner_deregister_id "$org" "$runner_id" >/dev/null 2>&1 || true
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}') || { exec 209>&-; continue; }
        if [[ "$status" == running ]]; then
            qm stop "$vmid" --timeout 30 200>&- 209>&- >/dev/null 2>&1 || { exec 209>&-; continue; }
            status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}') || { exec 209>&-; continue; }
            [[ "$status" == stopped ]] || { exec 209>&-; continue; }
        fi
        rollover_pending_identity_matches "$vmid" "$name" "$org" "$gen" "$nonce" || { exec 209>&-; continue; }
        if qm destroy "$vmid" --purge 200>&- 209>&- 2>/dev/null; then
            cleanup_clone_snippets "$vmid"
            rm -f "$file"
            log_info "[rollover-recovery] destroyed pending VMID $vmid ($name)"
        fi
        exec 209>&-
    done
}

rollover_vmid_is_committed_pending() {
    local vmid="$1" file phase record_vmid name org gen _runner_id nonce _cgroup
    file="$ROLLOVER_PENDING_DIR/${vmid}.pending"
    [[ "$vmid" =~ ^[0-9]+$ && -f "$file" ]] || return 1
    IFS='|' read -r phase record_vmid name org gen _runner_id nonce _cgroup < "$file" || return 1
    [[ "$phase" == committed && "$record_vmid" == "$vmid" ]] || return 1
    rollover_pending_identity_matches "$vmid" "$name" "$org" "$gen" "$nonce"
}

# Compatibility wrapper for callers that only need id/busy.
github_runner_lookup() {
    local details id busy _status
    details=$(github_runner_lookup_details "$1" "$2") || return 1
    IFS=$'\t' read -r id busy _status <<< "$details"
    printf '%s\t%s\n' "$id" "$busy"
}

# Strict counterpart to deregister_runner for callers whose next operation is
# destructive.  Failure is meaningful: they must leave the VM alone.
# DELETE a runner by numeric id. PAT on stdin, never argv or a <( ) fd — see
# github_runners_snapshot for why. Shared by github_runner_deregister_id
# (which resolves org-config credentials first) and fetch_jit_config's canary
# label-mismatch path (which already has GITHUB_ORG/GITHUB_PAT loaded and has
# no org-config slug to re-derive them from) — one place for this HTTP call.
# stdout suppressed: DELETE returns 204 (empty), but callers run this from
# inside $(...) capture (deregister_runner from clone_runner's JIT mint-retry
# path, fetch_jit_config's own mismatch path), so keep any surprise body off
# the captured stdout. The exit status still propagates — destructive callers
# depend on it.
_github_runner_delete() {
    local github_org="$1" pat="$2" runner_id="$3" auth_config
    [[ "$runner_id" =~ ^[0-9]+$ ]] || return 1
    printf -v auth_config 'header = "Authorization: token %s"\n' "$pat"
    curl -sf --max-time 10 -X DELETE \
        -H "Accept: application/vnd.github+json" \
        --config - \
        "https://api.github.com/orgs/${github_org}/actions/runners/${runner_id}" \
        >/dev/null 2>&1 <<< "$auth_config"
}

github_runner_deregister_id() {
    local org="$1" runner_id="$2" credentials github_org pat
    [[ "$runner_id" =~ ^[0-9]+$ ]] || return 1
    credentials=$(github_runner_credentials "$org") || return 1
    IFS=$'\t' read -r github_org pat <<< "$credentials"
    _github_runner_delete "$github_org" "$pat" "$runner_id"
}

deregister_runner() {
    local org="$1" runner_name="$2" runner id _busy

    runner=$(github_runner_lookup "$org" "$runner_name") || return 0
    IFS=$'\t' read -r id _busy <<< "$runner"
    github_runner_deregister_id "$org" "$id" || return 0
}

# --- Shared runner VM helpers ---

# Mint a single-use JIT (just-in-time) runner config on the host. The runner
# registers and auto-removes using this config, and it CANNOT be reused to
# register another runner — so even if a job reads it from the cloud-init drive
# it cannot be replayed. Requires GITHUB_PAT and GITHUB_ORG in scope (caller ran
# load_org_config). The PAT is passed via curl --config to keep it off argv; the
# request body (name/labels/group) is not sensitive. RUNNER_GROUP_ID (default 1
# = the org's "Default" group) and RUNNER_LABELS may be set in the org config.
# clone_runner --canary shadows RUNNER_LABELS with a local before calling this,
# so a canary's minted config carries only gen-<N>-canary (#21) — this function
# has no canary-specific branch of its own.
#
# JIT_ENFORCE_EXACT_LABELS=1 (set by clone_runner --canary alongside its
# RUNNER_LABELS shadow) turns "GitHub adds no default labels to a
# JIT-registered runner" from an assumption into an enforced invariant: the
# mint response's runner.labels[] is compared against exactly what was
# requested, and ANY extra label (e.g. a read-only self-hosted/Linux/X64
# GitHub decided to attach) deregisters the runner immediately and fails
# closed — clone_runner never clones a VM for it. Left unset (or 0) for every
# production mint, where GitHub legitimately attaching a read-only default
# label must never block a clone.
# Prints the base64 encoded_jit_config on stdout.
# Returns 0 on success, 2 on HTTP 409 (duplicate runner name), 1 on any other
# failure (including the label-mismatch fail-closed path above).
fetch_jit_config() {
    local name="$1"
    local group="${RUNNER_GROUP_ID:-1}"
    local labels="${RUNNER_LABELS:-self-hosted,linux,x64}"
    [[ -n "$labels" ]] || labels="self-hosted,linux,x64"
    # Group IDs are >=1 (1 = Default); clamp anything else to 1.
    [[ "$group" =~ ^[1-9][0-9]*$ ]] || group=1
    local body http_code jit tmp auth_config
    # split → trim each label → drop empties, so a hand-edited RUNNER_LABELS with
    # spaces or a trailing comma still yields clean labels.
    body=$(jq -n --arg name "$name" --argjson group "$group" --arg labels "$labels" \
        '{name: $name, runner_group_id: $group,
          labels: ($labels | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)))}') || return 1
    tmp=$(mktemp) || return 1
    # Config on stdin, not on a <( ) fd — see github_runners_snapshot.
    printf -v auth_config 'header = "Authorization: token %s"\n' "$GITHUB_PAT"
    http_code=$(curl -sS -o "$tmp" -w "%{http_code}" --max-time 15 --retry 3 -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        --config - \
        --data "$body" \
        "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/generate-jitconfig" \
        <<< "$auth_config") || http_code="000"
    body=$(cat "$tmp")
    rm -f "$tmp"
    if [[ "$http_code" == "409" ]]; then
        log_warn "JIT mint conflict: a runner named '$name' already exists"
        return 2
    fi
    if [[ "$http_code" != "201" && "$http_code" != "200" ]]; then
        case "$http_code" in
            401|403) log_error "JIT mint failed for '$name' (HTTP $http_code) — PAT needs runner write access" ;;
            404) log_error "JIT mint failed for '$name' (HTTP $http_code) — org or runner group $group not found" ;;
            422) log_error "JIT mint failed for '$name' (HTTP $http_code) — invalid name, labels, or group" ;;
            *) log_error "JIT mint failed for '$name' (HTTP $http_code)" ;;
        esac
        return 1
    fi
    jit=$(jq -r '.encoded_jit_config // empty' <<<"$body" 2>/dev/null) || return 1
    # Must be a single base64 token — rejects anything with quotes/newlines that
    # could break out of the YAML string it gets rendered into.
    [[ -n "$jit" && "$jit" =~ ^[A-Za-z0-9+/=_-]+$ ]] || return 1

    # Canary isolation invariant (issue #21): the whole point of shadowing
    # RUNNER_LABELS is worthless if GitHub silently attaches a label we
    # didn't ask for. Compare what the response actually attached to the
    # runner against exactly what was requested — never the other way
    # around, so a legitimate production default (JIT_ENFORCE_EXACT_LABELS
    # unset) is never second-guessed.
    if [[ "${JIT_ENFORCE_EXACT_LABELS:-0}" == "1" ]]; then
        local requested_json returned_json unexpected runner_id
        requested_json=$(jq -n --arg labels "$labels" \
            '$labels | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)) | sort') || return 1
        # .runner.labels[] may be absent on a malformed/unexpected response
        # shape; falling back to [] treats that as "nothing observed" rather
        # than erroring, since the base64 config itself already validated
        # above.
        returned_json=$(jq -c '[.runner.labels[]?.name] | sort' <<<"$body" 2>/dev/null) || returned_json="[]"
        unexpected=$(jq -rn --argjson requested "$requested_json" --argjson returned "$returned_json" \
            '($returned - $requested) | join(", ")' 2>/dev/null)
        if [[ -n "$unexpected" ]]; then
            runner_id=$(jq -r '.runner.id // empty' <<<"$body" 2>/dev/null)
            log_error "JIT mint for '$name' returned unexpected label(s) [$unexpected] beyond the requested set ($labels) — GitHub may have attached a default label to this JIT runner. Deregistering; refusing to start an unisolated canary."
            # _github_runner_delete itself rejects a non-numeric/empty
            # runner_id, so this one check covers both "nothing to delete"
            # and "the DELETE failed" — either way the operator must not be
            # told the canary is isolated when a labeled runner is still
            # sitting on GitHub.
            if ! _github_runner_delete "$GITHUB_ORG" "$GITHUB_PAT" "$runner_id"; then
                log_error "failed to deregister runner ${runner_id:-<unknown>} — an unisolated runner is still registered on GitHub; remove it manually"
            fi
            return 1
        fi
    fi

    printf '%s' "$jit"
}

# Render a per-VM cloud-init user snippet carrying only the single-use JIT
# config and org (never the PAT). Uses awk with the config passed via ENVIRON so
# it never appears in the process list.
# Usage: render_user_snippet <vmid> <org> <jit_config>
render_user_snippet() {
    local vmid="$1" org="$2" jit_config="$3"
    local tmp
    tmp=$(mktemp "$SNIPPETS_DIR/.runner-${vmid}-user.XXXXXX") || return 1
    chmod 600 "$tmp"
    JIT_CONFIG="$jit_config" GITHUB_ORG="$GITHUB_ORG" DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-}" awk '
    # Literal string replace (avoids gsub special chars: & and \)
    function lreplace(str, old, new,    i, result) {
        result = ""
        while ((i = index(str, old)) > 0) {
            result = result substr(str, 1, i - 1) new
            str = substr(str, i + length(old))
        }
        return result str
    }
    {
        $0 = lreplace($0, "{{JIT_CONFIG}}", ENVIRON["JIT_CONFIG"])
        $0 = lreplace($0, "{{GITHUB_ORG}}", ENVIRON["GITHUB_ORG"])
        $0 = lreplace($0, "{{DOCKER_MIRROR_URL}}", ENVIRON["DOCKER_MIRROR_URL"])
        print
    }' "$INSTALL_DIR/templates/runner-user-data.yaml" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$SNIPPETS_DIR/runner-${vmid}-user-${org}.yaml" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SNIPPETS_DIR/runner-${vmid}-user-${org}.yaml"
}

# Deterministic MAC from name. Locally-administered unicast (02:xx:xx:xx:xx:xx).
generate_mac() {
    echo -n "$1" | md5sum | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\).*/02:\1:\2:\3:\4:\5/'
}

# Remove every per-VM cloud-init snippet for a clone: meta, the per-VM JIT
# user snippet (runner-<vmid>-user-<org>.yaml — org unknown here, hence the
# glob), and a defensive sweep of a vendor snippet. Canary label isolation is
# expressed in the JIT config minted on the host (see the RUNNER_LABELS
# override next to clone_runner's fetch_jit_config call), not via cloud-init
# vendor-data, so nothing writes runner-<vmid>-vendor.yaml today — the glob
# stays so a later occupant of the same VMID can never inherit a stray one.
# Proven by "cleanup_clone_snippets removes meta, user, and vendor files".
cleanup_clone_snippets() {
    local vmid="${1:-}"
    [[ "$vmid" =~ ^[0-9]+$ ]] || return 0
    rm -f "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" \
          "${SNIPPETS_DIR}/runner-${vmid}-user-"*.yaml \
          "${SNIPPETS_DIR}/runner-${vmid}-vendor.yaml"
}

_ensure_generations_lib() {
    if declare -F gen_list >/dev/null 2>&1; then
        return 0
    fi
    if [[ -r "$LIB_DIR/generations.sh" ]]; then
        # generations.sh sources common.sh; RUNNER_COMMON_LOADED makes that
        # a no-op. source=/dev/null so shellcheck does not follow the cycle.
        # shellcheck source=/dev/null
        source "$LIB_DIR/generations.sh" || return 1
    fi
    declare -F gen_list >/dev/null 2>&1
}

# GEN_ID whose record names this template VMID. Scans every record matching
# GEN_VMID rather than "the currently active generation": a promotion can land
# between a caller reading the pointer and clone_runner running, and tagging
# the clone as the new generation would undercount the old one's children.
# Proven by "clone_runner tags the clone gen-N from the cloned VMID's record".
clone_generation_id_for_vmid() (
    local target="${1:-}" rec_vmid
    # gen_read assigns these via printf -v; locals keep the lookup from leaking.
    local GEN_ID="" GEN_VMID=""
    [[ -n "$target" ]] || return 1
    while read -r rec_vmid; do
        [[ -n "$rec_vmid" ]] || continue
        gen_read "$rec_vmid" || continue
        if [[ "$GEN_VMID" == "$target" ]]; then
            printf '%s\n' "$GEN_ID"
            return 0
        fi
    done < <(gen_list)
    return 1
)

# Tag a fresh clone from the VMID actually cloned. Missing store or record is
# a warning, not a failed clone — unless extra_tag is set (canary), which is
# fail-closed so an untagged canary cannot register with production labels.
clone_tag_generation() {
    local clone_vmid="$1" template_vmid="$2" extra_tag="${3:-}"
    local gen_id="" tags

    if ! _ensure_generations_lib; then
        if [[ -n "$extra_tag" ]]; then
            log_error "clone_runner: generation store unavailable — cannot tag $clone_vmid as $extra_tag"
            return 1
        fi
        log_warn "clone_runner: generation store unavailable — clone $clone_vmid untagged"
        return 0
    fi

    gen_id=$(clone_generation_id_for_vmid "$template_vmid") || gen_id=""
    if [[ -z "$gen_id" ]]; then
        if [[ -n "$extra_tag" ]]; then
            log_error "clone_runner: no generation record for template VMID $template_vmid — cannot tag $clone_vmid as $extra_tag"
            return 1
        fi
        log_warn "clone_runner: no generation record for template VMID $template_vmid — clone $clone_vmid untagged"
        return 0
    fi
    tags="runner,gen-${gen_id}"
    [[ -n "$extra_tag" ]] && tags="${tags},${extra_tag}"
    if ! qm set "$clone_vmid" --tags "$tags" \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&-; then
        log_error "clone_runner: failed to tag $clone_vmid as gen-${gen_id}"
        return 1
    fi
    return 0
}

# Canary clone of a specific template VMID (typically a candidate). Production
# callers stay on clone_runner name/org and never pass --canary.
# Proven by "clone_canary_runner clones the candidate template not TEMPLATE_ID".
clone_canary_runner() {
    local name="${1:-}" org="${2:-}" template_vmid="${3:-}" vmid="${4:-}"
    if [[ -z "$name" || -z "$org" || -z "$template_vmid" ]]; then
        log_error "clone_canary_runner: usage: clone_canary_runner <name> <org> <template-vmid> [vmid]"
        return 1
    fi
    if [[ ! "$template_vmid" =~ ^[0-9]+$ ]]; then
        log_error "clone_canary_runner: invalid template VMID $template_vmid"
        return 1
    fi
    if [[ -n "$vmid" ]]; then
        clone_runner --canary --template "$template_vmid" "$name" "$org" "$vmid"
    else
        clone_runner --canary --template "$template_vmid" "$name" "$org"
    fi
}

# Clone template, configure cloud-init, set hookscript, start VM.
# Returns VMID on stdout.
# Returns 1 on failure (cleans up partial clone).
# Returns 3 when PROMOTION_PAUSE_FILE is still present after a bounded wait
# (CLONE_PAUSE_RETRY_MAX_SECONDS, default 130 — longer than promote's 120s
# exclusive-lock wait). Distinct from 1 so reclone.sh / watch.sh retry
# without notifying clone.failed. Tests set the bound to 0 to skip the wait.
#
# --canary mints its JIT config with RUNNER_LABELS=gen-N-canary so the guest
# registers with only that label (GitHub does not add default labels to a
# JIT-registered runner), and tags runner,gen-N,runner-canary. --template
# clones that VMID instead of the active pointer; it is rejected without
# --canary so production call sites stay byte-identical (user= + meta= only,
# and the RUNNER_LABELS an org config may set is never shadowed).
clone_runner() {
    local name="" org="" vmid=""
    local canary=0 template_override="" clone_src="" canary_gen_id="" extra_tag=""
    # Declared unconditionally (unlike RUNNER_LABELS, which a production org
    # config may legitimately set and must pass through untouched) so that an
    # exported env var or an org .conf that happens to set
    # JIT_ENFORCE_EXACT_LABELS=1 can never leak into a production mint and
    # fail it over a legitimate GitHub default. Only the canary branch below
    # turns it on.
    local JIT_ENFORCE_EXACT_LABELS=0
    local RESERVED_VMID=""
    local pause_waited=0
    local pause_max="${CLONE_PAUSE_RETRY_MAX_SECONDS:-130}"
    local pool_lock_owned=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --canary)
                canary=1
                shift
                ;;
            --template)
                if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                    log_error "clone_runner: --template requires a VMID"
                    return 1
                fi
                template_override="$2"
                shift 2
                ;;
            --template=*)
                template_override="${1#--template=}"
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                log_error "clone_runner: unknown option $1"
                return 1
                ;;
            *)
                break
                ;;
        esac
    done
    name="${1:-}"
    org="${2:-}"
    vmid="${3:-}"
    if [[ -z "$name" || -z "$org" ]]; then
        log_error "clone_runner: usage: clone_runner [--canary] [--template VMID] <name> <org> [vmid]"
        return 1
    fi
    if [[ -n "$template_override" && "$canary" -ne 1 ]]; then
        log_error "clone_runner: --template is only valid with --canary"
        return 1
    fi
    if [[ -n "$template_override" && ! "$template_override" =~ ^[0-9]+$ ]]; then
        log_error "clone_runner: invalid template VMID $template_override"
        return 1
    fi

    # GITHUB_PAT/GITHUB_ORG must be in scope (caller ran load_org_config).
    if [[ -z "${GITHUB_PAT:-}" || -z "${GITHUB_ORG:-}" ]]; then
        log_error "clone_runner: org config not loaded (GITHUB_PAT/GITHUB_ORG unset)"
        return 1
    fi

    # reclone.sh holds fd 202 for its whole lifetime (POOL_ACTIVITY_LOCK_HELD=1)
    # so runner stop's exclusive 202 waits out destroy+mint, not just qm clone.
    # Do not exec 202> in that case — it would drop the caller's lock.
    _pool_lock_acquire() {
        if [[ "${POOL_ACTIVITY_LOCK_HELD:-0}" == "1" ]]; then
            return 0
        fi
        exec 202>"$POOL_ACTIVITY_LOCK_FILE"
        flock -s 202
        pool_lock_owned=1
    }
    _pool_lock_release() {
        if [[ "$pool_lock_owned" == "1" ]]; then
            exec 202>&-
            pool_lock_owned=0
        fi
    }

    _pool_lock_acquire

    # Pause file lets promote acquire the exclusive lock: Linux flock has no
    # writer preference, so new shared holders would otherwise starve it.
    # Sleep 2, drop shared, re-acquire, re-check, up to pause_max seconds;
    # then return 3 (not 1). Proven by "clone_runner returns 3 without cloning
    # when PROMOTION_PAUSE_FILE remains" and "clone_runner clones the re-read
    # TEMPLATE_ID when the pause file clears mid-wait".
    #
    # When the caller owns fd 202 (reclone.sh, POOL_ACTIVITY_LOCK_HELD=1) the
    # wait cannot work: dropping the lock here would break the caller's promise
    # that `runner stop` waits out its whole destroy+mint, and holding it would
    # just starve promote for the full wait. Defer immediately instead — the
    # caller exits, which releases fd 202 and lets promote through, and the
    # watcher refills the slot on the next tick.
    [[ "$pause_max" =~ ^[0-9]+$ ]] || pause_max=130
    if [[ "${POOL_ACTIVITY_LOCK_HELD:-0}" == "1" && -e "$PROMOTION_PAUSE_FILE" ]]; then
        log_info "clone_runner: promotion in progress, will retry"
        return 3
    fi
    while [[ -e "$PROMOTION_PAUSE_FILE" ]]; do
        if (( pause_waited >= pause_max )); then
            # Unflocked pause is leftover (SIGKILL). A live promote holds
            # exclusive 211 on this file. Proven by "clone_runner returns 3
            # without cloning when PROMOTION_PAUSE_FILE remains".
            exec 211>>"$PROMOTION_PAUSE_FILE" || {
                _pool_lock_release
                return 3
            }
            if flock -n 211; then
                rm -f "$PROMOTION_PAUSE_FILE"
                exec 211>&- 2>/dev/null || true
                log_warn "clone_runner: removed stale promotion pause file"
                break
            fi
            exec 211>&- 2>/dev/null || true
            log_info "clone_runner: promotion in progress, will retry"
            _pool_lock_release
            return 3
        fi
        if (( pause_waited == 0 )); then
            log_info "clone_runner: promotion in progress, waiting to retry $name"
        fi
        _pool_lock_release
        sleep 2
        pause_waited=$((pause_waited + 2))
        exec 202>"$POOL_ACTIVITY_LOCK_FILE" || {
            log_error "clone_runner: cannot reopen pool lock while waiting out promotion"
            return 1
        }
        flock -s 202
        pool_lock_owned=1
    done

    if pool_is_draining; then
        log_warn "clone_runner: pool drain active, refusing to create $name"
        _pool_lock_release
        return 1
    fi

    # Re-read after the shared lock so a promotion that ran after the caller
    # sourced CONFIG_FILE is visible before qm clone.
    # Proven by "clone_runner re-reads TEMPLATE_ID after the shared lock".
    # --template (canary only) clones that VMID instead of the active pointer.
    if [[ -n "$template_override" ]]; then
        clone_src="$template_override"
    else
        TEMPLATE_ID=$(reload_active_template_id) || {
            log_error "clone_runner: failed to re-read TEMPLATE_ID"
            _pool_lock_release
            return 1
        }
        clone_src="$TEMPLATE_ID"
    fi

    # A canary without a generation id cannot isolate labels — refuse before
    # allocating a VMID. Proven by "clone_runner --canary fails closed without
    # a generation record".
    if [[ "$canary" -eq 1 ]]; then
        if ! _ensure_generations_lib; then
            log_error "clone_runner: generation store unavailable — refusing canary clone"
            _pool_lock_release
            return 1
        fi
        canary_gen_id=$(clone_generation_id_for_vmid "$clone_src") || canary_gen_id=""
        if [[ -z "$canary_gen_id" ]]; then
            log_error "clone_runner: canary clone requires a generation record for template $clone_src"
            _pool_lock_release
            return 1
        fi
        extra_tag="runner-canary"
    fi

    # Cleanup helper: destroy VM (only if it belongs to us), remove snippet, and
    # sweep orphan zvols at this VMID. The ownership check prevents touching
    # another process's VM on VMID collision. Orphan sweep runs unconditionally
    # for our-VMID and no-owner cases because qm destroy --purge can silently
    # leave residue (busy ZFS dataset, etc.) and a clone that fails before
    # writing config leaves zvols with no VM to attach to.
    _fail() {
        local owner
        owner=$(qm config "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&- 2>/dev/null | awk '/^name:/{print $2}') || true

        if [[ -n "$owner" && "$owner" != "$name" ]]; then
            return 0
        fi

        cleanup_clone_snippets "$vmid"

        if [[ "$owner" == "$name" ]]; then
            local destroy_err; destroy_err=$(mktemp)
            if ! qm destroy "$vmid" --purge 200>&- 201>&- 202>&- 203>&- 204>&- 2>"$destroy_err"; then
                log_warn "qm destroy $vmid failed: $(tr '\n' ' ' < "$destroy_err")"
            fi
            rm -f "$destroy_err"
        fi

        local volid
        while read -r volid; do
            [[ -n "$volid" ]] || continue
            pvesm free "$volid" 2>/dev/null || log_warn "Failed to free orphan volume $volid"
        done < <(
            pvesm list "$VM_STORAGE" 2>/dev/null |
                awk -v v="$vmid" 'NR>1 && $1 ~ ("(^|:|/)vm-" v "-(disk-[0-9]+|cloudinit)$") {print $1}'
        )
    }

    # Mint the single-use JIT config BEFORE cloning so the PAT never enters the
    # VM. Fail fast here (return 1, not _fail): nothing has been created yet, and
    # on a VMID collision _fail's name match could destroy a foreign VM.
    # generate-jitconfig 409s if a runner of this name still exists (e.g. a
    # crashed VM left a stale entry). A healthy ephemeral runner auto-removes
    # after its job, so the common path mints in one call; only on failure do we
    # deregister the stale entry (mirrors config.sh --replace) and retry once.
    #
    # Canary label isolation happens right here, not via cloud-init: fetch_jit_config
    # reads RUNNER_LABELS from its environment, and a `local` in bash is visible to
    # every function called from this point in the call stack (including a retry
    # after a 409), so shadowing it for a canary clone makes the minted JIT config
    # carry only gen-<N>-canary — never self-hosted/linux/x64 — without touching
    # whatever RUNNER_LABELS a production org config may set. GitHub does not add
    # default labels to a JIT-registered runner, so this label set is exact. Proven
    # by "clone_runner --canary mints a JIT config carrying only gen-N-canary".
    #
    # JIT_ENFORCE_EXACT_LABELS turns that "GitHub adds no default labels"
    # assumption into an enforced invariant instead of a trusted one:
    # fetch_jit_config compares the labels GitHub's response actually
    # attached to the runner against exactly what was requested, and fails
    # closed (deregistering the runner it just minted) on any mismatch.
    # Canary-only: production must never fail a clone over a legitimate
    # read-only default GitHub may attach there.
    if [[ "$canary" -eq 1 ]]; then
        local RUNNER_LABELS="gen-${canary_gen_id}-canary"
        JIT_ENFORCE_EXACT_LABELS=1
    fi
    local jit_config mint_rc=0
    jit_config=$(fetch_jit_config "$name") && mint_rc=0 || mint_rc=$?
    if [[ $mint_rc -eq 2 ]]; then
        # Duplicate name: deregister the stale GitHub-side runner and mint once more.
        deregister_runner "$org" "$name" || true
        jit_config=$(fetch_jit_config "$name") && mint_rc=0 || mint_rc=$?
        if [[ $mint_rc -ne 0 ]]; then
            log_error "Failed to mint JIT config for org '$GITHUB_ORG' after removing a stale runner named '$name'"
            _pool_lock_release
            return 1
        fi
    elif [[ $mint_rc -ne 0 ]]; then
        _pool_lock_release
        return 1
    fi

    # Acquire global VMID allocation lock only long enough to reserve one VMID.
    # The per-VMID reservation stays held until qm clone returns, which lets
    # other workers reserve different VMIDs and clone with bounded parallelism.
    # Timeout is intentionally high because a cold pool refill can queue many
    # workers behind the same allocation lock.
    # Callers (reclone.sh/watch.sh) must acquire their per-slot fd 200 lock
    # before entering clone_runner to avoid deadlock on lock order inversion.
    exec 201>"$VMID_LOCK_FILE"
    if ! flock -w 300 201; then
        log_error "clone_runner: timed out acquiring VMID lock for $name"
        exec 201>&-
        _pool_lock_release
        return 1
    fi

    if [[ -z "$vmid" ]]; then
        if ! reserve_vmid; then
            exec 201>&-
            _pool_lock_release
            return 1
        fi
        vmid="$RESERVED_VMID"
    else
        # Caller pre-allocated. Re-verify under lock — a concurrent process
        # could have grabbed it between the caller's check and now.
        if ! reserve_vmid "$vmid"; then
            exec 201>&-
            _pool_lock_release
            return 1
        fi
        vmid="$RESERVED_VMID"
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        exec 201>&-
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi

    # VMID is reserved; release the allocator so other workers can reserve and
    # clone different VMIDs while this clone runs.
    exec 201>&-

    local slot_rc=0
    acquire_clone_slot || slot_rc=$?
    if (( slot_rc == 3 )); then
        log_info "clone_runner: promotion in progress, will retry"
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 3
    fi
    if (( slot_rc != 0 )); then
        log_warn "clone_runner: pool drain became active before cloning $name"
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active before cloning $name"
        release_clone_slot
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi

    # Keep maintenance locks in this shell only. Proxmox helper children can
    # spawn long-lived kvm processes; those must not inherit runner lock fds.
    # Capture stderr so the actual ZFS/Proxmox error surfaces under
    # `journalctl -t github-runner` instead of being buried under the service
    # unit log (which the operator does not look at first).
    local clone_err; clone_err=$(mktemp)
    if ! qm clone "$clone_src" "$vmid" --name "$name" 200>&- 201>&- 202>&- 203>&- 204>&- 2>"$clone_err"; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && log_error "qm clone $vmid: $line"
        done < "$clone_err"
        rm -f "$clone_err"
        release_clone_slot
        _fail
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi
    rm -f "$clone_err"
    release_clone_slot

    if ! clone_tag_generation "$vmid" "$clone_src" "$extra_tag"; then
        _fail
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active after cloning $name, cleaning up VM $vmid"
        _fail
        release_vmid_reservation "$vmid"
        _pool_lock_release
        return 1
    fi

    # Clone succeeded — VMID is now claimed in Proxmox.
    release_vmid_reservation "$vmid"

    # Deterministic MAC
    local mac net0
    mac=$(generate_mac "$name")
    net0=$(qm config "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&- | grep '^net0:' | sed 's/^net0: //') || true
    if [[ -n "$net0" ]]; then
        # shellcheck disable=SC2001  # pattern is a regex; ${//} only does literals
        net0=$(echo "$net0" | sed "s/virtio=[^,]*/virtio=$mac/")
        qm set "$vmid" --net0 "$net0" 200>&- 201>&- 202>&- 203>&- 204>&- || { _fail; _pool_lock_release; return 1; }
    fi

    # Cloud-init meta (instance-id / hostname). Guard the write itself — a brace
    # group's exit status is its LAST command, so a failed write (e.g. ENOSPC mid
    # clone) followed by a successful chmod would be masked and boot a VM with a
    # truncated meta snippet.
    printf 'instance-id: "%s"\nlocal-hostname: "%s"\n' "$name" "$name" \
        > "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" || { _fail; _pool_lock_release; return 1; }
    chmod 600 "${SNIPPETS_DIR}/runner-${vmid}-meta.yaml" || { _fail; _pool_lock_release; return 1; }

    # Per-VM user snippet carrying the single-use JIT config (must exist before
    # qm set --cicustom, which validates the referenced volume). Canary label
    # isolation does not need a vendor-data snippet here: the JIT config minted
    # above already carries the canary-only label set (see the RUNNER_LABELS
    # override next to the fetch_jit_config call), so this cicustom stays
    # user=+meta= for both production and canary clones.
    render_user_snippet "$vmid" "$org" "$jit_config" || { _fail; _pool_lock_release; return 1; }

    qm set "$vmid" --cicustom "user=local:snippets/runner-${vmid}-user-${org}.yaml,meta=local:snippets/runner-${vmid}-meta.yaml" \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }
    qm set "$vmid" --ipconfig0 ip=dhcp \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }
    [[ -z "${DNS_SERVERS:-}" ]] || qm set "$vmid" --nameserver "$DNS_SERVERS" \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }
    qm set "$vmid" --ciuser runner \
        200>&- \
        201>&- \
        202>&- \
        203>&- \
        204>&- \
        || { _fail; _pool_lock_release; return 1; }

    # Hookscript for auto-destroy on shutdown
    if [[ -f "$SNIPPETS_DIR/runner-hookscript.sh" ]]; then
        qm set "$vmid" --hookscript "local:snippets/runner-hookscript.sh" \
            200>&- \
            201>&- \
            202>&- \
            203>&- \
            204>&- \
            || log_warn "Failed to set hookscript on $vmid — VM will not auto-recycle"
    fi

    if pool_is_draining; then
        log_warn "clone_runner: pool drain became active while configuring $name, cleaning up VM $vmid"
        _fail
        _pool_lock_release
        return 1
    fi

    # Start
    if ! qm start "$vmid" 200>&- 201>&- 202>&- 203>&- 204>&-; then
        _fail
        _pool_lock_release
        return 1
    fi

    _pool_lock_release
    echo "$vmid"
}
