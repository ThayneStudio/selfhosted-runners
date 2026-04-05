#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "add-org"

# Clean up temp files on exit
SNIPPET_TMP=""
CONF_TMP=""
cleanup() {
    [[ -n "$SNIPPET_TMP" ]] && rm -f "$SNIPPET_TMP" || true
    [[ -n "$CONF_TMP" ]] && rm -f "$CONF_TMP" || true
}
trap cleanup EXIT

# Require config file exists (infra must be set up)
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration not found. Run 'runner setup' first."
    exit 1
fi

# Verify template file exists
if [[ ! -f "$INSTALL_DIR/templates/runner-user-data.yaml" ]]; then
    log_error "Template not found at $INSTALL_DIR/templates/runner-user-data.yaml"
    log_error "Run 'runner setup' to install."
    exit 1
fi

echo ""
echo "=== Add GitHub Organization ==="
echo ""

# Collect and validate GitHub Organization
while true; do
    read -rp "GitHub Organization name: " GITHUB_ORG
    if [[ -z "$GITHUB_ORG" ]]; then
        log_error "Organization name cannot be empty"
        continue
    fi
    if ! validate_org_name "$GITHUB_ORG"; then
        log_error "Invalid organization name. Use only letters, numbers, hyphens, underscores."
        continue
    fi
    break
done

# Check if org already exists
if [[ -f "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf" ]]; then
    log_warn "Organization '$GITHUB_ORG' is already configured."
    log_warn "Existing runners will keep using the old PAT until re-created."
    read -rp "Update its PAT? [y/N]: " UPDATE
    if [[ ! "${UPDATE:-N}" =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Collect and validate GitHub PAT
while true; do
    read -rsp "GitHub PAT (admin:org scope): " GITHUB_PAT
    echo ""
    if [[ -z "$GITHUB_PAT" ]]; then
        log_error "PAT cannot be empty"
        continue
    fi
    # Reject characters that could cause injection when config is sourced
    if [[ "$GITHUB_PAT" =~ [\"\$\`\\] ]]; then
        log_error "PAT contains invalid characters"
        continue
    fi
    if [[ ! "$GITHUB_PAT" =~ ^(ghp_|github_pat_) ]]; then
        log_warn "PAT doesn't start with 'ghp_' or 'github_pat_'. Make sure it's valid."
        read -rp "Continue anyway? [y/N]: " CONTINUE
        [[ "${CONTINUE:-N}" =~ ^[Yy]$ ]] || continue
    fi
    break
done

# Validate PAT by testing GitHub API
log_info "Validating PAT with GitHub API..."
# Pass auth header via file descriptor to avoid leaking PAT in /proc/PID/cmdline
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -H "Accept: application/vnd.github.v3+json" \
    --config <(printf 'header = "Authorization: token %s"\n' "$GITHUB_PAT") \
    "https://api.github.com/orgs/${GITHUB_ORG}") || {
    log_error "Failed to reach GitHub API (network error or DNS failure)"
    log_error "Check your internet connectivity and try again."
    exit 1
}

if [[ "$HTTP_CODE" != "200" ]]; then
    log_error "GitHub API returned HTTP $HTTP_CODE"
    log_error "Check that your PAT has 'admin:org' scope and the organization name is correct."
    exit 1
fi
log_info "PAT validated successfully"

# Runner pool configuration (pre-populate from existing config if updating)
EXISTING_PREFIX=""
EXISTING_COUNT=""
if [[ -f "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf" ]]; then
    EXISTING_PREFIX=$(grep '^RUNNER_PREFIX=' "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf" 2>/dev/null | head -1 | sed 's/^RUNNER_PREFIX=//' | tr -d '"') || true
    EXISTING_COUNT=$(grep '^RUNNER_COUNT=' "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf" 2>/dev/null | head -1 | sed 's/^RUNNER_COUNT=//' | tr -d '"') || true
fi

read -rp "Runner name prefix [${EXISTING_PREFIX:-runner}]: " RUNNER_PREFIX
RUNNER_PREFIX=${RUNNER_PREFIX:-${EXISTING_PREFIX:-runner}}
if [[ ! "$RUNNER_PREFIX" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    log_error "Invalid prefix. Use only letters, numbers, dots, hyphens, underscores."
    exit 1
fi

read -rp "Number of runners for this org [${EXISTING_COUNT:-2}]: " RUNNER_COUNT
RUNNER_COUNT=${RUNNER_COUNT:-${EXISTING_COUNT:-2}}
if [[ ! "$RUNNER_COUNT" =~ ^[0-9]+$ ]] || [[ "$RUNNER_COUNT" -lt 1 || "$RUNNER_COUNT" -gt 50 ]]; then
    log_error "Runner count must be between 1 and 50"
    exit 1
fi

# Generate cloud-init snippet from template using awk (avoids PAT in process list)
log_info "Generating cloud-init snippet for '$GITHUB_ORG'..."
mkdir -p "$SNIPPETS_DIR"
SNIPPET_TMP=$(mktemp "$SNIPPETS_DIR/.runner-user-data-${GITHUB_ORG}.XXXXXX")
chmod 600 "$SNIPPET_TMP"
GITHUB_PAT="$GITHUB_PAT" GITHUB_ORG="$GITHUB_ORG" awk '
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
    $0 = lreplace($0, "{{GITHUB_PAT}}", ENVIRON["GITHUB_PAT"])
    $0 = lreplace($0, "{{GITHUB_ORG}}", ENVIRON["GITHUB_ORG"])
    print
}' "$INSTALL_DIR/templates/runner-user-data.yaml" > "$SNIPPET_TMP" || {
    log_error "Failed to generate cloud-init snippet"
    exit 1
}
mv "$SNIPPET_TMP" "$SNIPPETS_DIR/runner-user-data-${GITHUB_ORG}.yaml"
chmod 600 "$SNIPPETS_DIR/runner-user-data-${GITHUB_ORG}.yaml"
SNIPPET_TMP=""

# Save org config atomically
mkdir -p "$ORG_CONFIG_DIR"
chmod 700 "$ORG_CONFIG_DIR"
CONF_TMP=$(mktemp "$ORG_CONFIG_DIR/.${GITHUB_ORG}.XXXXXX")
printf 'GITHUB_ORG="%s"\nGITHUB_PAT="%s"\nRUNNER_PREFIX="%s"\nRUNNER_COUNT="%s"\n' "$GITHUB_ORG" "$GITHUB_PAT" "$RUNNER_PREFIX" "$RUNNER_COUNT" > "$CONF_TMP"
chmod 600 "$CONF_TMP"
mv "$CONF_TMP" "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf"
CONF_TMP=""

echo ""
log_info "Organization '$GITHUB_ORG' configured successfully"
echo ""
echo "View runners in GitHub:"
echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
echo ""
