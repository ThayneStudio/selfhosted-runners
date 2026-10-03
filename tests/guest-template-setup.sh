#!/usr/bin/env bash
# Checks the parts of the template bake script that shape every clone: the
# Docker mirror configuration, the periodic apt jobs, and the DHCP client
# identifier. Blocks of /opt/setup-template.sh, rendered with the real
# render_template_setup_snippet, run under a scratch root with the system
# commands they call mocked on PATH.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'guest-template-setup: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/bake.sh
source "$root/lib/bake.sh"
fail() { printf 'guest-template-setup: %s\n' "$1" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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
# Lines of a script from the line equal to $2 through the next line equal to $3.
script_block() {
    FROM="$2" TO="$3" awk '
        !on && $0 == ENVIRON["FROM"] { on = 1; print; next }
        on { print }
        on && $0 == ENVIRON["TO"] { exit }
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

bin=$work/bin
mkdir -p "$bin"
cat > "$bin/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$GUEST_STATE/calls"
EOF
chmod +x "$bin"/*

INSTALL_DIR=$root
SNIPPETS_DIR=$work
DOCKER_MIRROR_URL=""

# Render the bake user-data for the current DOCKER_MIRROR_URL and extract
# /opt/setup-template.sh from it.
render_setup_script() {
    render_template_setup_snippet || fail "render_template_setup_snippet failed"
    user_data=$SNIPPETS_DIR/template-setup.yaml
    setup_script=$work/setup-template.sh
    write_file_content "$user_data" /opt/setup-template.sh > "$setup_script"
    [[ -s "$setup_script" ]] || fail "could not extract /opt/setup-template.sh"
}
# Run lines of the bake script under a fresh guest root. Sets guest and state.
run_in_guest() {
    local name="$1" body="$2"
    guest=$work/$name/root
    state=$work/$name/state
    # Directories the stock cloud image already has.
    mkdir -p "$guest/etc/apt/apt.conf.d" "$guest/etc/netplan" "$state"
    : > "$state/calls"
    {
        cat <<'EOF'
#!/bin/bash
set -euo pipefail
log() { echo "$1"; }
log_error() { echo "ERROR: $1" >&2; }
EOF
        in_guest_root "$body" "$guest"
        printf '\n'
    } > "$state/script"
    GUEST_STATE=$state PATH="$extra_path$bin:$PATH" "$BASH" "$state/script" > "$state/out" 2>&1 \
        || fail "$name: the bake block failed: $(cat "$state/out")"
}
extra_path=""

# Parse YAML with a real parser when one is installed: print the value of a
# Ruby-style key path such as ["network"]["ethernets"].
yaml_parser=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    yaml_parser=python3
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' 2>/dev/null; then
    yaml_parser=ruby
fi
yaml_value() {
    case "$yaml_parser" in
        python3) python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); sys.stdout.write(str(eval("d" + sys.argv[2])))' "$1" "$2" ;;
        ruby) ruby -ryaml -e 'd = YAML.safe_load(File.read(ARGV[0])); print eval("d" + ARGV[1])' "$1" "$2" ;;
    esac
}

render_setup_script
if [[ -n "$yaml_parser" ]]; then
    parsed=$(yaml_value "$user_data" '["write_files"][0]["content"]') || fail "template-setup.yaml does not parse"
    [[ "$(yaml_value "$user_data" '["write_files"][0]["path"]')" == /opt/setup-template.sh ]] \
        || fail "/opt/setup-template.sh is no longer the first write_files entry"
    [[ "$parsed" == "$(cat "$setup_script")" ]] \
        || fail "$yaml_parser and this test read /opt/setup-template.sh differently"
fi
"$BASH" -n "$setup_script" || fail "/opt/setup-template.sh has a syntax error"

# Docker mirror. Docker's containerd image store reads hosts.toml from
# /etc/docker/certs.d; nothing reads /etc/containerd/certs.d.
mirror_block() {
    grep -m1 '^DOCKER_MIRROR_URL=' "$setup_script"
    # shellcheck disable=SC2016 # a literal line of the bake script
    script_block "$setup_script" 'if [[ -n "${DOCKER_MIRROR_URL:-}" ]]; then' 'fi'
}
hosts_toml() {
    printf 'server = "%s"\n\n[host."%s"]\n  capabilities = ["pull", "resolve"]\n  skip_verify = true' "$1" "$2"
}
DOCKER_MIRROR_URL=https://10.20.1.19:5000
render_setup_script
run_in_guest mirror-https "$(mirror_block)"
[[ "$(cat "$guest/etc/docker/certs.d/public.ecr.aws/hosts.toml" 2>/dev/null)" \
    == "$(hosts_toml https://public.ecr.aws "$DOCKER_MIRROR_URL")" ]] \
    || fail "the bake did not route public.ecr.aws through the mirror in /etc/docker/certs.d"
[[ "$(cat "$guest/etc/docker/certs.d/10.20.1.19:5000/hosts.toml" 2>/dev/null)" \
    == "$(hosts_toml "$DOCKER_MIRROR_URL" "$DOCKER_MIRROR_URL")" ]] \
    || fail "the bake did not write the mirror's own hosts.toml in /etc/docker/certs.d"
[[ ! -e "$guest/etc/containerd" ]] || fail "the bake still writes /etc/containerd/certs.d, which Docker never reads"
jq -e '.features["containerd-snapshotter"] == true' "$guest/etc/docker/daemon.json" >/dev/null \
    || fail "an HTTPS mirror no longer enables the containerd image store"
grep -qxF 'systemctl restart docker' "$state/calls" || fail "the bake did not restart Docker after the mirror config"
DOCKER_MIRROR_URL=http://10.20.1.19:5000
render_setup_script
run_in_guest mirror-http "$(mirror_block)"
jq -e '."storage-driver" == "overlay2" and ."insecure-registries" == ["10.20.1.19:5000"]' \
    "$guest/etc/docker/daemon.json" >/dev/null || fail "an HTTP mirror lost its overlay2 and insecure-registries settings"
[[ ! -e "$guest/etc/containerd" ]] || fail "the bake still writes /etc/containerd/certs.d, which Docker never reads"
DOCKER_MIRROR_URL=""
render_setup_script

# Periodic apt jobs. unattended-upgrades takes the dpkg lock without waiting
# for cloud-final, under the bake and under jobs on every clone. They must be
# off before the bake's first apt-get, and stay off in the template.
before_first_apt_get() {
    awk '
        index($0, "log \"[2/12]") == 1 { on = 1 }
        on && !/^[[:space:]]*#/ && /apt-get/ { exit }
        on { print }
    ' "$setup_script"
}
[[ -n "$(before_first_apt_get)" ]] || fail "could not find the bake's [2/12] step"
run_in_guest apt-periodic "$(before_first_apt_get)"
grep -qxF 'systemctl disable --now apt-daily.timer apt-daily-upgrade.timer' "$state/calls" \
    || fail "the apt-daily timers are not disabled before the bake's first apt-get"
grep -qxF 'systemctl mask apt-daily.service apt-daily-upgrade.service' "$state/calls" \
    || fail "the apt-daily services are not masked before the bake's first apt-get"
apt_conf=$(grep -lF 'APT::Periodic::Unattended-Upgrade "0";' "$guest"/etc/apt/apt.conf.d/* 2>/dev/null | head -1 || true)
[[ -n "$apt_conf" ]] || fail "unattended-upgrades is not turned off in apt.conf.d"
grep -qxF 'APT::Periodic::Update-Package-Lists "0";' "$apt_conf" || fail "periodic package list updates are not turned off"
grep -Eqx 'DPkg::Lock::Timeout "[1-9][0-9]*";' "$apt_conf" || fail "apt-get does not wait for a held dpkg lock"
# apt reads apt.conf.d in order; the stock 20auto-upgrades turns both on.
[[ "$(basename "$apt_conf")" > 50unattended-upgrades ]] || fail "$(basename "$apt_conf") is read before the stock apt settings"
# An image without these units must still bake.
mkdir -p "$work/bin-systemctl-fails"
printf '#!/bin/bash\nexit 1\n' > "$work/bin-systemctl-fails/systemctl"
chmod +x "$work/bin-systemctl-fails/systemctl"
extra_path=$work/bin-systemctl-fails:
run_in_guest apt-periodic-no-units "$(before_first_apt_get)"
extra_path=""
grep -rqF 'APT::Periodic::Unattended-Upgrade "0";' "$guest/etc/apt/apt.conf.d" \
    || fail "a failed systemctl call skipped the apt settings"

# DHCP client identifier. A slot keeps its MAC across recycles but each clone
# gets a new machine-id, so the identifier must be the MAC. It must be in the
# image: user-data write_files runs after networkd has started DHCP.
netplan_block() {
    script_block "$setup_script" "cat > /etc/netplan/99-dhcp-mac.yaml <<'NETPLANEOF'" \
        'chmod 600 /etc/netplan/99-dhcp-mac.yaml'
}
[[ -n "$(netplan_block)" ]] || fail "the bake no longer writes /etc/netplan/99-dhcp-mac.yaml"
run_in_guest dhcp-identifier "$(netplan_block)"
netplan=$guest/etc/netplan/99-dhcp-mac.yaml
[[ -n "$(find "$netplan" -perm 600 2>/dev/null)" ]] || fail "99-dhcp-mac.yaml is not mode 600"
if [[ -n "$yaml_parser" ]]; then
    [[ "$(yaml_value "$netplan" '["network"]["ethernets"]["eth0"]["dhcp-identifier"]')" == mac ]] \
        || fail "99-dhcp-mac.yaml does not set dhcp-identifier: mac on eth0"
    [[ "$(yaml_value "$netplan" '["network"]["ethernets"]["eth0"]["dhcp4"]')" == [Tt]rue ]] \
        || fail "99-dhcp-mac.yaml turns DHCP off on eth0"
else
    grep -qx '      dhcp-identifier: mac' "$netplan" || fail "99-dhcp-mac.yaml does not set dhcp-identifier: mac"
fi
line_of() { grep -nxF -- "$1" "$setup_script" | head -1 | cut -d: -f1 || true; }
written=$(line_of 'chmod 600 /etc/netplan/99-dhcp-mac.yaml')
cleaned=$(line_of 'cloud-init clean --logs')
completed=$(line_of 'touch /opt/.template-setup-complete')
[[ -n "$cleaned" && -n "$completed" && "$written" -lt "$cleaned" && "$written" -lt "$completed" ]] \
    || fail "99-dhcp-mac.yaml is not written before the image is sealed"
if grep -q '^  - path: /etc/netplan/' "$root/templates/runner-user-data.yaml"; then
    fail "runner-user-data.yaml writes netplan config that a clone never applies"
fi

printf 'guest-template-setup: ok\n'
