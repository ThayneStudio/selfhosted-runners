# Agent instructions

## Skills

Project skills live in **`.agents/skills/<name>/SKILL.md`**. Provider directories (`.claude/skills`, `.grok/skills`, `.codex/skills`, `.gemini/skills`, `.opencode/skills`, `.cursor/skills`) symlink to that canonical copy so Claude, Grok, Codex, Gemini, OpenCode, and Cursor load the same files.

- **`/spec`** — Fully specify a system/feature, then file a GitHub issue graph with dependency links. Do **not** implement in that session.

Edit skills only under `.agents/skills/`.
