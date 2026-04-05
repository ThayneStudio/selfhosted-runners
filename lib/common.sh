#!/bin/bash
set -euo pipefail
# Common functions and constants shared across all runner scripts

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1" >&2; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2; }

# Resolve symlinks to find real script location
_resolve_source() {
    local source="$1"
    while [[ -L "$source" ]]; do
        local dir="$(cd "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$dir/$source"
    done
    echo "$source"
}

COMMON_SOURCE="$(_resolve_source "${BASH_SOURCE[0]}")"
LIB_DIR="$(cd "$(dirname "$COMMON_SOURCE")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"

# Path constants
CONFIG_FILE="/etc/github-runners.conf"
ORG_CONFIG_DIR="/etc/github-runners.d"
RUNNERS_DIR="/etc/github-runners.d/runners"
SNIPPETS_DIR="/var/lib/vz/snippets"
INSTALL_DIR="/opt/selfhosted-runners"
LOCK_FILE="/var/lock/github-runner.lock"

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command must be run as root"
        echo "Try: sudo runner ${1:-}" >&2
        exit 1
    fi
}

# Validate an org name contains only safe characters for use in paths
validate_org_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# Load infra configuration (bridge, storage, template)
load_infra_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration not found at $CONFIG_FILE"
        log_error "Run 'runner setup' first."
        exit 1
    fi
    migrate_config_if_needed
    source "$CONFIG_FILE"
    for var in NETWORK_BRIDGE VM_STORAGE TEMPLATE_ID; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Missing required config variable: $var"
            log_error "Re-run 'runner setup' to fix configuration."
            exit 1
        fi
    done
}

# Load a specific org's configuration
load_org_config() {
    local org_name="$1"
    if ! validate_org_name "$org_name"; then
        log_error "Invalid organization name: $org_name"
        exit 1
    fi
    local org_file="$ORG_CONFIG_DIR/${org_name}.conf"
    if [[ ! -f "$org_file" ]]; then
        log_error "Organization '$org_name' not configured"
        log_error "Run 'runner add-org' to add it."
        exit 1
    fi
    source "$org_file"
    if [[ -z "${GITHUB_ORG:-}" || -z "${GITHUB_PAT:-}" ]]; then
        log_error "Invalid org config for '$org_name' — missing GITHUB_ORG or GITHUB_PAT"
        exit 1
    fi
}

# List configured org names
list_orgs() {
    local orgs=()
    if [[ -d "$ORG_CONFIG_DIR" ]]; then
        for f in "$ORG_CONFIG_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            orgs+=("$(basename "$f" .conf)")
        done
    fi
    if [[ ${#orgs[@]} -gt 0 ]]; then
        printf '%s\n' "${orgs[@]}"
    fi
}

# Select an org — auto-select if one, prompt if multiple
# Usage: SELECTED_ORG=$(select_org "$org_flag") || exit 1
select_org() {
    local org_flag="${1:-}"
    local orgs
    mapfile -t orgs < <(list_orgs)

    if [[ ${#orgs[@]} -eq 0 ]]; then
        log_error "No organizations configured."
        log_error "Run 'runner add-org' to add one."
        exit 1
    fi

    # If --org flag was provided, validate and use it
    if [[ -n "$org_flag" ]]; then
        if ! validate_org_name "$org_flag"; then
            log_error "Invalid organization name: $org_flag"
            exit 1
        fi
        local org_file="$ORG_CONFIG_DIR/${org_flag}.conf"
        if [[ ! -f "$org_file" ]]; then
            log_error "Organization '$org_flag' not configured"
            log_error "Available orgs: ${orgs[*]}"
            exit 1
        fi
        echo "$org_flag"
        return
    fi

    # Auto-select if only one org
    if [[ ${#orgs[@]} -eq 1 ]]; then
        echo "${orgs[0]}"
        return
    fi

    # Multiple orgs — prompt user to select
    echo "" >&2
    echo "Multiple organizations configured:" >&2
    local i
    for i in "${!orgs[@]}"; do
        echo "  $((i + 1))) ${orgs[$i]}" >&2
    done
    echo "" >&2

    while true; do
        echo -n "Select organization (number or name): " >&2
        if ! read -r choice </dev/tty; then
            log_error "No input received"
            exit 1
        fi
        # Try as number first
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#orgs[@]} ]]; then
            echo "${orgs[$((choice - 1))]}"
            return
        fi
        # Try as org name
        for org in "${orgs[@]}"; do
            if [[ "$org" == "$choice" ]]; then
                echo "$choice"
                return
            fi
        done
        log_error "Invalid selection: $choice"
    done
}

# Get the org name for a VM from its cicustom config
get_vm_org() {
    local vmid="$1"
    local cicustom
    cicustom=$(qm config "$vmid" 2>/dev/null | grep "^cicustom:" || true)

    if [[ -z "$cicustom" ]]; then
        echo "unknown"
        return
    fi

    # Match runner-user-data-<org>.yaml pattern
    if [[ "$cicustom" =~ runner-user-data-([^.]+)\.yaml ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi

    # Legacy: runner-user-data.yaml (no org suffix)
    if [[ "$cicustom" =~ runner-user-data\.yaml ]]; then
        # If there's exactly one org configured, assume it's that one
        local orgs
        mapfile -t orgs < <(list_orgs)
        if [[ ${#orgs[@]} -eq 1 ]]; then
            echo "${orgs[0]}"
        else
            echo "unknown"
        fi
        return
    fi

    echo "unknown"
}

# Migrate old single-org config to new multi-org format
migrate_config_if_needed() {
    # Check if old format (GITHUB_ORG in main config)
    if ! grep -q '^GITHUB_ORG=' "$CONFIG_FILE" 2>/dev/null; then
        return
    fi

    # Migration writes to /etc — requires root
    if [[ $EUID -ne 0 ]]; then
        log_warn "Config migration needed but not running as root. Run 'sudo runner setup' to migrate."
        return
    fi

    log_info "Migrating configuration to multi-org format..."

    # Extract values safely without eval
    local old_org="" old_pat=""
    old_org=$(grep '^GITHUB_ORG=' "$CONFIG_FILE" | head -1 | sed 's/^GITHUB_ORG=//' | tr -d '"' || true)
    old_pat=$(grep '^GITHUB_PAT=' "$CONFIG_FILE" | head -1 | sed 's/^GITHUB_PAT=//' | tr -d '"' || true)

    if [[ -z "$old_org" ]]; then
        log_warn "Could not read GITHUB_ORG from old config, skipping migration"
        return
    fi

    # Validate org name is safe for use in file paths
    if ! validate_org_name "$old_org"; then
        log_warn "Org name '$old_org' contains invalid characters, skipping migration"
        return
    fi

    # Create org config directory
    mkdir -p "$ORG_CONFIG_DIR"
    chmod 700 "$ORG_CONFIG_DIR"

    # Skip writing org config if already migrated (idempotent)
    if [[ -f "$ORG_CONFIG_DIR/${old_org}.conf" ]]; then
        log_info "Org config already exists at $ORG_CONFIG_DIR/${old_org}.conf, stripping old keys from main config"
    else
        # Write per-org config
        printf 'GITHUB_ORG="%s"\nGITHUB_PAT="%s"\nRUNNER_PREFIX="runner"\nRUNNER_COUNT="2"\n' "$old_org" "$old_pat" > "$ORG_CONFIG_DIR/${old_org}.conf"
        chmod 600 "$ORG_CONFIG_DIR/${old_org}.conf"
    fi

    # Rewrite main config without org/PAT, preserving permissions
    local tmp_conf
    tmp_conf=$(grep -v '^GITHUB_ORG=' "$CONFIG_FILE" | grep -v '^GITHUB_PAT=' || true)
    printf '%s\n' "$tmp_conf" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    # Copy cloud-init snippet to org-specific name (keep original for existing VMs)
    if [[ -f "$SNIPPETS_DIR/runner-user-data.yaml" && ! -f "$SNIPPETS_DIR/runner-user-data-${old_org}.yaml" ]]; then
        cp "$SNIPPETS_DIR/runner-user-data.yaml" "$SNIPPETS_DIR/runner-user-data-${old_org}.yaml"
        chmod 600 "$SNIPPETS_DIR/runner-user-data-${old_org}.yaml"
    fi

    log_info "Migrated org '$old_org' to $ORG_CONFIG_DIR/${old_org}.conf"
}

# Deregister a runner from GitHub (best-effort, non-fatal)
# Removes the runner registration so it doesn't linger as "Offline" in the GitHub UI.
deregister_runner() {
    local org="$1"
    local runner_name="$2"

    # Load org config to get PAT
    local org_file="$ORG_CONFIG_DIR/${org}.conf"
    [[ -f "$org_file" ]] || return 0

    # Source org config in a subshell to avoid polluting caller's scope
    local pat="" github_org=""
    pat=$(source "$org_file" && echo "$GITHUB_PAT") || return 0
    github_org=$(source "$org_file" && echo "$GITHUB_ORG") || return 0
    [[ -n "$pat" && -n "$github_org" ]] || return 0

    # Find runner ID by name (pass auth via file descriptor to avoid PAT in /proc/PID/cmdline)
    local runner_id
    runner_id=$(curl -sf --max-time 10 \
        -H "Accept: application/vnd.github.v3+json" \
        --config <(printf 'header = "Authorization: token %s"\n' "$pat") \
        "https://api.github.com/orgs/${github_org}/actions/runners" 2>/dev/null \
        | jq --arg name "$runner_name" -r '.runners[] | select(.name == $name) | .id' 2>/dev/null) || return 0

    [[ -n "$runner_id" && "$runner_id" != "null" && "$runner_id" =~ ^[0-9]+$ ]] || return 0

    # Delete the runner
    curl -sf --max-time 10 -X DELETE \
        -H "Accept: application/vnd.github.v3+json" \
        --config <(printf 'header = "Authorization: token %s"\n' "$pat") \
        "https://api.github.com/orgs/${github_org}/actions/runners/${runner_id}" 2>/dev/null || return 0
}
