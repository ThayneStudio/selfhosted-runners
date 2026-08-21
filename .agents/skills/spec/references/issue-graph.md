# Issue graph

Loaded from `spec` SKILL.md. Commands use `gh` only — no harness-specific tools.

`--blocked-by` / `--add-blocked-by` need **gh ≥ 2.94.0**. If missing, use the GraphQL fallback below. Same-repo body `Blocked by #N` still works; **cross-repo does not** (native blocked-by only).

## Epic ≠ blocker

`--parent` / `gh issue edit --parent` is hierarchy (progress on the epic). It is **not** a pickup gate.

Never `--blocked-by` the epic. Never put `Blocked by #<epic>` in a leaf. A tracking issue that never closes would defer every leaf forever.

## Body template (leaves)

Keep every section. **Unblocked leaves** use `None`. Fill `Blocked by #N` only for **work-item** blockers, never the epic.

```markdown
## Problem

<What is wrong or missing. One concrete operator/user failure.>

## Context

<What already exists. Files, issues, decisions. "Do not rebuild X.">

## Non-goals

- <Explicitly out of this ticket>

## What to do

1. <Sequenced, testable steps>

## Acceptance

- <Command, test, or observable check>
- <What must not change>

## Blockers

None
```

Dependent example (same-repo; one line per blocker; not in a fenced block in the real body):

```markdown
## Blockers

Blocked by #12.
Blocked by #15.
```

Cite a known-good shape when useful: ThayneStudio/orcest#569 (problem, existing code, non-goals, acceptance, `Blocked by #564`).

Epics: short index — spec path, summary of the system, child list after filing. No implementation steps. **Do not** label epics `orcest:ready`.

## Labels

```bash
gh label list --repo OWNER/REPO --search orcest --json name --limit 20
```

**Orcest mode** if `orcest:ready` is in that list:

| Issue | Labels |
|-------|--------|
| Leaf, unblocked or blocked-by GitHub **work** issues | `orcest:ready` (+ type labels if the repo uses them) |
| Leaf, waiting on a **non-issue** (funding, experiment, human decision) | `orcest:blocked` — only this case, and only after asking |
| Epic / parent | no `orcest:ready`, no `orcest:blocked` |

Blocked-by GitHub work issues: keep `orcest:ready`. The orchestrator defers while those blockers are open and enqueues on the next poll when they close. `orcest:blocked` is terminal and is not auto-cleared.

**Generic mode** if `orcest:ready` is absent: native `--blocked-by` + body text. Pass **no** `orcest:*` flags. Do not create those labels unless the user asks.

## File in topological order

1. Detect labels (`--search orcest`).
2. Create the epic (no ready label). Capture URL and number.
3. Create unblocked leaves. Body `## Blockers` / `None`. No `--blocked-by`. No `--parent` on create.
4. Create dependents with `--blocked-by` (numbers or URLs, comma-separated for many) and matching `Blocked by #N` lines.
5. Optionally `gh issue edit <leaf> --parent <epic URL>`. If this fails, the leaf is still filed — report the attach failure.
6. Patch the epic body with the child list and spec path.

```bash
REPO=OWNER/REPO
DRAFT=$(mktemp -d)

# Detect orcest without inventing labels
if gh label list --repo "$REPO" --search orcest --json name --jq '.[].name' | grep -qx 'orcest:ready'; then
  READY=(--label orcest:ready)
else
  READY=()
fi

EPIC_URL=$(gh issue create --repo "$REPO" --title "Epic: <system>" --body-file "$DRAFT/epic.md")
EPIC_N=${EPIC_URL##*/}

# Unblocked root leaf — not blocked by the epic
SCHEMA_URL=$(gh issue create --repo "$REPO" --title "<schema work>" "${READY[@]}" --body-file "$DRAFT/schema.md")
SCHEMA_N=${SCHEMA_URL##*/}

# Dependent: native blocked-by AND body line (schema.md/api.md written with real numbers)
API_URL=$(gh issue create --repo "$REPO" --title "<api work>" "${READY[@]}" \
  --blocked-by "$SCHEMA_URL" --body-file "$DRAFT/api.md")
API_N=${API_URL##*/}

# Diamond: --blocked-by "$SCHEMA_URL,$OTHER_URL"

# Parent is extra tracking; do not fail the graph if sub-issues are off
gh issue edit "$SCHEMA_N" --repo "$REPO" --parent "$EPIC_URL" || true
gh issue edit "$API_N" --repo "$REPO" --parent "$EPIC_URL" || true

gh issue edit "$EPIC_N" --repo "$REPO" --body-file "$DRAFT/epic-with-children.md"
```

`$DRAFT/api.md` must contain `Blocked by #${SCHEMA_N}` in prose, **not** in a fenced code block.

Cross-repo: `--blocked-by` with the blocker issue **URL**. Do **not** rely on body `Blocked by #N` across repos.

### If `gh issue create` has no `--blocked-by`

Still write the body line (same-repo). Then either:

```bash
gh issue edit "$API_N" --repo "$REPO" --add-blocked-by "$SCHEMA_URL"
```

or GraphQL (needs node IDs, not numbers):

```bash
ISSUE_ID=$(gh issue view "$API_N" --repo "$REPO" --json id --jq .id)
BLOCKER_ID=$(gh issue view "$SCHEMA_N" --repo "$REPO" --json id --jq .id)
gh api graphql -f query='
mutation($issueId:ID!, $blockingIssueId:ID!) {
  addBlockedBy(input: {issueId: $issueId, blockingIssueId: $blockingIssueId}) {
    blockingIssue { number }
  }
}' -f issueId="$ISSUE_ID" -f blockingIssueId="$BLOCKER_ID"
```

If native links still fail, keep the body line, tell the user, and **do not** file cross-repo dependents as if they were gated.

## Re-run / dedupe

```bash
gh issue list --repo OWNER/REPO --search "<spec slug OR distinctive title>" --limit 50
```

Search open **and** recently closed (omit `--state open`, or run both). If matching issues exist: reuse them, update bodies/links, do not create duplicates. Say what you reused.

## Executable payloads

If a body contains live IDs, bids, SQL, or other runnable payloads, open with:

```markdown
> **Data window:** YYYY-MM-DD → YYYY-MM-DD
> **Derived:** YYYY-MM-DD
> **Expires:** YYYY-MM-DD — after this, re-derive. Do not run the payloads as written.
```

Pick expiry from how fast the inputs move. Still file the issue. Expiry is not a reason to omit the work.

## Dry-run table (Gate 2)

Use real labels for the repo (`orcest:ready` only in orcest mode; otherwise leave Labels empty or use existing type labels).

| Title | Repo | Type | Labels | Blocked by | Phase |
|-------|------|------|--------|------------|-------|
| Epic: … | owner/repo | epic | (none ready) | — | — |
| … | owner/repo | leaf | (ready if orcest) | — | 1 |
| … | owner/repo | leaf | (ready if orcest) | #schema | 1 |
| … | owner/repo | leaf | (ready if orcest) | #api | 2 |
