#!/usr/bin/env bash
# Runner VMs keep the DNS servers DHCP offers only while DNS_SERVERS is empty,
# and setup must be able to store that. An empty answer selects the default,
# so the answer "dhcp" (any case) stores an empty value, the label says so,
# and a saved empty value is prefilled as "dhcp" so that Enter keeps it.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'setup2-dns-prompt: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/setup-prompts.sh
source "$root/lib/setup-prompts.sh"
fail() { printf 'setup2-dns-prompt: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
CONFIG_FILE=$state/config
public='1.1.1.1 8.8.8.8'

# --- "dhcp" stores the empty value that keeps the DHCP servers ---
for answer in dhcp DHCP ' Dhcp '; do
    DNS_SERVERS=unchanged
    prompt_dns_servers "$public" <<< "$answer"
    [[ -z "$DNS_SERVERS" ]] || fail "the answer '$answer' stored '$DNS_SERVERS', not an empty DNS_SERVERS"
done
prompt_dns_servers "$public" <<< ''
[[ "$DNS_SERVERS" == "$public" ]] || fail "an empty answer did not select the default"
prompt_dns_servers "$public" <<< '10.0.0.53 10.0.0.54'
[[ "$DNS_SERVERS" == '10.0.0.53 10.0.0.54' ]] || fail "explicit nameservers were changed"
# Setup's address check rejects this; it is not the dhcp answer.
prompt_dns_servers "$public" <<< 'dhcp 10.0.0.53'
[[ "$DNS_SERVERS" == 'dhcp 10.0.0.53' ]] || fail "a list containing dhcp was rewritten"
if prompt_dns_servers "$public" < /dev/null; then
    fail "end of input was silently treated as an answer"
fi

# --- The label tells the operator about the dhcp answer ---
(
    prompt_setup_value() { printf '%s\n' "$2" > "$state/label"; printf -v "$1" '%s' "$3"; }
    prompt_dns_servers "$public"
)
grep -qiF 'dhcp' "$state/label" || fail "the DNS prompt does not mention the dhcp answer: $(cat "$state/label")"

# --- A saved empty value is prefilled as dhcp, so Enter keeps it ---
printf "NETWORK_BRIDGE=vmbr0\nDNS_SERVERS=''\n" > "$CONFIG_FILE"
load_setup_prefills
[[ "${SETUP_PREFILLS[DNS_SERVERS]}" == dhcp ]] || fail "a saved empty DNS_SERVERS was not prefilled as dhcp"
DNS_SERVERS=unchanged
prompt_dns_servers "$public" <<< "${SETUP_PREFILLS[DNS_SERVERS]}"
[[ -z "$DNS_SERVERS" ]] || fail "keeping the prefilled answer stored '$DNS_SERVERS'"
# Clones read a missing key as empty too.
printf 'NETWORK_BRIDGE=vmbr0\n' > "$CONFIG_FILE"
load_setup_prefills
[[ "${SETUP_PREFILLS[DNS_SERVERS]}" == dhcp ]] || fail "a config without DNS_SERVERS was not prefilled as dhcp"
printf 'DNS_SERVERS=10.0.0.53\\ 10.0.0.54\n' > "$CONFIG_FILE"
load_setup_prefills
[[ "${SETUP_PREFILLS[DNS_SERVERS]}" == '10.0.0.53 10.0.0.54' ]] || fail "saved nameservers were not prefilled"
rm -f "$CONFIG_FILE"
load_setup_prefills
[[ -z "${SETUP_PREFILLS[DNS_SERVERS]+set}" ]] || fail "a fresh install prefilled the DNS answer"

# --- The wizard asks through prompt_dns_servers ---
grep -qx 'prompt_dns_servers "1.1.1.1 8.8.8.8"' "$root/lib/setup.sh" || fail "setup.sh does not use prompt_dns_servers"
if grep -q 'prompt_setup_value DNS_SERVERS' "$root/lib/setup.sh"; then
    fail "setup.sh asks for DNS_SERVERS without the dhcp answer"
fi

printf 'setup2-dns-prompt: ok\n'
