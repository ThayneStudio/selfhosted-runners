#!/usr/bin/env bash
# Boots a clone's /opt/register-runner.sh the way cloud-init would: render the
# per-VM user-data with the real render_user_snippet, write every write_files
# entry under a scratch root, then run the script there with the system
# commands it calls mocked on PATH.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'guest-register-runner: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
fail() { printf 'guest-register-runner: %s\n' "$1" >&2; exit 1; }
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
write_file_mode() {
    awk -v want="$2" '
        /^  - path: / { inside = ($3 == want); next }
        inside && /^    permissions: / { gsub(/\047/, "", $2); print $2; exit }
    ' "$1"
}

# Cross-check the awk reading against a real YAML parser when one exists.
yaml_parser=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    yaml_parser=python3
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' 2>/dev/null; then
    yaml_parser=ruby
fi
yaml_write_file() {
    case "$yaml_parser" in
        python3)
            python3 -c '
import sys, yaml
for entry in yaml.safe_load(open(sys.argv[1]))["write_files"]:
    if entry["path"] == sys.argv[2]:
        sys.stdout.write(entry["content"])
' "$1" "$2"
            ;;
        ruby)
            ruby -ryaml -e '
YAML.safe_load(File.read(ARGV[0]))["write_files"].each { |e| print e["content"] if e["path"] == ARGV[1] }
' "$1" "$2"
            ;;
    esac
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
    local user_data="$1" guest="$2" path content mode
    while IFS= read -r path; do
        content=$(write_file_content "$user_data" "$path")
        if [[ "$path" == /opt/register-runner.sh ]]; then
            content=$(in_guest_root "$content" "$guest")
        fi
        mkdir -p "$guest$(dirname "$path")"
        printf '%s\n' "$content" > "$guest$path"
        mode=$(write_file_mode "$user_data" "$path")
        chmod "${mode:-0644}" "$guest$path"
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
cat > "$bin/resolvectl" <<'EOF'
#!/bin/bash
printf 'resolvectl %s\n' "$*" >> "$GUEST_STATE/calls"
# Like resolvectl, print no "DNS Servers:" line when the link has none.
if [[ "$1" == status && -s "$GUEST_STATE/dhcp-dns" ]]; then
    printf 'Link 2 (eth0)\n       DNS Servers: %s\n' "$(cat "$GUEST_STATE/dhcp-dns")"
fi
EOF
cat > "$bin/ip" <<'EOF'
#!/bin/bash
printf 'default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.50 metric 100\n'
printf '192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50 metric 100\n'
EOF
cat > "$bin/curl" <<'EOF'
#!/bin/bash
exit 0
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
env > "$GUEST_STATE/run-env"
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
dhcp_dns=""
baked=1
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
    printf '%s\n' "$run_rc" > "$state/run-rc"
    SNIPPETS_DIR=$work/$name
    render_user_snippet 9001 test-org "$jit" || fail "$name: render_user_snippet failed"
    user_data=$SNIPPETS_DIR/runner-9001-user-test-org.yaml
    install_write_files "$user_data" "$guest"
    cp "$work/run.sh" "$guest/home/runner/actions-runner/run.sh"
    [[ "$baked" == 0 ]] || printf '2.337.0\n' > "$guest/opt/.baked-runner-version"
    GUEST_STATE=$state PATH="$bin:$PATH" "$BASH" "$guest/opt/register-runner.sh" \
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

boot yaml
if [[ -n "$yaml_parser" ]]; then
    while IFS= read -r path; do
        [[ "$(yaml_write_file "$user_data" "$path")" == "$(write_file_content "$user_data" "$path")" ]] \
            || fail "$yaml_parser and this test read $path differently"
    done < <(write_file_paths "$user_data")
fi
assert_ran "rendered user-data"

# DNS. DHCP that offers only the gateway, or no DNS server at all, must not
# end the script before run.sh.
dhcp_dns="192.168.1.1"
boot dns-gateway-only
assert_ran "DHCP DNS is only the gateway"
if grep -q '^resolvectl dns ' "$state/calls"; then
    fail "the only DHCP DNS server was replaced while DNS_SERVERS is empty"
fi
dhcp_dns=""
boot dns-none
assert_ran "DHCP offers no DNS server"
dhcp_dns="192.168.1.1 9.9.9.9"
boot dns-strip-gateway
assert_ran "DHCP DNS includes the gateway"
called "resolvectl dns eth0 9.9.9.9" || fail "the gateway was not dropped from the DHCP DNS servers"
# Proxmox's --nameserver never reaches a DHCP interface, so DNS_SERVERS is
# applied by the guest and replaces whatever DHCP offered.
DNS_SERVERS="1.1.1.1 8.8.8.8"
dhcp_dns="192.168.1.1"
boot dns-configured
assert_ran "DNS_SERVERS is set"
called "resolvectl dns eth0 1.1.1.1 8.8.8.8" || fail "DNS_SERVERS was not applied to eth0"
logged "DNS servers: 1.1.1.1 8.8.8.8" || fail "the applied DNS servers were not logged"
DNS_SERVERS=""
dhcp_dns=""

printf 'guest-register-runner: ok\n'
