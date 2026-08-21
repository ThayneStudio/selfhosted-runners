---
name: spec
description: >
  Use when the user asks to spec out, fully specify, or plan an entire
  system, feature, or project before implementation, or to break planned
  work into GitHub issues with dependency links for a worker fleet or
  future sessions to pick up (spec, plan, roadmap, epic, milestone,
  backlog, issue graph, tickets). Use when the user runs /spec. Do not
  use when the user wants code written in this session, mentions a spec
  only to read, follow, or implement it, or means spec/test files
  (*.spec.ts, RSpec).
---

# Spec

Planning skill. You produce a complete spec and a GitHub issue graph. You do not implement.

**The planner never implements. Done = approved spec + filed issue graph — nothing less, nothing more.**

**Violating the letter of these rules is violating the spirit of these rules.**

This session ends when you have reported filed issue URLs (or written drafts, if you cannot file). It does not end with an implementation branch, an implementation PR, or "the first ticket started."

Write the spec file on disk. Commit it on the current branch only if the user wants it in git. Do not open a PR whose purpose is to implement the spec. Put the spec path **and** a short summary in the epic body so a 404 on the default branch is not fatal — leaves must be self-contained.

## Iron Law

```
NO IMPLEMENTATION. NO SILENT DEFERRAL. NO PARTIAL BACKLOG.
```

If you have not (1) written a complete spec, (2) gotten explicit approval, (3) shown an issue-graph dry-run, (4) gotten explicit approval, and (5) filed or drafted every in-scope issue, you are not done.

## When this skill applies

The user wants a system/feature/project specified, a backlog filed, an epic broken down, or a fleet fed. They may also be about to skip planning and code.

**Do not use** when they want code in this session, or when "spec" means a test file or an existing document to follow.

## Two gates

Copy this checklist and keep it visible:

```
Spec progress:
- [ ] 1. Explore conventions (labels, spec dir, existing issues)
- [ ] 2. Write the complete spec
- [ ] 3. Completeness self-review
- [ ] 4. GATE 1 — human approves the spec
- [ ] 5. Draft the issue graph (dry-run table + coverage table)
- [ ] 6. GATE 2 — human approves the dry-run
- [ ] 7. File issues (topological order) or write drafts and stop
- [ ] 8. Report URLs. STOP.
```

**Gate 1 approval message must end with:** "Next: I'll draft the issue graph for your approval. I will not implement."

**Gate 2 approval message must end with:** "If you say yes, I will file these issues and stop. I will not start any ticket."

"Looks good" on the spec is only Gate 1. "Looks good, start #1" is a red flag: refuse to code, **show the Gate 2 dry-run**, and wait. Do not file yet. Do not start #1.

**What counts as approval:** an explicit yes (or equivalent) in chat to the artifact you just showed. Do not treat silence, "go," or "ship it" as approval of a graph you have not shown. **Non-interactive / no human:** write the spec and issue drafts under `docs/specs/<slug>-issues/` (or next to the spec if that directory does not exist). Do not `gh issue create`. Report the draft paths.

## Completeness (Gate 1)

Holes mean planning is unfinished. Keep specifying.

A spec is complete when every in-scope part has: purpose, boundaries, interfaces, data shapes, error paths, migration/rollout if any, test strategy, and ops/failure concerns. Then answer this forcing question in the spec:

> List everything this system touches that still has no spec section.

If the list is non-empty, you are not at Gate 1.

**YAGNI shrinks the spec; it never shrinks the ratio of spec to issues.** Scope cuts become explicit, human-approved **Non-goals**. Everything that survives scoping is fully specified and filed.

Default spec path: `docs/specs/YYYY-MM-DD-<slug>.md`. If `docs/superpowers/specs/` exists, use that. Honor a path the user names.

## Verbs

| Verb | Meaning | What you produce |
|------|---------|------------------|
| **Deprioritize** | Later phase / further down the DAG | Fully specified. Filed as issues. Blocked-by earlier work. |
| **Include** | In scope now (phase 1 / unblocked work) | Fully specified. Filed as a leaf. No work-item blockers. |
| **Cut** | Out of the system | Human-approved **Non-goal** in the spec. No issue, or a closed `not planned` note if they want a record. |
| **Defer** | Cannot specify yet (needs an experiment, funding, unknown external constraint) | **Exceptional.** Ask first. If they confirm: spec section stating the gap + reason, and a tracking issue that is **not** fleet-ready. |

Human says "later," "next quarter," "phase 2," "don't boil the ocean," "just the slice": that is **deprioritize**, not defer. Spec it. File it. Do not implement the slice in this session.

Human says "skip it / we don't need it": confirm a **cut** (Non-goal).

**Defer** only if you *cannot write the spec*. Ask before leaving it out.

## Coverage invariant (required before Gate 2)

Fill this table. Every spec section maps to ≥1 issue, a Non-goal, or an approved deferral.

| Spec section | Issue(s) | Verb | Phase |
|--------------|----------|------|-------|
| … | #title | include / deprioritize / cut / defer | 1 / 2 / … |

Empty cells are the bug. Do not file until the table is full.

## Issue graph (Gate 2)

Show a dry-run table **before any `gh issue create`:**

| Title | Repo | Type (epic/leaf) | Labels | Blocked by | Phase |
|-------|------|------------------|--------|------------|-------|
| … | owner/repo | leaf | … | … | 1 |

Then file only after yes. **Read [references/issue-graph.md](references/issue-graph.md)** for the body template, `gh` commands, orcest vs generic labels, and re-run/dedupe.

Hard rules:

- **Leaves** are one-worker jobs. Epics/parents are tracking only. **Epic/parent is not a blocker.** Never `--blocked-by` the epic and never put `Blocked by #<epic>` in a leaf.
- **Dual dependency encoding** applies only when a leaf is blocked by another **work** issue: native `--blocked-by` **and** a body line `Blocked by #N` (same-repo). Unblocked leaves: no `--blocked-by`, body says `None`. Cross-repo: native blocked-by only (issue URL). Multiple blockers: `--blocked-by 200,201` and one `Blocked by #N` line per blocker.
- File **work blockers first** so numbers exist.
- Never use `Closes` / `Fixes` / `Resolves #N` as a dependency. Never a bare `#N`. Never parent/sub-issue hierarchy as the pickup gate (`--parent` is extra tracking, not a substitute). Attach `--parent` **after** the leaf is created so a sub-issue failure cannot abort filing.
- **Orcest, if `orcest:ready` exists:** blocked leaves still get `orcest:ready`. Do **not** apply `orcest:blocked` for dependency waits — that label is terminal and is never auto-cleared, so the fleet starves. Epics never get `orcest:ready`.
- Detect with `gh label list --search orcest`. If `orcest:ready` is absent, generic mode (native blocked-by + body text, no `orcest:*` flags). Do not invent labels without asking.
- Any issue with runnable payloads (IDs, SQL, bids) gets a data-window/expiry block. Pick expiry from how fast the inputs move. **Expiry is not a reason to omit the issue.**

## STOP after filing

Report issue numbers and URLs. Stop.

Do not: create a feature branch, start ticket #1, "knock out the trivial one," open a PR, or sketch production code "as reference."

## Rationalizations

| Excuse | Reality |
|--------|---------|
| "The human already scoped it to this slice" | Slice = phase or cut. If phase: spec + file the rest further down the DAG. If cut: they confirm Non-goals. Not a license to omit or to code. |
| "The fleet is idle — implement now" | An idle fleet wants a **full filed graph**. Implementing yourself feeds one ticket and starves the rest. |
| "Later-phase issues expire / go stale" | File them. Add a data-window if they have payloads. Stale filed work is cheaper than work that was never written down. |
| "YAGNI — skip audit/SSO/the rest" | YAGNI decides Non-goals (with approval). It does not leave holes. Later phases still get spec sections and issues. |
| "I'll just start ticket #1" | Planner never implements. File, report, stop. |
| "The first issue is trivial, I'll knock it out" | Then a worker has nothing, and you raced the fleet. File it as `orcest:ready` (if applicable) and stop. |
| "We can defer phase 3" | Deprioritize: still spec, still file. Defer only if it cannot be specified, and only after asking. |
| "This part is obvious, no issue needed" | Obvious work is still an issue. No silent leftovers. |
| "I'll file the important issues now, the rest later" | Partial backlog is the failure mode. Coverage table must be full. |
| "Label dependents `orcest:blocked` so workers wait" | Terminal label; never auto-cleared. Use `orcest:ready` + blocked-by. |
| "I'll spec now and file issues after I code the spike" | Spec + graph first. A spike is a throwaway, or an experiment that must be asked as a deferral. |
| "Non-interactive, so I'll just implement" | Write spec + issue drafts under `docs/specs/<slug>-issues/`. Do not file, do not code. |
| "Blocked by the epic so it stays grouped" | Epic is tracking, not a blocker. That wait never clears. Use `--parent` only. |

## Red flags — STOP

- Writing application code, tests-for-the-feature, or a feature branch
- "I'll just start ticket #1"
- "Phase 2" as a one-line note with no spec section and no issues
- Applying `orcest:blocked` for a GitHub-issue dependency
- `Blocked by #<epic>` or `--blocked-by` the tracking issue
- Labeling an epic `orcest:ready`
- Filing without a dry-run table the human approved
- Self-approving Gate 1 or Gate 2
- Omitting work because issues might go stale
- `Closes #N` used as a blocker
- "Keep this sketch as reference and start coding"

**All of these mean: return to the checklist. Do not implement.**

## Packaging

This folder is the skill. Copy it into other repos as `.agents/skills/spec/`, `.claude/skills/spec/`, or `.grok/skills/spec/`. See [references/packaging.md](references/packaging.md).
