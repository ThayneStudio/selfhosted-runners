#!/usr/bin/env bash
# Run the repo's shell checks. There is no other test suite.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bash "$root/tests/cloud-image.sh"
bash "$root/tests/disableupdate.sh"
bash "$root/tests/rebake-decision.sh"
bash "$root/tests/rebake-safety.sh"
bash "$root/tests/setup-prompts.sh"
