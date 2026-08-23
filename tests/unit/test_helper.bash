# Forwarder so `load test_helper` works from tests/unit/*.bats. The harness
# itself lives one directory up; see tests/test_helper.bash.
# shellcheck source=../test_helper.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test_helper.bash"
