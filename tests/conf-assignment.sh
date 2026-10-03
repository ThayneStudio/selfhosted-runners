#!/usr/bin/env bash
# Publishing a template rewrites TEMPLATE_ID. A line that is more than that
# one assignment used to be replaced wholesale, so a bake limit sharing the
# line disappeared. A result that is not valid shell must not replace the file.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'conf-assignment: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/rebake.sh
source "$root/lib/rebake.sh"
fail() { printf 'conf-assignment: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
conf=$state/github-runners.conf

cat > "$conf" <<'EOF'
# operator comment
TEMPLATE_ID=9000; BAKE_MIN_FREE_GIB=50
TEMPLATE_ID=9000
BAKE_TIMEOUT=10800
EOF
set_conf_assignment "$conf" TEMPLATE_ID 9001
grep -qx 'TEMPLATE_ID=9000; BAKE_MIN_FREE_GIB=50' "$conf" \
    || fail "publish rewrote a line that was more than one assignment: $(cat "$conf")"
grep -qx 'TEMPLATE_ID=9001' "$conf" \
    || fail "the exact TEMPLATE_ID assignment was not updated: $(cat "$conf")"
grep -qx 'BAKE_TIMEOUT=10800' "$conf" || fail "publish dropped BAKE_TIMEOUT: $(cat "$conf")"
if grep -qx 'BAKE_MIN_FREE_GIB=50' "$conf"; then
    fail "publish split the compound line and dropped its other assignment"
fi
# shellcheck disable=SC1090
(
    # shellcheck disable=SC1090
    source "$conf"
    [[ "$TEMPLATE_ID" == 9001 ]] || exit 1
    [[ "$BAKE_MIN_FREE_GIB" == 50 ]] || exit 1
    [[ "$BAKE_TIMEOUT" == 10800 ]] || exit 1
) || fail "the published conf did not source to the new template: $(cat "$conf")"

# No exact assignment to replace: the compound line stays and the new value
# is appended, where it wins.
cat > "$conf" <<'EOF'
TEMPLATE_ID=9000;BAKE_MIN_FREE_GIB=50
EOF
set_conf_assignment "$conf" TEMPLATE_ID 9001
grep -qx 'TEMPLATE_ID=9000;BAKE_MIN_FREE_GIB=50' "$conf" \
    || fail "publish rewrote a semicolon command with no space: $(cat "$conf")"
# shellcheck disable=SC1090
(
    # shellcheck disable=SC1090
    source "$conf"
    [[ "$TEMPLATE_ID" == 9001 ]] || exit 1
    [[ "$BAKE_MIN_FREE_GIB" == 50 ]] || exit 1
) || fail "the appended TEMPLATE_ID did not win: $(cat "$conf")"

# An unclosed quote must not be published. The appended assignment would sit
# inside it, and every later source of the conf would fail.
cat > "$conf" <<'EOF'
NETWORK_BRIDGE='unterminated
EOF
cp "$conf" "$state/before"
rewrite_rc=0
set_conf_assignment "$conf" TEMPLATE_ID 9001 2>"$state/err" || rewrite_rc=$?
[[ "$rewrite_rc" != 0 ]] || fail "publish replaced a conf bash cannot source"
cmp -s "$conf" "$state/before" || fail "publish replaced the conf with a file that is not valid shell"
grep -q 'not valid shell' "$state/err" || fail "the refusal did not say why: $(cat "$state/err")"

printf 'conf-assignment: ok\n'
