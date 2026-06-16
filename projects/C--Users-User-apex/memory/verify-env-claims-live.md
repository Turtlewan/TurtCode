---
name: verify-env-claims-live
description: "Never assert \"you can't run X here\" / capability or environment limits from memory or status notes — verify against live env, settings, and hooks first."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1c86294c-153f-4281-98b3-6a925b98013f
---

Before asserting any **environment or capability limit** ("this is Mac-gated", "Windows is
planning-only", "you can't run X here"), **verify against the live machine** — env vars
(`env | grep -i ANTHROPIC|DEEPSEEK`), `~/.claude/settings*.json`, the project `.claude/`, and the
SessionStart/backend hooks. Stale `docs/status.md` notes and `project` memories are **leads, not
facts** — they are point-in-time and propagate by pattern-match.

**Why:** On 2026-06-15 I told the user a backlog of items was "Mac-gated" and unrunnable on Windows,
reciting the [[project-deployment]] memory + old status.md tags. A live check found `DEEPSEEK_API_KEY`
set on Windows and a documented env-var-swap to the **cloud** DeepSeek coding backend — most items
were runnable here all along. The error wasn't model capability; it was trusting written context over
verifying. The user (correctly) read it as a regression and asked for a thorough check instead.

**How to apply:**
- Treat CLAUDE.md §1 (don't assume; verify) as binding for environment/capability claims specifically.
- Distinguish **policy** ("we choose to build on the Mac") from **capability** ("Windows can't build") —
  never state the former as the latter.
- Keep the two-gate split sharp: `coding-session` (needs DeepSeek session, runs on Windows) vs
  `mac-gated` (needs macOS tooling). See [[project-deployment]].
- When a memory/status note drives a user-facing "can't", spend one tool call confirming it live before
  you say it.
