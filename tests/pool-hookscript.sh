#!/usr/bin/env bash
# The post-stop hook must start reclone.sh as its own systemd unit, not as a
# child of the hook. A child stays in qmeventd.service's cgroup and dies with
# it on every qemu-server upgrade and at host shutdown.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'pool-hookscript: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
hook="$root/templates/runner-hookscript.sh"
fail() { printf 'pool-hookscript: %s\n' "$1" >&2; exit 1; }
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# The hook runs as a standalone script, so its commands are mocked as
# executables on PATH. Each records its arguments, one per line.
mkdir "$state/bin"
for cmd in systemd-run logger nohup setsid; do
    cat > "$state/bin/$cmd" <<EOF
#!/bin/sh
{ printf '%s\n' "\$@"; printf -- '--\n'; } >> "$state/$cmd.calls"
[ "$cmd" != systemd-run ] || exit "\$(cat "$state/systemd-run.rc" 2>/dev/null || echo 0)"
EOF
    chmod +x "$state/bin/$cmd"
done

run_hook() {
    rm -f "$state"/*.calls
    PATH="$state/bin:$PATH" bash "$hook" "$@" > "$state/out" 2>&1
}

run_hook 9001 post-stop || fail "post-stop hook exited non-zero"
[[ -f "$state/systemd-run.calls" ]] || fail "post-stop did not start a systemd unit"
expected=(--no-block --collect --quiet --unit=github-runner-reclone-9001
    --property=StandardOutput=append:/var/log/github-runner.log
    --property=StandardError=append:/var/log/github-runner.log
    /opt/selfhosted-runners/lib/reclone.sh 9001 --)
mapfile -t got < "$state/systemd-run.calls"
[[ "${got[*]}" == "${expected[*]}" ]] || fail "unexpected systemd-run call: ${got[*]}"
[[ ! -e "$state/nohup.calls" && ! -e "$state/setsid.calls" ]] || fail "reclone was also started as a child process"
grep -qx 'VM 9001 stopped, triggering reclone' "$state/logger.calls" || fail "post-stop was not logged"

# systemd refuses new units during host shutdown. The hook must not fall
# back to a child process, and must not fail the Proxmox stop task.
printf '1\n' > "$state/systemd-run.rc"
run_hook 9002 post-stop || fail "a refused unit failed the hook"
[[ ! -e "$state/nohup.calls" && ! -e "$state/setsid.calls" ]] || fail "a refused unit fell back to a child process"
grep -q 'could not start the reclone unit' "$state/logger.calls" || fail "a refused unit was not logged"
rm -f "$state/systemd-run.rc"

for phase in pre-start post-start pre-stop; do
    run_hook 9001 "$phase" || fail "$phase hook exited non-zero"
    [[ ! -e "$state/systemd-run.calls" ]] || fail "$phase started a reclone"
done

printf 'pool-hookscript: ok\n'
