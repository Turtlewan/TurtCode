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
- Surgical scope: only the files listed above; `git status --porcelain -uall` must show no path outside them that was not already dirty when you started. (NOT `git diff --stat` — a file you CREATE is untracked, so it never appears there, and you may not `git add` it into view.)
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

The coder runs the recipe **inside its own isolated worktree** and iterates to green — that is what this clause instructs. It is not the authoritative pass, and it is not an adjudication. The **authoritative integrated verify** runs on the integration tree: the Engine executes the recipe and adjudicates pass/fail for eligible attended builds; HOST executes and adjudicates on the manual/AFK path (apex-code § Verify). Both cadences are required; neither replaces the other.

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

## Completion routing (Engine for eligible attended builds; HOST for manual recovery)

On the Engine path, the Engine consumes coder completions and owns deterministic retry, integration, and verify routing. HOST reads the Engine exit code plus durable `engine-state` status **and diagnosis**, not a coder's `done` as build success. If no state exists, use the console `Engine refused: <message>` as the diagnosis; fix the inputs/spec or take the attended HOST manual path.

| Engine exit | Meaning | HOST routing |
|---|---|---|
| `0` | build/hand-off complete; HOST close-out pending | Critic/Scribe/family gate/docs close-out against the integrated tip, then owner-approved commit and proof-gated `-Teardown <runId>` per apex-code Post-build |
| `1` | refused/parked/failed/partial/quota-paused; distinguish by status and diagnosis | diagnose; fix inputs/spec or seek owner disposition for manual recovery. Resume an unchanged spec with `-Resume <runId>`; an amended spec needs a new run after inspecting partial work and permitted `-Teardown <runId> -Discard` |
| `2` | `awaiting-review` | run Opus Critic on the integrated wave, then `-Resume <runId>` with bound `-ReviewVerdict clean\|reject`, `-ReviewDigest`, and external `-ReviewRecord` per apex-code Engine path; rejection parks for HOST manual fixes or amended-spec rerun |

On the manual/AFK path, HOST reads the coder exit code + final `.final` JSON and adjudicates:

| Signal | Meaning | HOST routing |
|---|---|---|
| `status: done` | complete | run the spec's authoritative integrated Verification Recipe on the diff (trust but verify) → check the task off |
| `status: done_with_concerns` | complete + flags | verify as above; copy `deviations` / `unresolved` into the decisions table |
| `status: blocked` (+ `blocker`) | **spec defect** | route through Forks (capture-at-halt). Never model-fallback — a spec defect survives the swap |
| non-zero exit / no valid `.final`, log tail shows a rate-limit / quota signature | **paused, not failed** | park the task + checkpoint In-Flight; owner choice: wait for quota reset (re-dispatch Codex) vs HOST-directed Claude fallback (Sonnet 5) |
| non-zero exit, any other signature | process failure | one re-dispatch; if it repeats, treat as verify-fail: HOST bumps effort through `xhigh`, then decides whether to re-dispatch at `max`/`ultra` with amended effort or take another manual route. Claude (Sonnet) fallback requires owner decision per SKILL.md § Fallback; no automatic model swap |
| verify recipe fails on a `done` diff | verify-fail | HOST bumps effort through `xhigh` (ADR-030); beyond that, HOST decides whether to re-dispatch at `max`/`ultra` with amended effort or take another manual route. Claude (Sonnet) fallback requires owner decision per SKILL.md § Fallback; no automatic model swap |

HOST owns manual re-dispatch, effort bump, Forks, and parking. The Engine accepts max/ultra task effort, but its automatic retry ladder stops at xhigh; beyond that ladder HOST decides between an amended-effort spec/new Engine run and attended manual recovery. Whole-spec Sonnet pins and owner-approved Sonnet quota fallback use the HOST manual path.
