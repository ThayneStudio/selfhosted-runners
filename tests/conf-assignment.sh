#!/usr/bin/env bash
# Publishing a template rewrites TEMPLATE_ID. A line that is more than that
# one assignment used to be replaced wholesale, so a bake limit sharing the
# line disappeared. An exact assignment earlier in the file must not leave a
# later compound line as the value that wins. A result that is not valid
# shell, or that still does not source to the new value, must not replace
# the file or record the switch.
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

# The exact assignment is first. Replacing it in place used to leave the
# compound line last, so three publishes still sourced TEMPLATE_ID=9000.
cat > "$conf" <<'EOF'
# operator comment
TEMPLATE_ID=9000
TEMPLATE_ID=9000; BAKE_MIN_FREE_GIB=50
EOF
for id in 9001 9002 9003; do
    set_conf_assignment "$conf" TEMPLATE_ID "$id"
    # shellcheck disable=SC1090
    (
        # shellcheck disable=SC1090
        source "$conf"
        [[ "$TEMPLATE_ID" == "$id" ]] || exit 1
        [[ "$BAKE_MIN_FREE_GIB" == 50 ]] || exit 1
    ) || fail "publish $id left the compound line as the effective TEMPLATE_ID: $(cat "$conf")"
    grep -qx 'TEMPLATE_ID=9000; BAKE_MIN_FREE_GIB=50' "$conf" \
        || fail "publish $id rewrote the compound line: $(cat "$conf")"
done
[[ "$(grep -c '^TEMPLATE_ID=' "$conf")" -eq 3 ]] \
    || fail "publishing three ids kept appending TEMPLATE_ID: $(cat "$conf")"
cp "$conf" "$state/stable"
set_conf_assignment "$conf" TEMPLATE_ID 9003
cmp -s "$conf" "$state/stable" \
    || fail "publishing the current id appended another assignment: $(cat "$conf")"

# A command that still wins after the appended assignment must not be
# published, and the switch must not retire the live template.
cat > "$conf" <<'EOF'
TEMPLATE_ID=9000
false
EOF
cp "$conf" "$state/before"
# shellcheck disable=SC2034 # switch_template_id reads these
CONFIG_FILE=$conf
TEMPLATE_ID=9000
STATE_DIR=$state
RETIRED_TEMPLATES_FILE=$state/retired-templates
rewrite_rc=0
switch_template_id 9001 2>"$state/err" || rewrite_rc=$?
[[ "$rewrite_rc" != 0 ]] || fail "switch_template_id recorded a switch the sourced conf does not show"
[[ "$TEMPLATE_ID" == 9000 ]] || fail "shell TEMPLATE_ID changed after a refused rewrite: $TEMPLATE_ID"
cmp -s "$conf" "$state/before" || fail "refused rewrite replaced the conf: $(cat "$conf")"
[[ ! -e "$RETIRED_TEMPLATES_FILE" ]] || fail "refused rewrite left the old template retired"
grep -q 'does not set TEMPLATE_ID' "$state/err" || fail "the refusal did not say why: $(cat "$state/err")"
shopt -s nullglob
leftovers=("$conf".*)
shopt -u nullglob
[[ ${#leftovers[@]} -eq 0 ]] || fail "refused rewrite left ${leftovers[*]}"

# A sourced exit skips the probe's print and exits 0. That must not count as
# an empty value and replace the file.
printf 'exit\n' > "$conf"
cp "$conf" "$state/before"
rewrite_rc=0
set_conf_assignment "$conf" TEMPLATE_ID '' 2>"$state/err" || rewrite_rc=$?
[[ "$rewrite_rc" != 0 ]] || fail "publish treated a sourced exit as an empty TEMPLATE_ID"
cmp -s "$conf" "$state/before" || fail "publish replaced a conf that exits before the new assignment: $(cat "$conf")"
grep -q 'does not set TEMPLATE_ID' "$state/err" || fail "the exit refusal did not say why: $(cat "$state/err")"

printf 'conf-assignment: ok\n'
