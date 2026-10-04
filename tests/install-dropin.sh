#!/usr/bin/env bash
# An existing-host upgrade writes the rebake start-timeout drop-in from the
# conf, still inside the quiesce, once the new tree is in place. The other
# install check stubs tar without lib/rebake.sh, so that branch never runs.
# BAKE_TIMEOUT in the conf becomes TimeoutStartSec plus an hour. With none
# set, the drop-in keeps the unit default of 9000. A drop-in directory that
# cannot be written is a warning: install still exits 0, releases the
# quiesce, and starts the watcher again.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'install-dropin: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../install.sh
source "$root/install.sh"
fail() { printf 'install-dropin: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'chmod -R u+w "$state" 2>/dev/null || true; rm -rf "$state"' EXIT

unset BAKE_TIMEOUT BAKE_MIN_FREE_GIB BAKE_FREE_FLOOR_GIB INVOCATION_ID TEMPLATE_ID

log=$state/log
INSTALL_DIR=$state/opt
CONFIG_FILE=$state/github-runners.conf
SYSTEMD_DIR=$state/systemd
SNIPPETS_DIR=$state/snippets
PVE_NODES_DIR=$state/nodes
RUNNER_BIN=$state/bin/runner
OLD_POOL_LOCK=$state/old/github-runner-pool.lock
POOL_DRAIN_FILE=$state/run/github-runner-drain
LEGACY_POOL_DRAIN_FILE=$state/legacy/github-runner-drain
REPO_URL=http://install.test/archive.tar.gz
dropin=$SYSTEMD_DIR/github-runner-rebake.service.d/timeout.conf

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$log"
    if [[ "$1" == is-active ]]; then
        printf '%s\n' inactive
        return 0
    fi
}
flock() {
    printf 'flock %s\n' "$*" >> "$log"
}
curl() {
    printf 'curl %s\n' "$*" >> "$log"
}
# Copy the real tree. A stub that omits lib/rebake.sh skips the drop-in.
tar() {
    printf 'tar %s\n' "$*" >> "$log"
    mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/templates"
    cp -R "$root/lib/." "$INSTALL_DIR/lib/"
    cp -R "$root/templates/." "$INSTALL_DIR/templates/"
    cp "$root/runner" "$INSTALL_DIR/runner"
}

line_of() {
    local n
    n=$(grep -n "$1" "$log" | head -1 | cut -d: -f1) || true
    printf '%s\n' "${n:-0}"
}

fresh() {
    chmod -R u+w "$state" 2>/dev/null || true
    : > "$log"
    rm -rf "$INSTALL_DIR" "$SYSTEMD_DIR" "$SNIPPETS_DIR" "${state:?}/old" "${state:?}/bin" \
        "${state:?}/run" "${state:?}/legacy" "$CONFIG_FILE"
    mkdir -p "$state/bin" "$state/old" "$state/legacy" "$PVE_NODES_DIR" "$SYSTEMD_DIR" "$SNIPPETS_DIR"
    : > "$SYSTEMD_DIR/github-runner-watch.timer"
}

drains_gone() {
    [[ ! -e "$POOL_DRAIN_FILE" && ! -L "$POOL_DRAIN_FILE" &&
        ! -e "$LEGACY_POOL_DRAIN_FILE" && ! -L "$LEGACY_POOL_DRAIN_FILE" ]]
}

# stop, then the watcher again, then the old pool lock. Drains this install
# wrote are gone. Called as `released || fail`, so errexit is off in here.
released() {
    local stop start unlocked
    stop=$(line_of 'systemctl stop github-runner-watch.timer')
    start=$(line_of 'systemctl start github-runner-watch.timer')
    unlocked=$(line_of 'flock -u 9')
    [[ "$stop" != 0 && "$start" != 0 && "$unlocked" != 0 && "$stop" -lt "$start" && "$start" -lt "$unlocked" ]] || return 1
    drains_gone
}

upgrade() {
    upgrade_rc=0
    ( install_main ) > "$state/out" 2>"$state/err" || upgrade_rc=$?
}

# Conf BAKE_TIMEOUT=7200: an hour of headroom, 10800.
fresh
cat > "$CONFIG_FILE" <<'EOF'
DOCKER_MIRROR_URL=
BAKE_TIMEOUT=7200
EOF
upgrade
[[ "$upgrade_rc" == 0 ]] || fail "an upgrade with BAKE_TIMEOUT=7200 failed: $(cat "$state/err")"
grep -qx 'TimeoutStartSec=10800' "$dropin" \
    || fail "the drop-in was not an hour above the conf BAKE_TIMEOUT: $(cat "$dropin" 2>/dev/null || printf missing)"
if grep -qF 'The rebake start timeout was not updated' "$state/err"; then
    fail "a writable drop-in directory warned: $(cat "$state/err")"
fi
released || fail "an upgrade with BAKE_TIMEOUT=7200 did not release the quiesce: $(cat "$log")"

# No BAKE_TIMEOUT in the conf: the same 9000 the unit file carries.
fresh
cat > "$CONFIG_FILE" <<'EOF'
DOCKER_MIRROR_URL=
EOF
upgrade
[[ "$upgrade_rc" == 0 ]] || fail "an upgrade with no BAKE_TIMEOUT failed: $(cat "$state/err")"
grep -qx 'TimeoutStartSec=9000' "$dropin" \
    || fail "an unset BAKE_TIMEOUT did not keep the 9000 default: $(cat "$dropin" 2>/dev/null || printf missing)"
if grep -qF 'The rebake start timeout was not updated' "$state/err"; then
    fail "an unset BAKE_TIMEOUT warned: $(cat "$state/err")"
fi
released || fail "an upgrade with no BAKE_TIMEOUT did not release the quiesce: $(cat "$log")"

# The directory is there and not writable. mkdir -p succeeds, the write
# fails, and the upgrade still finishes.
fresh
cat > "$CONFIG_FILE" <<'EOF'
DOCKER_MIRROR_URL=
BAKE_TIMEOUT=7200
EOF
mkdir -p "$SYSTEMD_DIR/github-runner-rebake.service.d"
chmod a-w "$SYSTEMD_DIR/github-runner-rebake.service.d"
upgrade
[[ "$upgrade_rc" == 0 ]] || fail "an unwritable drop-in directory failed the install: $(cat "$state/err")"
grep -qF 'The rebake start timeout was not updated' "$state/err" \
    || fail "an unwritable drop-in directory did not warn: $(cat "$state/err")"
[[ ! -e "$dropin" ]] || fail "an unwritable drop-in directory still wrote timeout.conf: $(cat "$dropin")"
released || fail "an unwritable drop-in directory did not release the quiesce: $(cat "$log")"
grep -q 'Template rebake timer enabled' "$state/out" \
    || fail "an unwritable drop-in directory stopped before the rebake timer was enabled: $(cat "$state/out")"

printf 'install-dropin: ok\n'
