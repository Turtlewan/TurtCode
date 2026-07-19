---
name: dontask-probe-cleanup-paradox
description: "dontAsk probe/build sessions can't self-clean — settings/spec-move edits aren't allow-listed; arrange cleanup outside dontAsk"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3947f62e-5a49-4a20-bd13-bcf3493cc724
---

A coding/probe session launched with `--permission-mode dontAsk` **cannot clean up after itself**: `settings.local.json` edits, moving a spec to `done/`, and any non-allow-listed write are auto-denied (correct — dontAsk runs only `permissions.allow` + read-only Bash). A probe allowlist scoped to `docs/probes/**` therefore cannot touch `.claude/settings.local.json` to remove its own scaffolding (e.g. a `Bash(rm *)` deny that then blocks every later session, planning included).

**Why:** dontAsk's security model has no prompt/escalation path — off-list = silent deny — so the running agent is structurally unable to undo its own setup.

**How to apply:** design post-probe cleanup as a pre/post-session concern, never as a step the dontAsk agent performs. Either (a) do cleanup before entering dontAsk, (b) pre-arrange a cleanup script, (c) explicitly allow-list the settings path, or (d) leave it as an explicit blocked-action for the next planning session to drain. Future probe specs should carry a cleanup-ownership line. Related: [[classifier-gates-protected-path-edits]].
