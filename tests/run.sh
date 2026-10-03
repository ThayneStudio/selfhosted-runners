#!/usr/bin/env bash
# Run the repo's shell checks. There is no other test suite.
# Every other tests/*.sh is one check; adding a file adds a check.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
for check in "$root"/tests/*.sh; do
    [[ "$check" == "$root/tests/run.sh" ]] && continue
    bash "$check"
done
