#!/bin/bash
# Editable saved settings for setup; an empty answer always uses the standard default.
declare -A SETUP_PREFILLS=()

load_setup_prefills() {
    local key
    # These locals are read indirectly through ${!key} after sourcing the config.
    # shellcheck disable=SC2034
    local NETWORK_BRIDGE="" VLAN_TAG="" VM_STORAGE="" TEMPLATE_ID=""
    # shellcheck disable=SC2034
    local MIN_VMID="" BALLOON="" DNS_SERVERS="" DOCKER_MIRROR_URL=""
    SETUP_PREFILLS=()
    [[ -f "$CONFIG_FILE" ]] || return 0
    # This is the same trusted, root-owned shell config used by load_infra_config.
    # Keep its settings local until the operator answers each prompt.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || return 1
    for key in NETWORK_BRIDGE VLAN_TAG VM_STORAGE TEMPLATE_ID MIN_VMID BALLOON DNS_SERVERS DOCKER_MIRROR_URL; do
        SETUP_PREFILLS["$key"]="${!key}"
    done
}

prompt_setup_value() {
    local key="$1" label="$2" default="$3" answer prefill
    prefill="${SETUP_PREFILLS[$key]:-}"
    if [[ -t 0 && -n "$prefill" ]]; then
        read -e -r -i "$prefill" -p "$label [${default:-none}]: " answer || return 1
    else
        read -r -p "$label [${default:-none}]: " answer || return 1
    fi
    printf -v "$key" '%s' "${answer:-$default}"
}
