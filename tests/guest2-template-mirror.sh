#!/usr/bin/env bash
# The template bake writes the Docker mirror's hosts.toml with the same TLS
# rule as every clone: the mirror's certificate is verified against the
# system roots unless the mirror is addressed by IP literal. The bake's
# mirror block, rendered with the real render_template_setup_snippet, runs
# under a scratch root with systemctl mocked on PATH.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'guest2-template-mirror: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/lib/common.sh"
# shellcheck source=../lib/bake.sh
source "$root/lib/bake.sh"
fail() { printf 'guest2-template-mirror: %s\n' "$1" >&2; exit 1; }
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
# The host resolves the runner release before rendering the bake snippet.
LATEST_RUNNER_VERSION=2.330.0

# Render the bake for DOCKER_MIRROR_URL and run its mirror block under a fresh
# guest root. Sets guest.
bake_mirror() {
    local name="$1" script block
    render_template_setup_snippet || fail "render_template_setup_snippet failed"
    script=$(write_file_content "$SNIPPETS_DIR/template-setup.yaml" /opt/setup-template.sh)
    # shellcheck disable=SC2016 # a literal line of the bake script
    block=$(script_block <(printf '%s\n' "$script") 'if [[ -n "${DOCKER_MIRROR_URL:-}" ]]; then' 'fi')
    [[ -n "$block" ]] || fail "could not find the bake's Docker mirror block"
    guest=$work/$name/root
    mkdir -p "$guest" "$work/$name/state"
    : > "$work/$name/state/calls"
    {
        cat <<'EOF'
#!/bin/bash
set -euo pipefail
log() { echo "$1"; }
EOF
        grep -m1 '^DOCKER_MIRROR_URL=' <<< "$script"
        in_guest_root "$block" "$guest"
        printf '\n'
    } > "$work/$name/state/script"
    GUEST_STATE=$work/$name/state PATH="$bin:$PATH" "$BASH" "$work/$name/state/script" \
        > "$work/$name/state/out" 2>&1 || fail "$name: the bake's mirror block failed: $(cat "$work/$name/state/out")"
}
# hosts.toml that routes registry $1 through mirror $2, skipping certificate
# verification when $3 is 1.
mirror_toml() {
    printf 'server = "%s"\n\n[host."%s"]\n  capabilities = ["pull", "resolve"]' "$1" "$2"
    [[ "$3" == 0 ]] || printf '\n  skip_verify = true'
}
certs=etc/docker/certs.d

n=0
while read -r url registry skip; do
    n=$((n + 1))
    DOCKER_MIRROR_URL=$url
    bake_mirror "tls-$n"
    [[ "$(cat "$guest/$certs/public.ecr.aws/hosts.toml" 2>/dev/null)" \
        == "$(mirror_toml https://public.ecr.aws "$url" "$skip")" ]] \
        || fail "bake, public.ecr.aws through $url: wrong hosts.toml: $(cat "$guest/$certs/public.ecr.aws/hosts.toml" 2>&1)"
    [[ "$(cat "$guest/$certs/$registry/hosts.toml" 2>/dev/null)" == "$(mirror_toml "$url" "$url" "$skip")" ]] \
        || fail "bake, $url: wrong hosts.toml for $registry: $(cat "$guest/$certs/$registry/hosts.toml" 2>&1)"
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

printf 'guest2-template-mirror: ok\n'
