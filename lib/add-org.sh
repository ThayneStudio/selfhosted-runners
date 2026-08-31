#!/bin/bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

require_root "add-org"

# Clean up temp files on exit
CONF_TMP=""
cleanup() {
    [[ -n "$CONF_TMP" ]] && rm -f "$CONF_TMP" || true
}
trap cleanup EXIT

# Require config file exists (infra must be set up)
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration not found. Run 'runner setup' first."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

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
        log_error "Invalid organization name. Use only letters, numbers, and hyphens (no leading/trailing hyphen)."
        continue
    fi
    break
done

# Check if org already exists
if [[ -f "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf" ]]; then
    log_warn "Organization '$GITHUB_ORG' is already configured."
    log_warn "JIT configs are minted per-VM at clone time, so the new PAT takes"
    log_warn "effect on the next clone (no existing runner stores the PAT)."
    read -rp "Update its PAT? [y/N]: " UPDATE
    if [[ ! "${UPDATE:-N}" =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Collect and validate GitHub PAT.
# Either a classic PAT with 'admin:org', or — least privilege, preferred — a
# fine-grained PAT scoped to this org with 'Self-hosted runners: Read and write'.
echo ""
echo "PAT options:"
echo "  - Classic PAT with 'admin:org' scope, OR"
echo "  - Fine-grained PAT for this org with 'Self-hosted runners: Read and write' (least privilege)"
while true; do
    read -rsp "GitHub PAT: " GITHUB_PAT
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

# Validate the PAT against the runner API (not just GET /orgs, which any token
# that can see the org passes). Listing org runners needs runner READ access
# (classic 'admin:org' or fine-grained 'Self-hosted runners: Read), so this
# catches a wrong org or a token with no runner access, and works for a
# least-privilege fine-grained token. Caveat: the mint needs runner WRITE, which
# this read probe can't confirm — a read-only fine-grained token passes here and
# fails at the first clone. Probing generate-jitconfig would confirm write but
# would create (and need to clean up) a throwaway runner; not worth it here.
log_info "Validating PAT with GitHub API..."
# Pass auth header via file descriptor to avoid leaking PAT in /proc/PID/cmdline
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -H "Accept: application/vnd.github+json" \
    --config <(printf 'header = "Authorization: token %s"\n' "$GITHUB_PAT") \
    "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners?per_page=1") || {
    log_error "Failed to reach GitHub API (network error or DNS failure)"
    log_error "Check your internet connectivity and try again."
    exit 1
}

if [[ "$HTTP_CODE" != "200" ]]; then
    log_error "GitHub API returned HTTP $HTTP_CODE for org '$GITHUB_ORG'"
    if [[ "$HTTP_CODE" == "403" || "$HTTP_CODE" == "404" ]]; then
        log_error "The PAT lacks runner access to this org. Grant classic 'admin:org',"
        log_error "or fine-grained 'Self-hosted runners: Read and write' for this org."
    fi
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

# Reject a prefix already used by another org — slot names ${prefix}-${n} would
# collide and the two pools would fight over the same VMs. generate-jitconfig
# 409s on a duplicate name, and the mint-retry then deregisters the other org's
# runner.
for other_conf in "$ORG_CONFIG_DIR"/*.conf; do
    [[ -f "$other_conf" ]] || continue
    other_org=$(basename "$other_conf" .conf)
    [[ "$other_org" == "$GITHUB_ORG" ]] && continue
    other_prefix=$(grep '^RUNNER_PREFIX=' "$other_conf" 2>/dev/null | head -1 | sed 's/^RUNNER_PREFIX=//' | tr -d '"') || true
    if [[ "${other_prefix:-runner}" == "$RUNNER_PREFIX" ]]; then
        log_error "Prefix '$RUNNER_PREFIX' is already used by org '$other_org' — slot names would collide."
        log_error "Choose a different prefix."
        exit 1
    fi
done

read -rp "Number of runners for this org [${EXISTING_COUNT:-2}]: " RUNNER_COUNT
RUNNER_COUNT=${RUNNER_COUNT:-${EXISTING_COUNT:-2}}
if [[ ! "$RUNNER_COUNT" =~ ^[0-9]+$ ]] || [[ "$RUNNER_COUNT" -lt 1 || "$RUNNER_COUNT" -gt 50 ]]; then
    log_error "Runner count must be between 1 and 50"
    exit 1
fi

# Runner names (and thus the VM hostname) must fit in 63 chars: "${prefix}-${n}"
if (( ${#RUNNER_PREFIX} + 1 + ${#RUNNER_COUNT} > 63 )); then
    log_error "Prefix too long: '${RUNNER_PREFIX}-${RUNNER_COUNT}' exceeds the 63-char hostname limit"
    exit 1
fi

# Runner group ID for JIT config. 1 is the org's "Default" group; change it only
# if you target a custom runner group (find the ID via the GitHub API/UI).
EXISTING_GROUP=""
if [[ -f "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf" ]]; then
    EXISTING_GROUP=$(grep '^RUNNER_GROUP_ID=' "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf" 2>/dev/null | head -1 | sed 's/^RUNNER_GROUP_ID=//' | tr -d '"') || true
fi
read -rp "Runner group ID [${EXISTING_GROUP:-1}]: " RUNNER_GROUP_ID
RUNNER_GROUP_ID=${RUNNER_GROUP_ID:-${EXISTING_GROUP:-1}}
if [[ ! "$RUNNER_GROUP_ID" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Runner group ID must be a positive number (1 = Default group)"
    exit 1
fi

# Save org config atomically. The PAT stays on the host; per-VM cloud-init
# snippets carrying a single-use JIT config are rendered at clone time.
mkdir -p "$ORG_CONFIG_DIR"
chmod 700 "$ORG_CONFIG_DIR"
CONF_TMP=$(mktemp "$ORG_CONFIG_DIR/.${GITHUB_ORG}.XXXXXX")
printf 'GITHUB_ORG="%s"\nGITHUB_PAT="%s"\nRUNNER_PREFIX="%s"\nRUNNER_COUNT="%s"\nRUNNER_GROUP_ID="%s"\n' "$GITHUB_ORG" "$GITHUB_PAT" "$RUNNER_PREFIX" "$RUNNER_COUNT" "$RUNNER_GROUP_ID" > "$CONF_TMP"
chmod 600 "$CONF_TMP"
mv "$CONF_TMP" "$ORG_CONFIG_DIR/${GITHUB_ORG}.conf"
CONF_TMP=""

echo ""
log_info "Organization '$GITHUB_ORG' configured successfully"
echo ""
echo "View runners in GitHub:"
echo "  https://github.com/organizations/$GITHUB_ORG/settings/actions/runners"
echo ""
