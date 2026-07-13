# Codex dispatch pack (every ▸codex coder dispatch — ADR-031)

The prompt piped to `codex exec` is never bare task text. Assemble this four-slot pack per task —
it is how the enforcement layer reaches the coder: the impl cores load in the *host*, so the
task-relevant rules must travel in the pack. **Read this file once per build** (like
`references/permissions.md`) and reuse it for every dispatch that session — never re-read per task.

## Pack template

```
## Goal
<task text verbatim>
Done when: <the task's done-when clause>

## Context
- Spec: <identity line>. Intent: <the spec's ## Intent block verbatim, if present>
- Repo: <repo-relative pointers the task needs — module paths, the pattern-file to mirror>
- Files for this task (authorized set — touch nothing else): <list>
- Resolved decisions: <versions, lib choices, policy values from the spec — state them;
  never "adapt to the bound stack">

## Constraints
- Surgical scope: only the files listed above; `git diff --stat` must show only those.
- <3–7 task-relevant hazards — selection rule below>
- <autonomy clause verbatim — below>

## Done-when
- Acceptance criterion: <verbatim from the spec>
- Verify: run <exact recipe commands for this task> — all green.
- Final message: JSON per the completion contract (--output-schema): status, changed_files,
  commands_run (+results), deviations, unresolved, blocker.
```

## Hazard selection (the Constraints slot)

- Source: the loaded impl cores (apex-coding-principles + bound stack NEVER/ALWAYS) + the spec's
  Specialist Context.
- Pick **3–7 this task can actually violate** (a DB task gets the schema hazards, not the a11y
  rules). Never paste a whole NEVER/ALWAYS list.
- Skip generic hygiene entirely (validation, HTTP codes, naming-in-general, DRY,
  no-silent-errors) — native to GPT-5.6; injecting it degrades output via instruction competition.
- Phrase positively; check the assembled pack for internal consistency before dispatch
  (contradictions burn GPT-5 reasoning) — rewrite conflicts, never stack them.

## Autonomy clause (verbatim — closes the Constraints slot)

"Follow AGENTS.md. Surgical scope — touch only the listed files. Work autonomously to
completion: run the verify recipe, and if a test fails / lint errors / you hit a problem, fix it
and re-run — do not stop to ask. Only end when the acceptance criterion passes, or you are
genuinely blocked — then say exactly what blocked you. Safe local choice (make it, log it in
deviations): which existing pattern to mirror, a local name. Blocker (report in `blocker`, don't
improvise): an acceptance criterion that cannot pass as written, a needed file outside the
authorized set, a missing credential."

## Completion routing (host reads exit code + `.final` JSON)

| Signal | Meaning | Host action |
|---|---|---|
| `status: done` | complete | run the spec's Verification Recipe on the diff (trust but verify) → check the task off |
| `status: done_with_concerns` | complete + flags | verify as above; copy `deviations` / `unresolved` into the decisions table |
| `status: blocked` (+ `blocker`) | **spec defect** | route through Forks (capture-at-halt). Never model-fallback — a spec defect survives the swap |
| non-zero exit / no valid `.final`, log tail shows a rate-limit / quota signature | **paused, not failed** | park the task + checkpoint In-Flight; operator choice: wait for quota reset (re-dispatch Codex) vs Opus fallback now |
| non-zero exit, any other signature | process failure | one re-dispatch; if it repeats, treat as verify-fail (effort ladder → fallback) |
| verify recipe fails on a `done` diff | verify-fail | effort-bump ladder (ADR-030) → `ultra` rung (ADR-034) → Opus fallback per SKILL.md § Model fallback |
