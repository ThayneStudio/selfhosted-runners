#!/usr/bin/env bash
# A test that calls into the pool must not leave the host's drain flag,
# locks or state as the path those calls write. The defaults are absolute
# host paths, so an override has to name the test's own scratch directory.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ ! -x "$candidate" ]] || exec "$candidate" "$0" "$@"
    done
    printf 'host-scratch: bash 4+ is required\n' >&2
    exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'host-scratch: %s\n' "$1" >&2; exit 1; }

# Calls that reach pool_is_draining, enable_pool_drain or disable_pool_drain.
# clone_runner's definition has no space before '(; a call does.
triggers='enable_pool_drain|disable_pool_drain|pool_is_draining|start_main|watch_main|reclone_main|fill_runner_slot|refill_runner_slot|acquire_clone_slot|clone_runner[[:space:]]|lib/create\.sh|cmd stop|cmd create|cmd start'

for check in "$root"/tests/*.sh; do
    base=$(basename "$check")
    [[ "$base" == run.sh || "$base" == host-scratch.sh ]] && continue
    # Full-line comments may name a function the test never calls.
    body=$(grep -vE '^[[:space:]]*#' "$check" || true)
    grep -Eq "$triggers" <<< "$body" || continue
    if ! grep -Eq 'LEGACY_POOL_DRAIN_FILE="?\$\{?(state|run)/' <<< "$body"; then
        fail "$base calls into the pool without pointing LEGACY_POOL_DRAIN_FILE at its scratch dir"
    fi
done

printf 'host-scratch: ok\n'
