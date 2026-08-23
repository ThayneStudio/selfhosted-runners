#!/usr/bin/env bash
# Run the same gates CI runs: shellcheck, yamllint, bats.
#
#   tests/run.sh          everything
#   tests/run.sh unit     bats only
#   tests/run.sh lint     shellcheck + yamllint only
#
# bats is fetched on first use into tests/.bats (gitignored) if it is not
# already installed. Keep the commands here in step with .github/workflows/ci.yml.
set -uo pipefail

# The code under test uses mapfile and associative arrays, and so does this
# script. macOS still ships bash 3.2 as /bin/bash.
if (( BASH_VERSINFO[0] < 4 )); then
    printf 'tests/run.sh needs bash 4 or newer (found %s).\n' "$BASH_VERSION" >&2
    printf 'On macOS: brew install bash\n' >&2
    exit 2
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
BATS_VERSION="v1.11.0"
BATS_HOME="$TESTS_DIR/.bats"

# A missing linter is a skip locally and a failure in CI, where the workflow
# installs it explicitly — a silently skipped gate is not a green gate.
REQUIRE_TOOLS="${REQUIRE_TOOLS:-${CI:-}}"

FAILED=0

gate_start() {
    printf '\n==> %s\n' "$1"
}

gate_end() {
    local rc="$1" name="$2"
    [[ "$rc" -eq 0 ]] && return 0
    printf '!!! %s failed\n' "$name" >&2
    FAILED=1
}

missing_tool() {
    local tool="$1"
    if [[ -n "$REQUIRE_TOOLS" ]]; then
        printf '!!! %s is not installed\n' "$tool" >&2
        FAILED=1
    else
        printf '\n==> skipping %s (not installed)\n' "$tool"
    fi
}

# Expand globs, dropping the ones that matched nothing. Passing an unmatched
# glob straight to a linter reads as a missing file and fails the gate.
existing_files() {
    local candidate
    for candidate in "$@"; do
        [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
    done
}

lint_shell() {
    local -a files
    mapfile -t files < <(existing_files \
        "$REPO_ROOT/runner" \
        "$REPO_ROOT/install.sh" \
        "$REPO_ROOT"/lib/*.sh \
        "$REPO_ROOT"/templates/*.sh \
        "$REPO_ROOT"/tests/run.sh \
        "$REPO_ROOT"/tests/test_helper.bash \
        "$REPO_ROOT"/tests/unit/test_helper.bash \
        "$REPO_ROOT"/tests/stubs/bin/_stub \
        "$REPO_ROOT"/tests/compat/bin/md5sum)

    # -x plus SCRIPTDIR makes shellcheck read lib/common.sh when it is sourced,
    # so checks that depend on knowing a variable exists work across files.
    # It does not check that a called function is defined anywhere; ShellCheck
    # has no such check, so a renamed helper still has to be caught by a test.
    shellcheck -x --source-path=SCRIPTDIR --format=gcc "${files[@]}"
}

lint_yaml() {
    local -a files
    mapfile -t files < <(existing_files \
        "$REPO_ROOT"/templates/*.yaml \
        "$REPO_ROOT"/templates/*.yml \
        "$REPO_ROOT"/.github/workflows/*.yml \
        "$REPO_ROOT"/.github/workflows/*.yaml)

    yamllint -c "$REPO_ROOT/.yamllint.yml" "${files[@]}"
}

# Prefer an installed bats, but only one new enough for BATS_TEST_TMPDIR and
# the rest of what the harness assumes. Distro packages are often years old and
# would change harness behavior silently rather than failing loudly.
find_bats() {
    local candidate major minor
    for candidate in "$(command -v bats || true)" "$BATS_HOME/bats-core/bin/bats"; do
        [[ -x "$candidate" ]] || continue
        major="" minor=""
        read -r major minor <<< "$("$candidate" --version 2>/dev/null |
            sed -n 's/^Bats \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
        [[ -n "${major:-}" ]] || continue
        if (( major > 1 || (major == 1 && minor >= 5) )); then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

install_bats() {
    printf '==> fetching bats-core %s into %s\n' "$BATS_VERSION" "$BATS_HOME"
    mkdir -p "$BATS_HOME"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$BATS_VERSION" \
        https://github.com/bats-core/bats-core.git "$BATS_HOME/bats-core"
}

unit() {
    local bats
    if ! bats=$(find_bats); then
        install_bats || {
            printf '!!! could not install bats-core (no network?)\n' >&2
            printf '    install it manually: https://bats-core.readthedocs.io\n' >&2
            return 1
        }
        bats=$(find_bats) || return 1
    fi
    "$bats" "$TESTS_DIR/unit"
}

lint_gates() {
    if command -v shellcheck >/dev/null; then
        gate_start shellcheck
        lint_shell
        gate_end $? shellcheck
    else
        missing_tool shellcheck
    fi

    if command -v yamllint >/dev/null; then
        gate_start yamllint
        lint_yaml
        gate_end $? yamllint
    else
        missing_tool yamllint
    fi
}

unit_gate() {
    gate_start bats
    unit
    gate_end $? bats
}

case "${1:-all}" in
    lint) lint_gates ;;
    unit) unit_gate ;;
    all)  lint_gates; unit_gate ;;
    *)
        printf 'usage: %s [all|lint|unit]\n' "$0" >&2
        exit 2
        ;;
esac

exit "$FAILED"
