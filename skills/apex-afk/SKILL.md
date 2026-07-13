---
name: apex-afk
skill: apex-afk
backend: coding
version: 1.0.1
description: >
  Use for an explicitly human-armed unattended coding run. Triggers: "afk mode",
  "run afk", "afk off", "run overnight", "run unattended". Not for planning,
  ordinary interactive builds, or agent-initiated permission escalation.
---

# APEX AFK

## Arming

- Require the human to run `afk` in their terminal before treating this session as armed.
- Never arm, simulate arming, or direct a tool to perform the human terminal action.
- Until the gate recognizes a valid armed state, use normal permissions and autonomy.

## Engage behavior

Once armed:

1. Confirm coding mode and autonomy L4.
2. Drain the ready build queue using `apex-code` AFK Build Mode.
3. Follow each build's declared scope, verification recipe, and normal handoff process.

The end-of-run adversarial review pass (A1) belongs to the sibling
`apex-code/references/afk-endgate.md`; it is not part of this skill.

## Disengage

- If the human types `afk off` in chat, the gate returns an `ask` decision on the
  next tool-layer attempt involving the flag; the human approves that prompt.
- Alternatively, the human may delete `afk.on` directly in a terminal. This is an
  immediate kill-switch.
- After disengagement, write the normal handoff and resume normal permission behavior.

## Safety invariants

- The destructive never-list, exfiltration, and remote-code-execution actions remain
  denied while armed.
- Writes to critical files—environment files, migrations, authentication code, CI
  configuration, package manifests, and credential dotfiles—fall through to the
  normal `ask` gate; never auto-allow them.
- The armed state has an `expires=` ceiling and self-expires.
- Deleting `afk.on` from any terminal is an instant kill-switch.
- Any Write, Edit, or Bash attempt to touch `afk.on` must receive an approval prompt;
  no tool-layer channel can silently self-trigger arming.
