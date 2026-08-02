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
- Scratch: if you need a scratch directory, create `.codex-scratch/` at the repo root and nowhere else — it is the only sanctioned name. `.scratch`, `.apex-tmp` and `.sandbox-cache` are DEPRECATED: they are still excluded from the scope check on existing repos, so they raise no violation, but they may lose that exclusion in a future revision — do not use them for new work. Any other invented or task-suffixed variant (`.codex-scratch-task2`) IS reported as an out-of-scope write. If this repo does not gitignore `.codex-scratch/`, it will flag as a scope violation — report that, and do NOT add gitignore entries yourself.
- <3–7 task-relevant hazards — selection rule below>
- <autonomy clause verbatim — below>

## Done-when
- Acceptance criterion: <verbatim from the spec>
- Verify: run <exact recipe commands for this task> — all green.
- Final message: JSON per the completion contract (--output-schema): status, changed_files,
  commands_run (+results), deviations, unresolved, blocker.
```

## Hazard selection (the Constraints slot)

- Source: the loaded `apex-coding-principles/impl.md` core NEVER/ALWAYS (there are no bound stack
  skills — ADR-036) + the spec's Specialist Context.
- Pick **3–7 this task can actually violate** (a DB task gets the schema hazards, not the a11y
  rules). Never paste a whole NEVER/ALWAYS list.
- Skip generic hygiene entirely (validation, HTTP codes, naming-in-general, DRY,
  no-silent-errors) — native to GPT-5.6; injecting it degrades output via instruction competition.
- Phrase positively; check the assembled pack for internal consistency before dispatch
  (contradictions burn GPT-5 reasoning) — rewrite conflicts, never stack them.

## Scratch directory (the Constraints slot)

There is exactly one sanctioned scratch directory name: `.codex-scratch/`, anchored at the repo
root. It is the only scratch location a coder may create. For noise reduction on existing repos,
`codex-scope-check.ps1` additionally excludes three DEPRECATED names (`.scratch`, `.apex-tmp`,
`.sandbox-cache`) and three tool caches (`.pytest_cache`, `.mypy_cache`, `.ruff_cache`). Those
names raise no violation today, may lose the exclusion in a future revision, and are not for new
work. See the script for the exclusion mechanism and its guards.

The exclusion depends on the target repo already ignoring the name. Coders never add gitignore
entries themselves; if the repo does not already gitignore `.codex-scratch/`, report the resulting
scope violation. Repo seeding is a wave-2 item.

## Autonomy clause (verbatim — closes the Constraints slot)

"Follow AGENTS.md. Surgical scope — touch only the listed files. Work autonomously to
completion: run the verify recipe, and if a test fails / lint errors / you hit a problem, fix it
and re-run — do not stop to ask. Only end when the acceptance criterion passes, or you are
genuinely blocked — then say exactly what blocked you. Safe local choice (make it, log it in
deviations): which existing pattern to mirror, a local name. Blocker (report in `blocker`, don't
improvise): an acceptance criterion that cannot pass as written, a needed file outside the
authorized set, a missing credential."

The coder runs the recipe **inside its own worktree** and iterates to green — that is what this clause instructs. It is not the authoritative pass, and it is not an adjudication. On the integration tree the ownership is split (ADR-046 D1; apex-code § Verify). The host EXECUTES the recipe as mechanics from the orchestrator's wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows. Both cadences are required; neither replaces the other.

## Reading the completion — the LAST agent_message, never any other

**`--output-schema` forces EVERY agent message into the completion shape, so Codex uses that shape
for narration.** A real run emits several. Only the last one is a completion report; every earlier
one is a thought.

From the live `cap-deps-1a` run (2026-07-14) — nine of them, in order:

```
0. status=done                changed_files=[]     <- "I'm about to start reading the spec"
1. status=done                changed_files=[]
2. status=done_with_concerns  changed_files=6
3. status=done                changed_files=6
4. status=done                changed_files=6
...
8. status=done_with_concerns  changed_files=6      <- THE ONLY REAL ONE
```

**Two ways to be silently wrong:**
- Take the **first** match → `done` with **zero** changed files. Reads as a clean no-op success. The
  task is checked off having apparently done nothing, and nobody looks again.
- Take **any `status: done`** → messages 3–5 and 7 qualify, look complete, carry the right six files
  — and **silently drop the concerns.** The deviations vanish. This is the worse one, because the
  output looks correct.

**The rule:** read `<scratch>/codex-<spec>-<task>.final` (what `-o` captures — it is the final
message by construction). If you are reading the **log** instead — a progress pulse, a tail, any
regex over `"status":` — you must take the **last** `agent_message` and discard the rest. Never the
first match, never "the first `done`".

## Completion routing (orchestrator-owned; the host reads the exit code + `.final` JSON and reports them)

| Signal | Meaning | Orchestrator routing |
|---|---|---|
| `status: done` | complete | run the spec's Verification Recipe on the diff (trust but verify) → check the task off |
| `status: done_with_concerns` | complete + flags | verify as above; copy `deviations` / `unresolved` into the decisions table |
| `status: blocked` (+ `blocker`) | **spec defect** | route through Forks (capture-at-halt). Never model-fallback — a spec defect survives the swap |
| non-zero exit / no valid `.final`, log tail shows a rate-limit / quota signature | **paused, not failed** | park the task + checkpoint In-Flight; operator choice: wait for quota reset (re-dispatch Codex) vs Claude fallback (Sonnet 5) now |
| non-zero exit, any other signature | process failure | one re-dispatch; if it repeats, treat as verify-fail (effort ladder → fallback) |
| verify recipe fails on a `done` diff | verify-fail | effort-bump ladder (ADR-030) → `ultra` rung (ADR-034) → Claude fallback (Sonnet 5) per SKILL.md § Fallback |

The host reads the signal and hands it up; **which rung fires — re-dispatch, effort bump, fork, park — is the orchestrator's call**, not the host's (ADR-046 D1). **V1:** on an ATTENDED build the orchestrator is the dispatched `apex-build-orchestrator` agent and the host relays the signal and executes the rung it names; on an UNATTENDED build the host performs that routing itself until v2 (ADR-046 D1).
