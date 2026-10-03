#!/usr/bin/env bash
# Boots a clone's /opt/register-runner.sh the way cloud-init would: render the
# per-VM user-data with the real render_user_snippet, write every write_files
# entry under a scratch root, then run the script there with the system
# commands it calls mocked on PATH. Checks the Docker mirror configuration.
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
cat > "$bin/sleep" <<'EOF'
#!/bin/bash
printf 'sleep %s\n' "$*" >> "$GUEST_STATE/calls"
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
# restores them, and query looks a name up through them.
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
    query) exec dns-lookup "${!#}" ;;
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
resolvers=("10.0.0.53 github.com registry.example.com mirror zot.home.arpa")
run_rc=0

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
    printf '%s\n' "$run_rc" > "$state/run-rc"
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

# hosts.toml that routes registry $1 through mirror $2, skipping certificate
# verification when $3 is 1.
mirror_toml() {
    printf 'server = "%s"\n\n[host."%s"]\n  capabilities = ["pull", "resolve"]' "$1" "$2"
    [[ "$3" == 0 ]] || printf '\n  skip_verify = true'
}
certs=etc/docker/certs.d

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

printf 'guest2-register-runner: ok\n'
