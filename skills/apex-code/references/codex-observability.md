# Codex live observability log (every ▸codex dispatch)

Default ON for every `codex exec` coder dispatch — sequential AND parallel. It is the live window that
makes a long Codex build watchable instead of blind, at ~zero host-context cost. Proven on codex-cli
0.141.0 (Windows, 2026-06-25): `--json` + `-o` split cleanly.

## Recipe
Run the dispatch **backgrounded** (Bash `run_in_background`), splitting Codex's output two ways:

```
printf '%s' "<dispatch pack>" | codex exec -p apex-coder --sandbox workspace-write -m gpt-5.6-sol \
  -c model_reasoning_effort="<effort>" \
  -C <repo-or-worktree> --json \
  --output-schema ~/.claude/skills/apex-code/references/codex-completion-schema.json \
  -o <scratch>/codex-<task>.final --color never \
  > <ledgerDir>/codex-logs/codex-<spec>-<task>-<worktreeTag>-<runId8>.log 2>&1
```

The log lives **outside the target repo**, beside the ledger — `<ledgerDirectory>\codex-logs\`, i.e.
`%LOCALAPPDATA%\apex\progress\codex-logs\` (or `%APEX_STATE_DIR%\progress\codex-logs\`). The wrapper
moved it out of the tree because the harness must not write into the tree it is judging (a log inside
`docs/progress/` read as an unauthorized write and failed every clean build). Never write it into the
worktree.

- `-c model_reasoning_effort="<effort>"` → the spec's `coder_effort` frontmatter (`{low|medium|high|xhigh|max|ultra}`,
  default `medium`; ADR-030). Omit the flag when the spec is at `medium` to keep the default behaviour.

## Effort ladder — max / ultra (ADR-030, codex-cli 0.144.1+, gpt-5.6 family)

`-c model_reasoning_effort` accepts `low|medium|high|xhigh|max|ultra` on gpt-5.6-family models (both
`max` and `ultra` are server-validated-accepted; a bogus value is rejected). Semantics above `xhigh`:

- **`max`** — reserve for the hardest *single* tasks: state migrations, IAM/auth-critical work, gnarly
  concurrency. The second-highest rung of the verify-fail recovery ladder (`medium→high→xhigh→max`).
- **`ultra`** — the **final** rung of the verify-fail ladder, above `max` (ADR-034). Reached only when
  `max` has already failed verification; then the Opus fallback (quota-out cases skip straight to Opus —
  the Codex pool is dead — see § Model-routing dispatch in SKILL.md).
  `ultra` spawns in-model subagents, so token usage multiplies — codex 0.144 warns about concurrency at
  ultra effort. Because of that multiplier, an `ultra` task counts **double** against `max_parallel_codex`
  (ADR-028) — or run `ultra` tasks sequential/foreground instead of folding them into a parallel wave.
  **Never a default `coder_effort`, and never reached except as that last automatic rung** — a spec that
  *starts* a task at `ultra` is a deliberate, logged escalation, not routine. Its worth against `max` is
  still gated on a head-to-head eval that has not yet run: ADR-034 promoted it on structural grounds (it is
  the only rung between `max` and the scarce Opus pool), so if the eval disappoints, cut this rung first.

The old Sol model rung (ADR-032) is **gone**: `gpt-5.6-sol` *is* the coder now (ADR-034), so there is no
higher Codex model to escalate to — the dial is the whole ladder.
- `--json` → Codex's event stream (reasoning, every shell command it runs, and per-turn `usage` token
  counts) as JSONL to the external `codex-logs\` log (path above). **This is the live feed** — both the user's
  deep-inspection file and the host's pulse source (below). The `usage` events make the log a live
  Codex-cost/quota meter.
- `-o <…>.final` → the schema-constrained completion JSON (ADR-031: status / changed_files /
  commands_run / deviations / unresolved / blocker). **The host reads this** (small) on completion,
  plus the exit code and `git diff --stat`, and routes `status` per
  `references/dispatch-pack.md` § Completion routing. Codex's own tokens are unchanged: the events
  already exist; `--json` only emits them.
- `--color never` keeps the JSONL clean for tailing/parsing.

## Progress pulses to chat — DEFAULT ON (the visibility fix)
Telling the user a log path is not visibility: a backgrounded Codex shows nothing in the chat (where the
user actually looks) until it exits, and a raw JSONL file they aren't tailing is unwatchable. So while a
backgrounded dispatch runs, **the host emits a one-line progress pulse to chat at each natural check-in**
(when you poll the background shell, and at most ~every 60–90s — never busy-loop):

1. Read only the **tail** of the background output (Bash `BashOutput` on the bg shell, or the last lines of
   the external `codex-logs\` log, `%LOCALAPPDATA%\apex\progress\codex-logs\codex-<spec>-<task>-<worktreeTag>-<runId8>.log`
   — or `%APEX_STATE_DIR%\progress\codex-logs\...`) — never the whole log.
2. Extract three things from the newest events: the latest shell command / file Codex touched, the latest
   test/verify result if any, and the most recent `usage` total.
3. Emit **one line**, then discard the read — do not keep log text in context:
   `⟳ codex[<task>] · <latest action> · <verify state> · ~<N>k tok`
   e.g. `⟳ codex[auth-session] · editing session.ts · pytest 8✓ 1✗ refixing · ~34k tok`

Token cost is bounded by design: tail-in, one-line-out, discard. This deliberately spends a small host
budget that the original zero-token, user-tails-the-file design withheld — and that withholding is why
"I still can't see anything" was the real failure mode. The full JSONL log remains for deep inspection
(open in Cursor, Ctrl+P-findable). On parallel dispatch (ADR-028/029), pulse per running subprocess,
prefixed by task, so concurrent builds stay legible.

## Why backgrounded (not foreground)
A foreground blocking `codex exec` returns nothing until it exits — that is the "I'm blind" failure, and
it is equally blind whether a design labels it foreground or background. Backgrounding + the log is what
actually surfaces progress. The host waits for the completion notification, then reads `.final`. This is
also why the ADR-029 supervision gate's foreground specs were never truly "watched" — the log fixes that
for every spec; the gate's real reason is host *supervision/intervention*, not raw visibility.

## Teardown
The log is a transient build artifact living in the external state dir (`<ledgerDirectory>\codex-logs\`),
not in the repo — so it never needs `.gitignore` and can never be committed. Prune old
`codex-logs\*.log` files at worktree/spec teardown.

## Durable dispatcher (ADR-033 A4)

For AFK/unattended builds, `scripts/codex-dispatch.ps1` replaces the raw `codex exec` invocation
above — same flags, same dispatch pack, same `--json` log and `-o` `.final` schema output — but
adds three things a long unattended run needs that a one-shot foreground/backgrounded call does
not: a guaranteed stdin close, a durable run record, and crash recovery.

**Why:** ad-hoc `codex exec` launches without an explicit stdin-close can wedge for 40+ minutes
waiting on an inherited stdin in some launch paths — a real recurring incident this wrapper exists
to make structurally impossible, not just documented against.

**Params:** `-Spec -Task -Worktree -BaseSha -Phase -Prompt [-SpecSourcePath <abs>] [-Effort medium] [-NoOutputTimeoutMin 8]
[-Adopt]`. `-Prompt` is the assembled dispatch pack text (same four-slot pack as any `▸codex`
dispatch — `references/dispatch-pack.md`).

**Mechanics:**
- Launches Codex via `System.Diagnostics.Process` (not `Start-Process`), writes the dispatch pack
  to the child's redirected stdin, then **immediately closes it** — this is the load-bearing fix.
- Appends a row to the external ledger `<ledgerDirectory>\codex-run-ledger.jsonl` =
  `%LOCALAPPDATA%\apex\progress\codex-run-ledger.jsonl` (JSONL, one object per line) **before**
  launch: `{run_id, pid, worktree, spec, task, base_sha, phase, started, log_path, status:
  "running"}`. On exit, the same row is rewritten in place (temp-file + atomic replace, mutex-
  serialized across concurrent wrappers) with `status: "done"|"failed"` + `ended`.
- **Watchdog:** polls the `--json` log's last-write time every ~15s. No new bytes for
  `-NoOutputTimeoutMin` minutes (default 8) → the ledger row flips to `status: "stalled"` and the
  wrapper exits `124`. It does **not** kill the child process — process ownership stays with the
  caller, who decides whether to terminate a stalled run.
- **`-Adopt -Spec <X> -Phase <Y>`:** reads the ledger, finds the newest row matching that spec+phase,
  prints its `worktree` and `git -C <worktree> diff <base_sha>..HEAD` — recovers an orphaned run's
  work after a session crash without re-dispatching.
- Windows npm-shim note: `codex` resolves to a `.ps1`/`.cmd` shim that `UseShellExecute=$false`
  cannot execute directly; the wrapper resolves the real `node.exe` + `codex.js` entry point and
  invokes that instead.
- The ledger is runtime state, not source — do not hand-edit it; the external
  `<ledgerDirectory>\codex-logs\` already holds the per-task `--json` logs the ledger's `log_path`
  field points at.
