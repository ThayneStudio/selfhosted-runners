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
    # Same precedence as load_infra_config: an explicit bake limit on this run
    # stays, and one the environment left unset takes the conf's value so the
    # setup bake uses it.
    if [[ -v BAKE_TIMEOUT ]]; then
        # shellcheck disable=SC2034 # shadows the caller's value across source
        local BAKE_TIMEOUT="$BAKE_TIMEOUT"
    fi
    if [[ -v BAKE_MIN_FREE_GIB ]]; then
        # shellcheck disable=SC2034
        local BAKE_MIN_FREE_GIB="$BAKE_MIN_FREE_GIB"
    fi
    if [[ -v BAKE_FREE_FLOOR_GIB ]]; then
        # shellcheck disable=SC2034
        local BAKE_FREE_FLOOR_GIB="$BAKE_FREE_FLOOR_GIB"
    fi
    SETUP_PREFILLS=()
    [[ -f "$CONFIG_FILE" ]] || return 0
    # This is the same trusted, root-owned shell config used by load_infra_config.
    # Keep its settings local until the operator answers each prompt.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || return 1
    for key in NETWORK_BRIDGE VLAN_TAG VM_STORAGE TEMPLATE_ID MIN_VMID BALLOON DNS_SERVERS DOCKER_MIRROR_URL; do
        SETUP_PREFILLS["$key"]="${!key}"
    done
    # An empty DNS_SERVERS keeps the DHCP servers. Prefill the answer that
    # stores it, or Enter would select the default instead.
    if [[ -z "${SETUP_PREFILLS[DNS_SERVERS]}" ]]; then
        SETUP_PREFILLS[DNS_SERVERS]=dhcp
    fi
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

# An empty answer selects the default, so "dhcp" (any case) is the answer that
# stores an empty DNS_SERVERS: runner VMs then keep the servers DHCP offers.
prompt_dns_servers() {
    prompt_setup_value DNS_SERVERS "DNS nameservers, space-separated, or dhcp to use the DHCP servers" "$1" || return 1
    if [[ "${DNS_SERVERS,,}" == dhcp ]]; then
        DNS_SERVERS=""
    fi
}
