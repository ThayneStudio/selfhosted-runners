#!/bin/bash
set -euo pipefail
# Re-clone a runner. Called by the hookscript after destroying a VM.
# Usage: reclone.sh <name> <org>

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
load_infra_config
load_org_config "$2"
clone_runner "$1" "$2" >/dev/null
log_info "Re-cloned $1 for org $2"
