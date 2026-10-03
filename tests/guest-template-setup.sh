#!/usr/bin/env bash
# Checks the parts of the template bake script that shape every clone: the
# Docker mirror configuration. Blocks of /opt/setup-template.sh, rendered with
# the real render_template_setup_snippet, run under a scratch root with the
# system commands they call mocked on PATH.
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
    mkdir -p "$guest/etc" "$state"
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
    GUEST_STATE=$state PATH="$bin:$PATH" "$BASH" "$state/script" > "$state/out" 2>&1 \
        || fail "$name: the bake block failed: $(cat "$state/out")"
}

render_setup_script
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c '
import sys, yaml
for entry in yaml.safe_load(open(sys.argv[1]))["write_files"]:
    if entry["path"] == "/opt/setup-template.sh":
        sys.stdout.write(entry["content"])
' "$user_data" > "$work/parsed.sh" || fail "template-setup.yaml does not parse"
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' 2>/dev/null; then
    ruby -ryaml -e '
YAML.safe_load(File.read(ARGV[0]))["write_files"].each { |e| print e["content"] if e["path"] == "/opt/setup-template.sh" }
' "$user_data" > "$work/parsed.sh" || fail "template-setup.yaml does not parse"
fi
if [[ -e "$work/parsed.sh" ]]; then
    [[ "$(cat "$work/parsed.sh")" == "$(cat "$setup_script")" ]] \
        || fail "the YAML parser and this test read /opt/setup-template.sh differently"
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

printf 'guest-template-setup: ok\n'
