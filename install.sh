#!/bin/bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/selfhosted-runners}"
REPO_URL="${REPO_URL:-https://github.com/ThayneStudio/selfhosted-runners/archive/refs/heads/master.tar.gz}"
CONFIG_FILE="${CONFIG_FILE:-/etc/github-runners.conf}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SNIPPETS_DIR="${SNIPPETS_DIR:-/var/lib/vz/snippets}"
PVE_NODES_DIR="${PVE_NODES_DIR:-/etc/pve/nodes}"
RUNNER_BIN="${RUNNER_BIN:-/usr/local/bin/runner}"
# The previous version's pool lock. New code uses /run/github-runners.
OLD_POOL_LOCK="${OLD_POOL_LOCK:-/run/lock/github-runner-pool.lock}"
OLD_POOL_LOCK_WAIT="${OLD_POOL_LOCK_WAIT:-600}"
# Old hookscript and old reclone.sh look at the legacy path. The new tree
# looks at POOL_DRAIN_FILE. An upgrade sets both when neither is already set.
POOL_DRAIN_FILE="${POOL_DRAIN_FILE:-/run/github-runners/github-runner-drain}"
LEGACY_POOL_DRAIN_FILE="${LEGACY_POOL_DRAIN_FILE:-/run/lock/github-runner-drain}"

# Set while an upgrade holds the old pool lock, has stopped the watcher,
# or has published a drain flag of its own.
UPGRADE_TIMER_STOPPED=0
UPGRADE_LOCK_HELD=0
UPGRADE_DRAIN_SET=0

# Drop the old pool lock, start the watcher, then clear a drain this
# install published. The watcher is started while the drain is still set,
# so its first tick does not fill a slot the old reclone skipped. Safe to
# call twice. An EXIT trap that ends in a successful command would hide
# the failure that caused the exit, so the trap exits again with the
# status it saved.
release_upgrade_quiesce() {
    if (( UPGRADE_LOCK_HELD )); then
        flock -u 9 2>/dev/null || true
        exec 9>&-
        UPGRADE_LOCK_HELD=0
    fi
    if (( UPGRADE_TIMER_STOPPED )); then
        systemctl start github-runner-watch.timer 2>/dev/null || true
        UPGRADE_TIMER_STOPPED=0
    fi
    if (( UPGRADE_DRAIN_SET )); then
        rm -f -- "$POOL_DRAIN_FILE" "$LEGACY_POOL_DRAIN_FILE" || true
        UPGRADE_DRAIN_SET=0
    fi
}

on_upgrade_exit() {
    local status=$?
    release_upgrade_quiesce
    exit "$status"
}

on_upgrade_signal() {
    release_upgrade_quiesce
    trap - EXIT INT TERM HUP
    exit 1
}

abort_upgrade() {
    printf '%s\n' "$1" >&2
    release_upgrade_quiesce
    exit 1
}

# A oneshot stays "activating" until ExecStart returns. is-active --quiet
# is false for that, so match the state text. Do not stop the service:
# that would kill a clone the pool lock is what we wait for.
wait_for_watch_service() {
    local state deadline
    deadline=$((SECONDS + OLD_POOL_LOCK_WAIT))
    while true; do
        state=$(systemctl is-active github-runner-watch.service 2>/dev/null || true)
        case "$state" in
            active|activating|deactivating) ;;
            *) return 0 ;;
        esac
        if (( SECONDS >= deadline )); then
            return 1
        fi
        sleep 1
    done
}

# Operator maintenance is a regular file at either drain path. A symlink
# is replaced below: the old hookscript treats any existing path as a drain,
# and the link would send that check somewhere else.
upgrade_drain_active() {
    if [[ -f "$POOL_DRAIN_FILE" && ! -L "$POOL_DRAIN_FILE" ]]; then
        return 0
    fi
    if [[ -f "$LEGACY_POOL_DRAIN_FILE" && ! -L "$LEGACY_POOL_DRAIN_FILE" ]]; then
        return 0
    fi
    return 1
}

# Publish both drain flags. The new directory is mode 0700. The legacy
# directory is /run/lock (1777); do not chmod it. mv replaces a symlink
# there instead of writing through it.
publish_upgrade_drain() {
    local dir tmp
    dir=$(dirname -- "$POOL_DRAIN_FILE")
    [[ -n "$dir" && "$dir" != "/" && "$dir" != "." && ! -L "$dir" ]] || return 1
    if [[ ! -d "$dir" ]]; then
        install -d -m 700 "$dir" || return 1
    fi
    if [[ -L "$POOL_DRAIN_FILE" ]]; then
        rm -f -- "$POOL_DRAIN_FILE" || return 1
    fi
    : > "$POOL_DRAIN_FILE" || return 1

    dir=$(dirname -- "$LEGACY_POOL_DRAIN_FILE")
    [[ -d "$dir" && ! -L "$dir" && -w "$dir" ]] || return 1
    tmp=$(mktemp "$dir/.github-runner-drain.XXXXXX") || return 1
    if ! mv -f "$tmp" "$LEGACY_POOL_DRAIN_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Old processes flock /run/lock/github-runner-pool.lock. The tree we are
# about to extract flocks /run/github-runners/github-runner-pool.lock, so
# an in-flight reclone and a new watch tick would both fill one slot.
# A VM that stops while that lock is held would start an old reclone,
# which passes its drain check and then blocks on the lock; when the lock
# is released it keeps going on the old paths. Set both drain flags first,
# unless one is already set, so that reclone exits before it takes the
# lock. Then stop the timer, let the current tick finish, and hold the
# old lock until the new units are in place. A host with no config is
# new: no timer and no lock.
quiesce_old_pool() {
    trap on_upgrade_exit EXIT
    trap on_upgrade_signal INT TERM HUP
    if ! upgrade_drain_active; then
        UPGRADE_DRAIN_SET=1
        publish_upgrade_drain || abort_upgrade "Could not set the maintenance drain, so the new tree was not installed."
    fi
    if [[ -f "$SYSTEMD_DIR/github-runner-watch.timer" ]]; then
        UPGRADE_TIMER_STOPPED=1
        systemctl stop github-runner-watch.timer
        if ! wait_for_watch_service; then
            abort_upgrade "github-runner-watch.service was still running after ${OLD_POOL_LOCK_WAIT}s, so the new tree was not installed. The watcher has been started again."
        fi
    fi
    # /run/lock is 1777. A symlink here would make flock wait on some
    # other file while the real lock stayed free.
    if [[ -L "$OLD_POOL_LOCK" ]]; then
        rm -f -- "$OLD_POOL_LOCK"
    fi
    exec 9>"$OLD_POOL_LOCK"
    if ! flock -w "$OLD_POOL_LOCK_WAIT" -x 9; then
        exec 9>&-
        abort_upgrade "Timed out after ${OLD_POOL_LOCK_WAIT}s waiting for $OLD_POOL_LOCK. A clone started by the previous version is still running, so the new tree was not installed. The watcher has been started again."
    fi
    UPGRADE_LOCK_HELD=1
}

install_main() {
    echo "Installing selfhosted-runners..."

    if [[ -f "$CONFIG_FILE" ]]; then
        quiesce_old_pool
    fi

    # Download and extract. The status is checked here because a caller that
    # runs install_main from if or || suspends set -e for the whole function,
    # so pipefail on its own does not stop the rest of the install.
    mkdir -p "$INSTALL_DIR"
    if ! curl -fsSL "$REPO_URL" | tar xz --strip-components=1 -C "$INSTALL_DIR"; then
        if (( UPGRADE_TIMER_STOPPED )); then
            abort_upgrade "The download failed, so the new tree was not installed. The watcher has been started again."
        fi
        abort_upgrade "The download failed, so the new tree was not installed."
    fi
    chmod +x "$INSTALL_DIR/runner" "$INSTALL_DIR/lib/"*.sh

    # Symlink to /usr/local/bin
    ln -sf "$INSTALL_DIR/runner" "$RUNNER_BIN"

    echo "Installed to $INSTALL_DIR"

    # If setup was already run, sync deployed files (hookscript, systemd units)
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Updating deployed files..."
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        if [[ -d "$SNIPPETS_DIR" ]]; then
            cp "$INSTALL_DIR/templates/runner-hookscript.sh" "$SNIPPETS_DIR/runner-hookscript.sh"
            chmod 755 "$SNIPPETS_DIR/runner-hookscript.sh"
            DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-}" awk '
            function lreplace(str, old, new,    i, result) {
                result = ""
                while ((i = index(str, old)) > 0) {
                    result = result substr(str, 1, i - 1) new
                    str = substr(str, i + length(old))
                }
                return result str
            }
            {
                $0 = lreplace($0, "{{DOCKER_MIRROR_URL}}", ENVIRON["DOCKER_MIRROR_URL"])
                print
            }' "$INSTALL_DIR/templates/template-setup.yaml" > "$SNIPPETS_DIR/template-setup.yaml"
            chmod 600 "$SNIPPETS_DIR/template-setup.yaml"
        fi
        if [[ -f "$SYSTEMD_DIR/github-runner-watch.timer" ]]; then
            cp "$INSTALL_DIR/templates/github-runner-watch.service" "$SYSTEMD_DIR/"
            cp "$INSTALL_DIR/templates/github-runner-watch.timer" "$SYSTEMD_DIR/"
        fi
        cp "$INSTALL_DIR/templates/github-runner-rebake.service" "$SYSTEMD_DIR/"
        cp "$INSTALL_DIR/templates/github-runner-rebake.timer" "$SYSTEMD_DIR/"
        systemctl daemon-reload
        systemctl enable --now github-runner-rebake.timer 2>/dev/null || true
        echo "Template rebake timer enabled (daily, separate from the pool watcher)."
        echo "A first enable waits for the next midnight before the timer's first check."
        echo "A host with no recorded baked version bakes once on that first check."
        echo "To run that check now: runner rebake"
        echo "Do not install or enable it while a template bake is still running."
        # Prune obsolete per-org snippets. These embedded the org PAT; the PAT now
        # stays on the host and a single-use JIT config is rendered per-VM at clone time.
        if compgen -G "$SNIPPETS_DIR/runner-user-data-*.yaml" > /dev/null; then
            rm -f "$SNIPPETS_DIR"/runner-user-data-*.yaml
            echo "  Removed obsolete per-org PAT snippets"
        fi
        echo "Done. No need to re-run setup."
        # VMs cloned from those snippets keep the PAT until they are destroyed.
        # Look for the VMs, not the snippets: an earlier run may have removed the
        # snippets, and clones made with JIT configs never held the PAT.
        pat_vms=$(grep -ls '^cicustom:.*user=local:snippets/runner-user-data-' "$PVE_NODES_DIR"/*/qemu-server/*.conf | wc -l) || pat_vms=0
        if (( pat_vms > 0 )); then
            echo ""
            echo "WARNING: $((pat_vms)) runner VM(s) cloned from the old per-org snippets still have the org PAT"
            echo "on their cloud-init drive, where any job they run can read it, until they are"
            echo "destroyed. Recycle the pool to destroy them, now or once the first rebake has"
            echo "published a new template:"
            echo "  runner stop && runner start"
        fi
    else
        echo ""
        echo "Run the setup wizard:"
        echo "  runner setup"
    fi

    release_upgrade_quiesce
    trap - EXIT INT TERM HUP
    echo ""
}

# A file execution has BASH_SOURCE equal to $0. curl | bash leaves it
# unset, and set -u would trip on a bare ${BASH_SOURCE[0]}. Sourcing (the
# tests) sets BASH_SOURCE to this file and $0 to the caller.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    install_main "$@"
fi
