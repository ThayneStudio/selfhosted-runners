#!/usr/bin/env bash
# Fails if a clone can start run.sh without --disableupdate, or if the JIT
# .runner document is no longer patched with disableUpdate=true on clones of a
# template that records its runner version (older templates keep updating).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
guest="$root/templates/runner-user-data.yaml"
bake="$root/templates/template-setup.yaml"

fail() {
    printf 'disableupdate: %s\n' "$1" >&2
    exit 1
}

[[ -f "$guest" ]] || fail "missing $guest"

run_lines=()
while IFS= read -r line; do
    run_lines+=("$line")
done < <(grep -n -- '--jitconfig' "$guest" | grep 'run\.sh' || true)

[[ ${#run_lines[@]} -eq 2 ]] || fail "expected 2 run.sh --jitconfig lines, found ${#run_lines[@]}"

for line in "${run_lines[@]}"; do
    [[ "$line" == *"--disableupdate"* ]] || fail "run.sh --jitconfig line lost --disableupdate: $line"
done

grep -q 'endswith(".runner")' "$guest" || fail "JIT patch no longer selects .runner keys"
grep -q '.disableUpdate = true' "$guest" || fail "JIT patch no longer sets disableUpdate"
grep -q 'Failed to set disableUpdate on the JIT runner config' "$guest" || fail "patch failure no longer exits"
# The patch is skipped only on templates without the record the bake writes.
grep -q 'if \[\[ -f /opt/.baked-runner-version \]\]; then' "$guest" \
    || fail "JIT patch is no longer gated on /opt/.baked-runner-version"
grep -q '> /opt/.baked-runner-version' "$bake" || fail "template bake no longer writes /opt/.baked-runner-version"
# The failure path must be an exit, not a warning that still starts run.sh.
awk '
    /Failed to set disableUpdate on the JIT runner config/ { seen = 1 }
    seen && /exit 1/ { found = 1; exit }
    seen && /run\.sh --jitconfig/ { exit 1 }
    END { exit found ? 0 : 1 }
' "$guest" || fail "disableUpdate patch failure does not exit 1 before run.sh"

# The executed filter is the one in the guest script, not a copy that can drift.
filter=$(awk '
    /patched=\$\(jq -c / { capture = 1; next }
    capture && /<<<"\$decoded"/ {
        sub(/^[[:space:]]+/, "")
        sub(/\047.*/, "")
        print
        exit
    }
    capture {
        sub(/^[[:space:]]+/, "")
        print
    }
' "$guest")
[[ -n "$filter" ]] || fail "could not extract the jq filter from $guest"

b64() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

runner_b64=$(b64 '{"agentName":"test"}')
migrated_b64=$(b64 '{"disableUpdate":false,"keep":1}')
cred_b64=$(b64 'credentials-stay')
payload=$(jq -nc \
    --arg r "$runner_b64" \
    --arg m "$migrated_b64" \
    --arg c "$cred_b64" \
    '{".runner":$r,".runner_migrated":$m,".credentials":$c}')

printf '%s' "$payload" | jq -e 'keys[] | select(endswith(".runner"))' >/dev/null \
    || fail "fixture has no .runner key"

patched=$(printf '%s' "$payload" | jq -c "$filter")
runner_json=$(printf '%s' "$patched" | jq -r '.[".runner"]' | base64 -d 2>/dev/null || printf '%s' "$patched" | jq -r '.[".runner"]' | base64 -D)
migrated_json=$(printf '%s' "$patched" | jq -r '.[".runner_migrated"]' | base64 -d 2>/dev/null || printf '%s' "$patched" | jq -r '.[".runner_migrated"]' | base64 -D)
cred_out=$(printf '%s' "$patched" | jq -r '.[".credentials"]' | base64 -d 2>/dev/null || printf '%s' "$patched" | jq -r '.[".credentials"]' | base64 -D)

printf '%s' "$runner_json" | jq -e '.disableUpdate == true' >/dev/null \
    || fail "patched .runner does not set disableUpdate true: $runner_json"
printf '%s' "$migrated_json" | jq -e '.disableUpdate == false and .keep == 1' >/dev/null \
    || fail ".runner_migrated was modified: $migrated_json"
[[ "$cred_out" == "credentials-stay" ]] || fail ".credentials was modified: $cred_out"

# No .runner key must fail the same test the guest uses, so run.sh is not reached.
if printf '%s' '{"other":"x"}' | jq -e 'keys[] | select(endswith(".runner"))' >/dev/null; then
    fail "a payload with no .runner key was accepted"
fi

# Clones must not grow a per-boot runner download. The tarball stays in the bake.
if grep -q 'actions-runner.tar.gz' "$guest" || grep -q 'releases/download' "$guest"; then
    fail "runner-user-data.yaml gained a download path"
fi
grep -q 'actions-runner-linux-x64' "$bake" || fail "template bake no longer downloads the runner tarball"
grep -q 'docker pull' "$bake" || fail "template bake no longer pulls Docker images"
grep -q 'playwright install' "$bake" || fail "template bake no longer installs Playwright"

printf 'disableupdate: ok\n'
