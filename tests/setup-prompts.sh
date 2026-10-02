#!/usr/bin/env bash
set -euo pipefail
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup-prompts: bash 4+ is required\n' >&2
    exit 1
fi
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup-prompts.sh
source "$root/lib/setup-prompts.sh"
fail() { printf 'setup-prompts: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
CONFIG_FILE=$state/config
load_setup_prefills
[[ ${#SETUP_PREFILLS[@]} == 0 ]] || fail "missing config supplied saved settings"
cat > "$CONFIG_FILE" <<'EOF'
NETWORK_BRIDGE=vmbr7
VLAN_TAG=42
VM_STORAGE=fast-zfs
TEMPLATE_ID=9100
MIN_VMID=0
BALLOON=2048
DNS_SERVERS=10.0.0.1\ 10.0.0.2
DOCKER_MIRROR_URL=http://10.20.1.19:8080
EOF
cp "$CONFIG_FILE" "$state/original"
NETWORK_BRIDGE=unchanged
load_setup_prefills
[[ "$NETWORK_BRIDGE" == unchanged ]] || fail "loading prefills changed an unanswered setting"
[[ "${SETUP_PREFILLS[NETWORK_BRIDGE]}" == vmbr7 ]] || fail "saved bridge was missed"
[[ "${SETUP_PREFILLS[MIN_VMID]}" == 0 ]] || fail "saved zero was missed"
[[ "${SETUP_PREFILLS[DNS_SERVERS]}" == '10.0.0.1 10.0.0.2' ]] || fail "escaped DNS list was not loaded"
[[ "${SETUP_PREFILLS[DOCKER_MIRROR_URL]}" == http://10.20.1.19:8080 ]] || fail "saved mirror was missed"

# Empty actual input keeps the standard defaults, even when a saved value exists.
declare -A defaults=([NETWORK_BRIDGE]=vmbr0 [VLAN_TAG]="" [VM_STORAGE]=local-zfs
    [TEMPLATE_ID]=9000 [MIN_VMID]=9001 [BALLOON]=0
    [DNS_SERVERS]='1.1.1.1 8.8.8.8' [DOCKER_MIRROR_URL]="")
for key in "${!defaults[@]}"; do
    prompt_setup_value "$key" "$key" "${defaults[$key]}" <<< ''
    [[ "${!key}" == "${defaults[$key]}" ]] || fail "empty $key did not select the standard default"
done
prompt_setup_value TEMPLATE_ID 'Template VM ID' 9000 <<< 9200
prompt_setup_value MIN_VMID 'Minimum VM ID' "$((TEMPLATE_ID + 1))" <<< ''
[[ "$MIN_VMID" == 9201 ]] || fail "minimum VMID default did not follow the chosen template"
prompt_setup_value MIN_VMID 'Minimum VM ID' 9001 <<< 0
[[ "$MIN_VMID" == 0 ]] || fail "explicit zero did not override the default"
prompt_setup_value DNS_SERVERS 'DNS servers' '1.1.1.1 8.8.8.8' <<< '10.1.1.1 10.1.1.2'
[[ "$DNS_SERVERS" == '10.1.1.1 10.1.1.2' ]] || fail "explicit DNS list was changed"
if prompt_setup_value NETWORK_BRIDGE 'Network bridge' vmbr0 < /dev/null; then
    fail "end of input was silently treated as a default"
fi
cmp -s "$CONFIG_FILE" "$state/original" || fail "prompts rewrote the saved config"

# Partial and explicitly empty saved settings must not inherit previous answers.
printf 'NETWORK_BRIDGE=vmbr8\nVLAN_TAG=\047\047\n' > "$CONFIG_FILE"
load_setup_prefills
[[ "${SETUP_PREFILLS[NETWORK_BRIDGE]}" == vmbr8 ]] || fail "partial config bridge was missed"
[[ -z "${SETUP_PREFILLS[VLAN_TAG]}" && -z "${SETUP_PREFILLS[DOCKER_MIRROR_URL]}" ]] || fail "partial config inherited old settings"
printf 'setup-prompts: ok\n'
