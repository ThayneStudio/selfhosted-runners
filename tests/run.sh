#!/usr/bin/env bash
# Run the repo's shell checks. There is no other test suite.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bash "$root/tests/setup-prompts.sh"
