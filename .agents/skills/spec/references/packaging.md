# Packaging

The skill is this directory (`spec/`), not a global install. Copy the folder into each repo that should use it.

## Install

Copy `spec/` so the harness you use can see `SKILL.md`:

| Harness | Path |
|---------|------|
| Codex / portable | `<repo>/.agents/skills/spec/` |
| Claude Code | `<repo>/.claude/skills/spec/` |
| Grok | `<repo>/.grok/skills/spec/` |

Same files in all three. Prefer one canonical copy plus symlinks if a repo uses multiple harnesses:

```bash
mkdir -p .agents/skills
cp -R spec .agents/skills/spec
# optional
mkdir -p .claude/skills .grok/skills
ln -s ../../.agents/skills/spec .claude/skills/spec
ln -s ../../.agents/skills/spec .grok/skills/spec
```

Do not add harness-only frontmatter (`allowed-tools`, Claude `argument-hint`, etc.). Portable fields are `name` and `description` only.

## What travels with it

- `SKILL.md` — discipline and gates
- `references/issue-graph.md` — templates and `gh` commands
- `references/packaging.md` — this file
- `agents/openai.yaml` — optional Codex display; safe to keep or drop

Repo-specific conventions (spec directory, extra labels) are **detected at run time**, not baked into the skill. Do not fork the skill per project unless the fleet contract itself differs.

## Distributed systems

A system that spans repos gets this folder in **each** repo you plan in. Run `/spec` in the repo that owns that slice. Cross-repo blockers use native `blocked-by` (URLs / `owner/repo#N`), not body `#N`.
