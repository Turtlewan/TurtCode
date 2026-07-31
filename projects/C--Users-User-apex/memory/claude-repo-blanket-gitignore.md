---
name: claude-repo-blanket-gitignore
description: ~/.claude git repo blanket-ignores everything; commit skill/registry files with git add -f
metadata: 
  node_type: memory
  type: project
  originSessionId: 38e016f5-d77a-4bfe-979d-8200d06882ef
  modified: 2026-07-29T09:17:22.802Z
---

The `~/.claude` git repo's `.gitignore` is a blanket `*` + `!.gitignore` — it ignores
everything. Skill files (`skills/apex-*/SKILL.md`, `impl.md`), `registry/domains.md`, etc. are
nonetheless **tracked** (prior commits force-added them).

**Why:** a plain `git add skills/apex-foo/SKILL.md` fails with "paths are ignored" even though
the file is already tracked and modified.

**How to apply:** commit tracked-but-ignored files in `~/.claude` with `git add -f <path>` by
name (e.g. `git add -f skills/apex-code/SKILL.md`). Still surgical — never `git add -A`/`-f .`.
Confirm a file is tracked first with `git ls-files <path>`.

Note: `~/apex` (the APEX docs/history repo, holding `SKILL-HISTORY.md`, `SKILLS.md`, `docs/`)
uses a normal gitignore — standard `git add` by name works there. The actual skill `.md` files
live only in `~/.claude/skills/` (not mirrored into `~/apex`).
