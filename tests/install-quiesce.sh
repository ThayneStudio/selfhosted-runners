#!/usr/bin/env bash
# install.sh replaces the tree while the watcher and reclone units are still
# running. Those processes hold /run/lock/github-runner-pool.lock; the new
# tree locks a different file. An upgrade has to stop the watcher, wait out
# the current tick, and hold the old lock across the extract. A new host has
# neither the timer nor the lock.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'install-quiesce: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../install.sh
source "$root/install.sh"
fail() { printf 'install-quiesce: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

grep -q 'OLD_POOL_LOCK:-/run/lock/github-runner-pool.lock' "$root/install.sh" ||
    fail "install.sh does not take the previous version's pool lock"
grep -q 'OLD_POOL_LOCK_WAIT:-600' "$root/install.sh" ||
    fail "install.sh does not bound the wait for the old pool lock"

log=$state/log
watch_state=inactive
flock_rc=0
curl_rc=0

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
stop_term=0
operator_stop=0
reclone_active_passes=0
reclone_list_n=0
systemctl_list_rc=0

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$log"
    # list-units runs in a command substitution, so a shell variable
    # set here is discarded. The count lives in a file.
    if [[ "$1" == list-units ]]; then
        reclone_list_n=$(cat "$state/reclone-list-n" 2>/dev/null || printf '0\n')
        reclone_list_n=$((reclone_list_n + 1))
        printf '%s\n' "$reclone_list_n" > "$state/reclone-list-n"
        if [[ "$systemctl_list_rc" != 0 ]]; then
            return "$systemctl_list_rc"
        fi
        if (( reclone_list_n <= reclone_active_passes )); then
            printf '%s\n' 'github-runner-reclone-101.service loaded active running GitHub runner reclone'
        fi
        return 0
    fi
    if [[ "$1" == stop && "${stop_term:-0}" == 1 ]]; then
        kill -TERM "$BASHPID"
        sleep 2
    fi
    if [[ "$1" == stop || "$1" == start ]]; then
        if [[ -f "$POOL_DRAIN_FILE" && -f "$LEGACY_POOL_DRAIN_FILE" ]]; then
            printf 'drain-at-%s\n' "$1" >> "$log"
        fi
    fi
    if [[ "$1" == is-active ]]; then
        printf '%s\n' "$watch_state"
        [[ "$watch_state" == active || "$watch_state" == activating || "$watch_state" == deactivating ]]
        return
    fi
}
flock() {
    local tmp
    if [[ -f "$POOL_DRAIN_FILE" && -f "$LEGACY_POOL_DRAIN_FILE" ]]; then
        printf 'drain-at-flock\n' >> "$log"
    fi
    # The exclusive lock is where an operator's runner stop, blocked on
    # this lock, has already replaced both drain files.
    if [[ "$*" == *-x* ]]; then
        if [[ -f "$POOL_DRAIN_FILE" && ! -L "$POOL_DRAIN_FILE" ]]; then
            cat -- "$POOL_DRAIN_FILE" > "$state/token-new"
        fi
        if [[ -f "$LEGACY_POOL_DRAIN_FILE" && ! -L "$LEGACY_POOL_DRAIN_FILE" ]]; then
            cat -- "$LEGACY_POOL_DRAIN_FILE" > "$state/token-legacy"
        fi
        if [[ "$operator_stop" == 1 ]]; then
            : > "$POOL_DRAIN_FILE"
            tmp=$(mktemp "$state/legacy/.github-runner-drain.XXXXXX")
            mv -f "$tmp" "$LEGACY_POOL_DRAIN_FILE"
        fi
    fi
    printf 'flock %s\n' "$*" >> "$log"
    return "$flock_rc"
}
curl() {
    printf 'curl %s\n' "$*" >> "$log"
    return "$curl_rc"
}
tar() {
    printf 'tar %s\n' "$*" >> "$log"
    mkdir -p "$INSTALL_DIR/templates" "$INSTALL_DIR/lib"
    cp "$root"/templates/* "$INSTALL_DIR/templates/"
    printf '#!/bin/sh\n' > "$INSTALL_DIR/runner"
    printf '#!/bin/sh\n' > "$INSTALL_DIR/lib/common.sh"
}

line_of() {
    local n
    n=$(grep -n "$1" "$log" | head -1 | cut -d: -f1)
    printf '%s\n' "${n:-0}"
}

fresh() {
    : > "$log"
    rm -rf "$INSTALL_DIR" "$SYSTEMD_DIR" "$SNIPPETS_DIR" "${state:?}/old" "${state:?}/bin" \
        "${state:?}/run" "${state:?}/legacy" "$CONFIG_FILE"
    mkdir -p "$state/bin" "$state/old" "$PVE_NODES_DIR" "$state/legacy"
    watch_state=inactive
    flock_rc=0
    curl_rc=0
    stop_term=0
    operator_stop=0
    reclone_active_passes=0
    reclone_list_n=0
    systemctl_list_rc=0
    printf '0\n' > "$state/reclone-list-n"
    OLD_POOL_LOCK_WAIT=600
    rm -f "$state/token-new" "$state/token-legacy"
}

sleep() {
    printf 'sleep %s\n' "$*" >> "$log"
    command sleep "$@"
}

drains_gone() {
    [[ ! -e "$POOL_DRAIN_FILE" && ! -L "$POOL_DRAIN_FILE" &&
        ! -e "$LEGACY_POOL_DRAIN_FILE" && ! -L "$LEGACY_POOL_DRAIN_FILE" ]]
}

# A host with no config does not stop a timer or take a lock.
fresh
( install_main ) > "$state/out" 2>"$state/err" || fail "a fresh install failed: $(cat "$state/err")"
[[ "$(line_of '^curl ')" != 0 ]] || fail "a fresh install did not extract the tree"
[[ "$(line_of '^systemctl ')" == 0 ]] || fail "a fresh install called systemctl: $(cat "$log")"
[[ "$(line_of '^flock ')" == 0 ]] || fail "a fresh install took a pool lock: $(cat "$log")"
grep -q 'Run the setup wizard' "$state/out" || fail "a fresh install did not say to run setup"
[[ -L "$RUNNER_BIN" ]] || fail "a fresh install did not link runner"
drains_gone || fail "a fresh install set a drain flag"

# An existing host drains old clones before the extract, then restarts the watcher.
fresh
printf 'DOCKER_MIRROR_URL=http://mirror.example\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
printf 'secret\n' > "$state/canary"
ln -s "$state/canary" "$OLD_POOL_LOCK"
( install_main ) > "$state/out" 2>"$state/err" || fail "an upgrade failed: $(cat "$state/err")"
stop=$(line_of 'systemctl stop github-runner-watch.timer')
held=$(line_of 'flock -w 600 -x 9')
extracted=$(line_of '^curl ')
released=$(line_of 'flock -u 9')
started=$(line_of 'systemctl start github-runner-watch.timer')
[[ "$stop" != 0 && "$stop" -lt "$held" && "$held" -lt "$extracted" && "$extracted" -lt "$started" && "$started" -lt "$released" ]] ||
    fail "upgrade order was stop=$stop flock=$held curl=$extracted start=$started release=$released: $(cat "$log")"
[[ "$(grep -c 'systemctl start github-runner-watch.timer' "$log")" == 1 ]] ||
    fail "the watcher was started more than once: $(cat "$log")"
[[ -f "$SNIPPETS_DIR/runner-hookscript.sh" ]] || fail "the hookscript was not installed"
[[ -f "$SYSTEMD_DIR/github-runner-rebake.timer" ]] || fail "the rebake timer was not installed"
[[ -f "$OLD_POOL_LOCK" && ! -L "$OLD_POOL_LOCK" ]] || fail "the old pool lock was left as a symlink"
[[ "$(cat "$state/canary")" == secret ]] || fail "taking the old pool lock followed a symlink"
grep -q 'Done. No need to re-run setup.' "$state/out" || fail "an upgrade did not finish: $(cat "$state/out")"
[[ "$(line_of 'drain-at-stop')" != 0 && "$(line_of 'drain-at-stop')" -lt "$held" ]] ||
    fail "the drain was not set before the old pool lock was taken: $(cat "$log")"
[[ -s "$state/token-new" && "$(cat "$state/token-new")" == "$(cat "$state/token-legacy")" ]] ||
    fail "install did not write the same token into both drain flags"
[[ "$(line_of 'drain-at-start')" == 0 ]] ||
    fail "install restarted the watcher while its own drain flag was still set: $(cat "$log")"
drains_gone || fail "an upgrade left the drain flag it set"
if grep -q 'was left stopped' "$state/out"; then
    fail "install reported a maintenance drain for its own token"
fi

# The old lock stays busy: leave the tree alone and start the watcher again.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
flock_rc=1
if ( install_main ) > "$state/out" 2>"$state/err"; then
    fail "install extracted the tree while the old pool lock was busy"
fi
grep -q 'was not installed' "$state/err" || fail "a busy old pool lock was not reported: $(cat "$state/err")"
[[ "$(line_of '^curl ')" == 0 ]] || fail "a busy old pool lock still extracted the tree"
[[ "$(line_of 'systemctl start github-runner-watch.timer')" != 0 ]] ||
    fail "a timed-out upgrade left the watcher stopped"
[[ ! -d "$INSTALL_DIR" ]] || fail "a timed-out upgrade created $INSTALL_DIR"
[[ "$(line_of 'drain-at-stop')" != 0 ]] || fail "a timed-out upgrade did not drain before stopping the watcher"
drains_gone || fail "a timed-out upgrade left the drain flag it set"

# The watch tick never finishes: same abort, and the old lock is not taken.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
watch_state=activating
OLD_POOL_LOCK_WAIT=0
if ( install_main ) > "$state/out" 2>"$state/err"; then
    fail "install waited forever for github-runner-watch.service"
fi
grep -q 'github-runner-watch.service was still running' "$state/err" ||
    fail "a stuck watch service was not reported: $(cat "$state/err")"
[[ "$(line_of '^flock ')" == 0 ]] || fail "a stuck watch service still took the pool lock"
[[ "$(line_of '^curl ')" == 0 ]] || fail "a stuck watch service still extracted the tree"
[[ "$(line_of 'systemctl start github-runner-watch.timer')" != 0 ]] ||
    fail "a stuck watch service left the watcher stopped"
drains_gone || fail "a stuck watch service left the drain flag set"

# Config, but no watcher unit yet: still wait for old reclones, and do not start a timer.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
( install_main ) > "$state/out" 2>"$state/err" || fail "an upgrade without a watcher failed: $(cat "$state/err")"
[[ "$(line_of 'systemctl stop github-runner-watch.timer')" == 0 ]] ||
    fail "install stopped a watcher timer that is not installed"
[[ "$(line_of 'systemctl start github-runner-watch.timer')" == 0 ]] ||
    fail "install started a watcher timer that is not installed"
[[ "$(line_of 'flock -w 600 -x 9')" != 0 && "$(line_of 'flock -w 600 -x 9')" -lt "$(line_of '^curl ')" ]] ||
    fail "an upgrade without a watcher did not hold the old pool lock first"
[[ "$(line_of 'drain-at-flock')" != 0 && "$(line_of 'drain-at-flock')" -lt "$(line_of 'flock -w 600 -x 9')" ]] ||
    fail "an upgrade without a watcher did not drain before taking the old pool lock"
drains_gone || fail "an upgrade without a watcher left the drain flag it set"

# The extract fails after the watcher was stopped: start it again.
# install_main is the condition of if, which suspends set -e inside it,
# so the download itself has to abort.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
curl_rc=1
if ( install_main ) > "$state/out" 2>"$state/err"; then
    fail "a failed extract was treated as success"
fi
grep -q 'The download failed' "$state/err" ||
    fail "a failed extract was not reported: $(cat "$state/err")"
[[ "$(line_of 'systemctl stop github-runner-watch.timer')" != 0 ]] || fail "the watcher was not stopped"
[[ "$(line_of 'systemctl start github-runner-watch.timer')" != 0 ]] ||
    fail "a failed extract left the watcher stopped"
[[ "$(grep -c 'systemctl start github-runner-watch.timer' "$log")" == 1 ]] ||
    fail "a failed extract started the watcher more than once: $(cat "$log")"
[[ "$(line_of 'drain-at-stop')" != 0 ]] || fail "a failed extract did not drain before stopping the watcher"
[[ "$(line_of 'drain-at-start')" == 0 ]] ||
    fail "a failed extract restarted the watcher while its own drain flag was still set"
drains_gone || fail "a failed extract left the drain flag it set"

# A drain the operator already set stays set, including when only one path is present.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR" "$(dirname "$POOL_DRAIN_FILE")"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
printf 'operator\n' > "$POOL_DRAIN_FILE"
printf 'operator\n' > "$LEGACY_POOL_DRAIN_FILE"
( install_main ) > "$state/out" 2>"$state/err" || fail "an upgrade with a drain set failed: $(cat "$state/err")"
[[ "$(cat "$POOL_DRAIN_FILE")" == operator ]] || fail "install rewrote the operator's drain flag"
[[ "$(cat "$LEGACY_POOL_DRAIN_FILE")" == operator ]] || fail "install rewrote the operator's legacy drain flag"
[[ "$(line_of 'systemctl start github-runner-watch.timer')" == 0 ]] ||
    fail "install restarted the watcher while the operator's drain was set: $(cat "$log")"
grep -q 'github-runner-watch.timer was left stopped' "$state/out" ||
    fail "install did not say the watcher stayed stopped: $(cat "$state/out")"
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR" "$(dirname "$POOL_DRAIN_FILE")"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
printf 'operator\n' > "$LEGACY_POOL_DRAIN_FILE"
( install_main ) > "$state/out" 2>"$state/err" || fail "an upgrade with a legacy drain failed: $(cat "$state/err")"
[[ ! -e "$POOL_DRAIN_FILE" ]] || fail "install published a new drain flag over an existing legacy drain"
[[ "$(cat "$LEGACY_POOL_DRAIN_FILE")" == operator ]] || fail "install cleared a pre-existing legacy drain flag"
[[ "$(line_of 'systemctl start github-runner-watch.timer')" == 0 ]] ||
    fail "install restarted the watcher while a legacy drain was set: $(cat "$log")"
grep -q 'github-runner-watch.timer was left stopped' "$state/out" ||
    fail "install did not say the watcher stayed stopped for a legacy drain: $(cat "$state/out")"

# runner stop during the install replaces both flags. stop truncates the
# new one and renames an empty file onto the legacy one, then blocks on
# the old pool lock. The flags stay, and the watcher stays stopped.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
operator_stop=1
( install_main ) > "$state/out" 2>"$state/err" || fail "runner stop during install failed: $(cat "$state/err")"
[[ -s "$state/token-new" && "$(cat "$state/token-new")" == "$(cat "$state/token-legacy")" ]] ||
    fail "install did not publish a token before runner stop replaced the drain"
[[ -f "$POOL_DRAIN_FILE" && ! -s "$POOL_DRAIN_FILE" ]] ||
    fail "install removed the drain flag runner stop truncated"
[[ -e "$LEGACY_POOL_DRAIN_FILE" && ! -L "$LEGACY_POOL_DRAIN_FILE" ]] ||
    fail "install removed the legacy drain flag runner stop replaced"
[[ "$(cat "$LEGACY_POOL_DRAIN_FILE")" != "$(cat "$state/token-new")" ]] ||
    fail "the replaced legacy drain still held install's token"
[[ "$(line_of 'systemctl start github-runner-watch.timer')" == 0 ]] ||
    fail "install restarted the watcher after runner stop set maintenance: $(cat "$log")"
grep -q 'github-runner-watch.timer was left stopped' "$state/out" ||
    fail "install did not say the watcher stayed stopped after runner stop: $(cat "$state/out")"
[[ "$(line_of '^curl ')" != 0 ]] || fail "runner stop during install aborted the extract"

# An active reclone unit has passed its drain check and not taken the
# shared lock. Install drops the exclusive lock, waits, and takes it again.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
reclone_active_passes=1
# Short enough that a unit which stays active fails this case quickly,
# and long enough for the one 2 second retry.
OLD_POOL_LOCK_WAIT=5
( install_main ) > "$state/out" 2>"$state/err" || fail "an active reclone unit aborted the install: $(cat "$state/err")"
[[ "$(grep -c 'flock -w [0-9][0-9]* -x 9' "$log")" == 2 ]] ||
    fail "an active reclone unit did not make install retry the old pool lock: $(cat "$log")"
[[ "$(grep -c 'systemctl list-units --state=active github-runner-reclone-' "$log")" == 2 ]] ||
    fail "install did not check for an active reclone unit twice: $(cat "$log")"
first_x=$(grep -n 'flock -w [0-9][0-9]* -x 9' "$log" | head -1 | cut -d: -f1)
second_x=$(grep -n 'flock -w [0-9][0-9]* -x 9' "$log" | tail -1 | cut -d: -f1)
listed=$(line_of 'systemctl list-units')
unlocked=$(line_of 'flock -u 9')
slept=$(line_of 'sleep 2')
[[ "$first_x" -lt "$listed" && "$listed" -lt "$unlocked" && "$unlocked" -lt "$slept" && "$slept" -lt "$second_x" ]] ||
    fail "reclone retry order was flock=$first_x list=$listed unlock=$unlocked sleep=$slept flock2=$second_x"
[[ "$second_x" -lt "$(line_of '^curl ')" ]] || fail "install extracted the tree before the reclone retry"
[[ "$(grep -c 'systemctl start github-runner-watch.timer' "$log")" == 1 ]] ||
    fail "a reclone retry started the watcher more than once: $(cat "$log")"
drains_gone || fail "a reclone retry left the drain flag install set"

# The same 10 minute budget covers the retry. A unit that stays active
# aborts, restarts the watcher, and clears the drain this install wrote.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
reclone_active_passes=100
OLD_POOL_LOCK_WAIT=1
if ( install_main ) > "$state/out" 2>"$state/err"; then
    fail "install kept going while a reclone unit stayed active"
fi
grep -q 'was not installed' "$state/err" ||
    fail "a reclone unit that stayed active was not reported: $(cat "$state/err")"
[[ "$(line_of '^curl ')" == 0 ]] || fail "a reclone unit that stayed active still extracted the tree"
[[ "$(grep -c 'flock -w [0-9][0-9]* -x 9' "$log")" == 1 ]] ||
    fail "a reclone deadline took the old pool lock more than once: $(cat "$log")"
[[ "$(line_of 'sleep 2')" == 0 ]] || fail "a reclone deadline slept past its budget: $(cat "$log")"
[[ "$(line_of 'systemctl start github-runner-watch.timer')" != 0 ]] ||
    fail "a reclone deadline left the watcher stopped"
drains_gone || fail "a reclone deadline left the drain flag install set"

# systemctl failing the unit list is the same as systemctl being absent:
# skip the check and keep the lock.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
systemctl_list_rc=127
OLD_POOL_LOCK_WAIT=3
( install_main ) > "$state/out" 2>"$state/err" ||
    fail "a failing systemctl aborted the install: $(cat "$state/err")"
[[ "$(grep -c 'flock -w [0-9][0-9]* -x 9' "$log")" == 1 ]] ||
    fail "a failing systemctl made install retry the old pool lock: $(cat "$log")"
[[ "$(grep -c 'systemctl list-units --state=active github-runner-reclone-' "$log")" == 1 ]] ||
    fail "install did not ask systemctl which reclone units are active: $(cat "$log")"
drains_gone || fail "a failing systemctl left the drain flag install set"

# A signal while the watcher is stopped still restarts it and clears the drain install set.
fresh
printf 'DOCKER_MIRROR_URL=\n' > "$CONFIG_FILE"
mkdir -p "$SYSTEMD_DIR" "$SNIPPETS_DIR"
: > "$SYSTEMD_DIR/github-runner-watch.timer"
stop_term=1
if ( install_main ) > "$state/out" 2>"$state/err"; then
    fail "a signal during upgrade was treated as success: $(cat "$state/err")"
fi
[[ "$(line_of 'systemctl start github-runner-watch.timer')" != 0 ]] ||
    fail "a signal during upgrade left the watcher stopped: $(cat "$log")"
[[ "$(grep -c 'systemctl start github-runner-watch.timer' "$log")" == 1 ]] ||
    fail "a signal during upgrade started the watcher more than once: $(cat "$log")"
drains_gone || fail "a signal during upgrade left the drain flag set"
[[ "$(line_of '^curl ')" == 0 ]] || fail "a signal during upgrade kept extracting"

# curl | bash reads this file from stdin, where BASH_SOURCE is empty. The
# guard still has to run install_main, and sourcing it must not.
mkdir -p "$state/fakebin"
cat > "$state/fakebin/curl" <<EOF
#!/bin/sh
printf 'curl %s\n' "\$*" >> "$log"
exit 1
EOF
chmod +x "$state/fakebin/curl"
run_stdin() {
    env PATH="$state/fakebin:$PATH" \
        INSTALL_DIR="$state/stdin-opt" \
        CONFIG_FILE="$state/missing.conf" \
        SYSTEMD_DIR="$state/stdin-systemd" \
        SNIPPETS_DIR="$state/stdin-snippets" \
        PVE_NODES_DIR="$state/stdin-nodes" \
        RUNNER_BIN="$state/stdin-bin/runner" \
        OLD_POOL_LOCK="$state/stdin-old.lock" \
        "$@"
}
: > "$log"
stdin_rc=0
run_stdin "$BASH" < "$root/install.sh" > "$state/stdin-out" 2>"$state/stdin-err" || stdin_rc=$?
[[ "$stdin_rc" -ne 0 ]] || fail "a stdin install treated a failed download as success"
grep -q 'Installing selfhosted-runners' "$state/stdin-out" ||
    fail "a stdin install did not run: $(cat "$state/stdin-out") $(cat "$state/stdin-err")"
grep -q 'The download failed' "$state/stdin-err" ||
    fail "a stdin install did not report the failed download: $(cat "$state/stdin-err")"
[[ "$(grep -c '^curl ' "$log")" == 1 ]] || fail "a stdin install did not download once: $(cat "$log")"
file_rc=0
run_stdin "$BASH" "$root/install.sh" > "$state/file-out" 2>"$state/file-err" || file_rc=$?
[[ "$file_rc" -ne 0 ]] || fail "a file install treated a failed download as success"
grep -q 'Installing selfhosted-runners' "$state/file-out" ||
    fail "a file install did not run: $(cat "$state/file-out") $(cat "$state/file-err")"

printf 'install-quiesce: ok\n'
