#!/usr/bin/env bash
# Boots a clone's /opt/register-runner.sh the way cloud-init would: render the
# per-VM user-data with the real render_user_snippet, write every write_files
# entry under a scratch root, then run the script there with the system
# commands it calls mocked on PATH. Checks the Docker mirror configuration,
# the DNS_SERVERS check with its DHCP fallback, and the hold after GitHub
# refuses the runner version.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'guest2-register-runner: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'guest2-register-runner: %s\n' "$1" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

write_file_paths() {
    awk '/^  - path: / { print $3 }' "$1"
}
# One write_files entry's content, with the block scalar indentation removed.
write_file_content() {
    awk -v want="$2" '
        /^  - path: / { inside = ($3 == want); body = 0; next }
        inside && /^    content: \|/ { body = 1; next }
        body && $0 == "" { print; next }
        body && substr($0, 1, 6) != "      " { body = 0; inside = 0 }
        body { print substr($0, 7) }
    ' "$1"
}
# Move the absolute paths a guest script uses under the scratch root. Mark
# first, then substitute, so a root that is itself under /var is not rewritten.
in_guest_root() {
    local text="$1" guest="$2" dir
    for dir in etc opt home var; do
        text=${text//\/$dir\//$'\001'$dir/}
    done
    printf '%s' "${text//$'\001'/$guest/}"
}
install_write_files() {
    local user_data="$1" guest="$2" path content
    while IFS= read -r path; do
        content=$(write_file_content "$user_data" "$path")
        if [[ "$path" == /opt/register-runner.sh ]]; then
            content=$(in_guest_root "$content" "$guest")
        fi
        mkdir -p "$guest$(dirname "$path")"
        printf '%s\n' "$content" > "$guest$path"
    done < <(write_file_paths "$user_data")
}

bin=$work/bin
mkdir -p "$bin"
cat > "$bin/shutdown" <<'EOF'
#!/bin/bash
printf 'shutdown %s\n' "$*" >> "$GUEST_STATE/calls"
EOF
cat > "$bin/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$GUEST_STATE/calls"
EOF
# Also records what /opt holds while the guest waits.
cat > "$bin/sleep" <<'EOF'
#!/bin/bash
printf 'sleep %s\n' "$*" >> "$GUEST_STATE/calls"
ls -A "$GUEST_ROOT/opt" > "$GUEST_STATE/opt-while-sleeping"
EOF
cat > "$bin/timeout" <<'EOF'
#!/bin/bash
printf 'timeout %s\n' "$*" >> "$GUEST_STATE/calls"
shift
exec "$@"
EOF
# dns-lookup NAME: 0 when one of eth0's DNS servers ($GUEST_STATE/link-dns)
# answers for NAME. Each line of $GUEST_STATE/resolvers is a server that
# answers on this network, then the names it resolves.
cat > "$bin/dns-lookup" <<'EOF'
#!/bin/bash
read -ra servers < "$GUEST_STATE/link-dns"
for server in "${servers[@]}"; do
    awk -v s="$server" -v n="$1" '$1 == s { for (i = 2; i <= NF; i++) if ($i == n) found = 1 } END { exit !found }' \
        "$GUEST_STATE/resolvers" && exit 0
done
exit 1
EOF
# eth0 starts with the servers DHCP offered: dns replaces them, revert
# restores them, and query looks a name up through them. The first
# $GUEST_STATE/query-failures queries fail, as a lost packet would.
cat > "$bin/resolvectl" <<'EOF'
#!/bin/bash
printf 'resolvectl %s\n' "$*" >> "$GUEST_STATE/calls"
case "$1" in
    status)
        # Like resolvectl, print no "DNS Servers:" line when the link has none.
        if [[ -s "$GUEST_STATE/link-dns" ]]; then
            printf 'Link 2 (eth0)\n       DNS Servers: %s\n' "$(cat "$GUEST_STATE/link-dns")"
        fi
        ;;
    dns) shift 2; printf '%s' "$*" > "$GUEST_STATE/link-dns" ;;
    revert) cp "$GUEST_STATE/dhcp-dns" "$GUEST_STATE/link-dns" ;;
    query)
        failures=$(cat "$GUEST_STATE/query-failures")
        if (( failures > 0 )); then
            printf '%s' "$((failures - 1))" > "$GUEST_STATE/query-failures"
            exit 1
        fi
        exec dns-lookup "${!#}"
        ;;
esac
EOF
cat > "$bin/ip" <<'EOF'
#!/bin/bash
printf 'default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.50 metric 100\n'
EOF
# https://github.com answers once eth0's DNS servers resolve it.
cat > "$bin/curl" <<'EOF'
#!/bin/bash
exec dns-lookup github.com
EOF
cat > "$bin/hostname" <<'EOF'
#!/bin/bash
printf 'runner-01\n'
EOF
# sudo resets the environment: the command sees only what its own command line
# passes with env VAR=... GUEST_STATE belongs to this harness.
cat > "$bin/sudo" <<'EOF'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec env -i PATH="$PATH" GUEST_STATE="$GUEST_STATE" "$@"
EOF
cat > "$work/run.sh" <<'EOF'
#!/bin/bash
printf 'run.sh\n' >> "$GUEST_STATE/calls"
printf '%s\n' "$@" > "$GUEST_STATE/run-args"
exit "$(cat "$GUEST_STATE/run-rc")"
EOF
chmod +x "$bin"/* "$work/run.sh"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
jit=$(b64 "$(jq -nc \
    --arg r "$(b64 '{"agentName":"runner-01","disableUpdate":false}')" \
    --arg c "$(b64 '{"scheme":"OAuth"}')" \
    '{".runner":$r,".credentials":$c}')")

INSTALL_DIR=$root
GITHUB_ORG=test-org
DOCKER_MIRROR_URL=""
DNS_SERVERS=""
# DHCP offers the gateway and the site resolver, which answers for every
# name the checks use. Public resolvers answer only where a check says so.
dhcp_dns="192.168.1.1 10.0.0.53"
site_resolver="10.0.0.53 github.com registry.example.com mirror zot.home.arpa"
resolvers=("$site_resolver")
query_failures=0
run_rc=0
# The HTTPS mirror the template was baked with, if any.
template_mirror=""

# hosts.toml that routes registry $1 through mirror $2, skipping certificate
# verification when $3 is 1.
mirror_toml() {
    printf 'server = "%s"\n\n[host."%s"]\n  capabilities = ["pull", "resolve"]' "$1" "$2"
    [[ "$3" == 0 ]] || printf '\n  skip_verify = true'
}
certs=etc/docker/certs.d
# What the bake leaves in /etc/docker for an IP-literal HTTPS mirror $1, plus
# a CA certificate beside the mirror's hosts.toml.
seed_template_mirror() {
    local registry="${1#https://}"
    mkdir -p "$guest/$certs/public.ecr.aws" "$guest/$certs/$registry"
    mirror_toml https://public.ecr.aws "$1" 1 > "$guest/$certs/public.ecr.aws/hosts.toml"
    mirror_toml "$1" "$1" 1 > "$guest/$certs/$registry/hosts.toml"
    printf 'internal CA\n' > "$guest/$certs/$registry/ca.crt"
    printf '{\n  "features": {\n    "containerd-snapshotter": true\n  }\n}\n' > "$guest/etc/docker/daemon.json"
}

# Render user-data from the settings above, write it into a fresh guest root,
# and run register-runner.sh there. Sets user_data, guest and state.
boot() {
    local name="$1"
    guest=$work/$name/root
    state=$work/$name/state
    mkdir -p "$guest/opt" "$guest/home/runner/actions-runner" "$state"
    : > "$state/calls"
    printf '%s' "$dhcp_dns" > "$state/dhcp-dns"
    cp "$state/dhcp-dns" "$state/link-dns"
    printf '%s\n' "${resolvers[@]}" > "$state/resolvers"
    printf '%s' "$query_failures" > "$state/query-failures"
    printf '%s\n' "$run_rc" > "$state/run-rc"
    [[ -z "$template_mirror" ]] || seed_template_mirror "$template_mirror"
    SNIPPETS_DIR=$work/$name
    render_user_snippet 9001 test-org "$jit" || fail "$name: render_user_snippet failed"
    user_data=$SNIPPETS_DIR/runner-9001-user-test-org.yaml
    install_write_files "$user_data" "$guest"
    cp "$work/run.sh" "$guest/home/runner/actions-runner/run.sh"
    printf '2.337.0\n' > "$guest/opt/.baked-runner-version"
    GUEST_STATE=$state GUEST_ROOT=$guest PATH="$bin:$PATH" "$BASH" "$guest/opt/register-runner.sh" \
        > "$state/out" 2>&1 || true
}
called() { grep -qxF -- "$1" "$state/calls"; }
logged() { grep -qF -- "$1" "$state/out"; }
# Every boot must reach run.sh and still power off through the EXIT trap.
assert_ran() {
    [[ -s "$state/run-args" ]] || fail "$1: run.sh was never started: $(cat "$state/out")"
    [[ "$(grep '^shutdown ' "$state/calls" | tail -1)" == "shutdown -h now" ]] \
        || fail "$1: the EXIT trap did not power the VM off"
}

# Docker verifies an HTTPS mirror's certificate against the system roots. Only
# an IP-literal mirror, which usually has a self-signed or internal
# certificate, skips the check. Plain HTTP has no certificate to skip.
n=0
while read -r url registry skip; do
    n=$((n + 1))
    DOCKER_MIRROR_URL=$url
    boot "tls-$n"
    assert_ran "Docker mirror $url"
    [[ "$(cat "$guest/$certs/public.ecr.aws/hosts.toml" 2>/dev/null)" \
        == "$(mirror_toml https://public.ecr.aws "$url" "$skip")" ]] \
        || fail "public.ecr.aws through $url: wrong hosts.toml: $(cat "$guest/$certs/public.ecr.aws/hosts.toml" 2>&1)"
    [[ "$(cat "$guest/$certs/$registry/hosts.toml" 2>/dev/null)" == "$(mirror_toml "$url" "$url" "$skip")" ]] \
        || fail "$url: wrong hosts.toml for $registry: $(cat "$guest/$certs/$registry/hosts.toml" 2>&1)"
done <<'EOF'
https://registry.example.com registry.example.com 0
https://registry.example.com:5000 registry.example.com:5000 0
https://mirror:5000 mirror:5000 0
https://10.20.1.19.nip.io:5000 10.20.1.19.nip.io:5000 0
https://10.20.1.19:5000 10.20.1.19:5000 1
https://10.20.1.19 10.20.1.19 1
https://[fd00::19]:5000 [fd00::19]:5000 1
https://[fd00::19] [fd00::19] 1
http://registry.example.com:5000 registry.example.com:5000 0
http://10.20.1.19:5000 10.20.1.19:5000 0
EOF
DOCKER_MIRROR_URL=""

# The template keeps the hosts.toml files of the mirror it was baked with, and
# Docker reads them on every pull. A clone removes those its mirror does not
# use, and nothing else: the image store in daemon.json holds the template's
# images, and a CA certificate is not mirror routing.
template_mirror=https://10.20.1.19:5000
boot stale-mirror-cleared
assert_ran "mirror cleared since the bake"
[[ ! -e "$guest/$certs/public.ecr.aws/hosts.toml" ]] \
    || fail "a clone without a mirror still routes public.ecr.aws through the template's mirror"
[[ ! -e "$guest/$certs/10.20.1.19:5000/hosts.toml" ]] || fail "a clone without a mirror kept the template mirror's hosts.toml"
[[ -f "$guest/$certs/10.20.1.19:5000/ca.crt" ]] || fail "the stale mirror cleanup removed more than hosts.toml"
jq -e '.features["containerd-snapshotter"] == true' "$guest/etc/docker/daemon.json" >/dev/null \
    || fail "the stale mirror cleanup changed daemon.json"
if called "systemctl restart docker"; then
    fail "a clone without a mirror restarted Docker"
fi
logged "Removed the template's stale Docker mirror config" || fail "removing the template's mirror config was not logged"
DOCKER_MIRROR_URL=https://10.20.1.20:5000
boot stale-mirror-replaced
assert_ran "mirror replaced since the bake"
[[ "$(cat "$guest/$certs/public.ecr.aws/hosts.toml")" == "$(mirror_toml https://public.ecr.aws "$DOCKER_MIRROR_URL" 1)" ]] \
    || fail "a clone did not route public.ecr.aws through the configured mirror"
[[ "$(cat "$guest/$certs/10.20.1.20:5000/hosts.toml")" == "$(mirror_toml "$DOCKER_MIRROR_URL" "$DOCKER_MIRROR_URL" 1)" ]] \
    || fail "a clone did not write the configured mirror's hosts.toml"
[[ ! -e "$guest/$certs/10.20.1.19:5000/hosts.toml" ]] || fail "a clone kept the replaced mirror's hosts.toml"
DOCKER_MIRROR_URL=https://10.20.1.19:5000
boot stale-mirror-same
assert_ran "the mirror the template was baked with"
[[ "$(cat "$guest/$certs/public.ecr.aws/hosts.toml")" == "$(mirror_toml https://public.ecr.aws "$DOCKER_MIRROR_URL" 1)" ]] \
    || fail "a clone lost public.ecr.aws routing through the template's own mirror"
[[ "$(cat "$guest/$certs/10.20.1.19:5000/hosts.toml")" == "$(mirror_toml "$DOCKER_MIRROR_URL" "$DOCKER_MIRROR_URL" 1)" ]] \
    || fail "a clone lost the hosts.toml of the template's own mirror"
if logged "Removed the template's stale Docker mirror config"; then
    fail "a clone removed config its own mirror uses"
fi
# IPv6 mirrors: the bracketed directory name must match literally.
template_mirror="https://[fd00::19]:5000"
DOCKER_MIRROR_URL="https://[fd00::20]:5000"
boot stale-mirror-ipv6
assert_ran "IPv6 mirror replaced since the bake"
[[ ! -e "$guest/$certs/[fd00::19]:5000/hosts.toml" ]] || fail "a clone kept the replaced IPv6 mirror's hosts.toml"
[[ -f "$guest/$certs/[fd00::20]:5000/hosts.toml" && -f "$guest/$certs/public.ecr.aws/hosts.toml" ]] \
    || fail "a clone removed the configured IPv6 mirror's config"
template_mirror=""
DOCKER_MIRROR_URL=""

# DNS. DNS_SERVERS replace the DHCP servers only once they resolve github.com
# and a mirror's host name from this network. Otherwise eth0 goes back to the
# DHCP servers without the gateway, and the clone still registers.
link_dns() { cat "$state/link-dns"; }
queried() { grep -E "^resolvectl query .* $1\$" "$state/calls" || true; }
DNS_SERVERS="1.1.1.1 8.8.8.8"
# The network blocks public DNS: only the site resolver from DHCP answers.
boot dns-public-blocked
assert_ran "DNS_SERVERS blocked by the network"
called "resolvectl dns eth0 1.1.1.1 8.8.8.8" || fail "DNS_SERVERS were not applied to eth0"
called "resolvectl revert eth0" || fail "eth0 was not reverted to DHCP after DNS_SERVERS failed"
[[ "$(link_dns)" == 10.0.0.53 ]] || fail "eth0 does not use the DHCP servers without the gateway: $(link_dns)"
logged "DNS servers 1.1.1.1 8.8.8.8 cannot resolve github.com" || fail "the DNS servers that failed were not named"
# resolved retries a lost query for up to two minutes: each try is bounded.
[[ -n "$(queried github.com)" ]] || fail "github.com was not looked up through DNS_SERVERS"
[[ "$(grep -c '^resolvectl query ' "$state/calls")" \
    == "$(grep -cE '^timeout ([1-9]|[12][0-9]|30) resolvectl query ' "$state/calls")" ]] \
    || fail "a DNS check is not bounded by timeout: $(grep -E '^(timeout|resolvectl query)' "$state/calls")"
# DHCP offers only the gateway, which is the only server that answers.
dhcp_dns="192.168.1.1"
resolvers=("192.168.1.1 github.com")
boot dns-public-blocked-gateway
assert_ran "DNS_SERVERS blocked, DHCP offers only the gateway"
[[ "$(link_dns)" == 192.168.1.1 ]] || fail "eth0 did not go back to the gateway, the only DHCP server: $(link_dns)"
dhcp_dns="192.168.1.1 10.0.0.53"
# Public DNS answers, but not for the mirror's LAN name.
resolvers=("$site_resolver" "1.1.1.1 github.com" "8.8.8.8 github.com")
DOCKER_MIRROR_URL=https://zot.home.arpa:5000
boot dns-mirror-lan-name
assert_ran "DNS_SERVERS do not resolve the mirror"
[[ -n "$(queried zot.home.arpa)" ]] || fail "the mirror's host name was not looked up"
called "resolvectl revert eth0" || fail "eth0 kept DNS_SERVERS that cannot resolve the mirror"
[[ "$(link_dns)" == 10.0.0.53 ]] || fail "eth0 does not use the DHCP servers: $(link_dns)"
logged "DNS servers 1.1.1.1 8.8.8.8 cannot resolve zot.home.arpa" || fail "the unresolved mirror was not named"
# Working DNS_SERVERS stay.
resolvers=("$site_resolver" "1.1.1.1 github.com zot.home.arpa")
boot dns-servers-work
assert_ran "working DNS_SERVERS"
[[ "$(link_dns)" == "1.1.1.1 8.8.8.8" ]] || fail "working DNS_SERVERS were replaced: $(link_dns)"
if called "resolvectl revert eth0"; then
    fail "working DNS_SERVERS were reverted"
fi
logged "DNS servers: 1.1.1.1 8.8.8.8" || fail "the applied DNS servers were not logged"
# One lost query is not a failure.
query_failures=1
boot dns-servers-flaky
assert_ran "DNS_SERVERS with one lost query"
[[ "$(link_dns)" == "1.1.1.1 8.8.8.8" ]] || fail "one lost query reverted working DNS_SERVERS: $(link_dns)"
query_failures=0
# An IP-literal mirror has no name to look up.
n=0
for DOCKER_MIRROR_URL in https://10.20.1.19:5000 "https://[fd00::19]:5000" http://10.20.1.19:5000; do
    n=$((n + 1))
    boot "dns-mirror-ip-$n"
    assert_ran "DNS_SERVERS with mirror $DOCKER_MIRROR_URL"
    [[ "$(grep '^resolvectl query ' "$state/calls" | grep -v ' github\.com$' || true)" == "" ]] \
        || fail "an IP-literal mirror was looked up in DNS: $(grep '^resolvectl query ' "$state/calls")"
    [[ "$(link_dns)" == "1.1.1.1 8.8.8.8" ]] || fail "DNS_SERVERS were not kept with mirror $DOCKER_MIRROR_URL: $(link_dns)"
done
DOCKER_MIRROR_URL=""
# Without DNS_SERVERS nothing is checked: the DHCP servers stay, without the gateway.
DNS_SERVERS=""
resolvers=("$site_resolver")
boot dns-dhcp
assert_ran "DNS_SERVERS empty"
if grep -qE '^resolvectl (query|revert) ' "$state/calls"; then
    fail "DHCP DNS was checked or reverted although DNS_SERVERS is empty"
fi
[[ "$(link_dns)" == 10.0.0.53 ]] || fail "the gateway was not dropped from the DHCP DNS servers: $(link_dns)"

# A runner version GitHub refuses (run.sh exits 7). The host sees only a
# stopped VM and clones the slot again at once, so the guest leaves the reason
# where qm guest exec can read it and stays up a few minutes first.
# The longest sleep, in seconds; empty when nothing slept a minute or more.
held_for() { awk '$1 == "sleep" && $2 ~ /^[0-9]+$/ && $2 >= 60 && $2 > max { max = $2 } END { if (max) print max }' "$state/calls"; }
run_rc=7
boot version-refused
assert_ran "run.sh exits 7"
marker=$guest/opt/.runner-version-refused
[[ -f "$marker" ]] || fail "a refused runner version left no marker for qm guest exec"
grep -qxF rc=7 "$marker" || fail "the marker does not record exit 7: $(cat "$marker")"
grep -qxF runner_version=2.337.0 "$marker" || fail "the marker does not name the refused version: $(cat "$marker")"
hold=$(held_for)
if [[ -z "$hold" ]] || (( hold < 180 || hold > 900 )); then
    fail "a refused runner version did not hold the VM for a few minutes: $(grep '^sleep ' "$state/calls" || true)"
fi
awk -v hold="sleep $hold" '
    $0 == "run.sh" { r = NR } $0 == hold { h = NR } $0 == "shutdown -h now" { d = NR }
    END { exit !(r && h && d && r < h && h < d) }
' "$state/calls" || fail "the hold does not come between run.sh and the power-off: $(cat "$state/calls")"
grep -qxF .runner-version-refused "$state/opt-while-sleeping" || fail "the marker was not written before the hold"
logged "Holding the VM for ${hold}s" || fail "the hold was not logged"
# Any other exit powers off at once and leaves no marker.
for run_rc in 0 1 2; do
    boot "run-exit-$run_rc"
    assert_ran "run.sh exits $run_rc"
    [[ ! -e "$guest/opt/.runner-version-refused" ]] || fail "run.sh exit $run_rc left a refused-version marker"
    [[ -z "$(held_for)" ]] || fail "run.sh exit $run_rc held the VM: $(grep '^sleep ' "$state/calls")"
done
run_rc=0

printf 'guest2-register-runner: ok\n'
