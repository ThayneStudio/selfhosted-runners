#!/usr/bin/env bash
# Runner VM destroys must not pass --purge. It removes the VMID from backup
# job configs, and the next runner usually reuses that VMID, so an operator's
# exclusion of runner VMIDs quietly disappears.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'pool-no-purge: %s\n' "$1" >&2; exit 1; }

for file in lib/recycle.sh lib/reclone.sh lib/destroy.sh lib/stop.sh lib/watch.sh; do
    [[ -f "$root/$file" ]] || fail "missing $file"
    # Comments may name the flag; commands may not.
    if hits=$(grep -nE '^[[:space:]]*[^#[:space:]][^#]*--purge' "$root/$file"); then
        fail "$file still passes --purge: $hits"
    fi
done

printf 'pool-no-purge: ok\n'
