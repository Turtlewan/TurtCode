# Codex live observability log (every ▸codex dispatch)

Default ON for every `codex exec` coder dispatch — sequential AND parallel. It is the live window that
makes a long Codex build watchable instead of blind, at ~zero host-context cost. Proven on codex-cli
0.141.0 (Windows, 2026-06-25): `--json` + `-o` split cleanly.

## Recipe
Run the dispatch **backgrounded** (Bash `run_in_background`), splitting Codex's output two ways:

```
printf '%s' "<prompt>" | codex exec -p apex-coder --sandbox workspace-write -m gpt-5.5 \
  -c model_reasoning_effort="<effort>" \
  -C <repo-or-worktree> --json -o <scratch>/codex-<task>.final --color never \
  > docs/progress/codex-<task>.log 2>&1
```

- `-c model_reasoning_effort="<effort>"` → the spec's `coder_effort` frontmatter (`{low|medium|high|xhigh}`,
  default `medium`; ADR-030). Omit the flag when the spec is at `medium` to keep the default behaviour.
- `--json` → Codex's event stream (reasoning, every shell command it runs, and per-turn `usage` token
  counts) as JSONL to `docs/progress/codex-<task>.log`. **This is the live feed** — both the user's
  deep-inspection file and the host's pulse source (below). The `usage` events make the log a live
  Codex-cost/quota meter.
- `-o <…>.final` → only Codex's final message. **The host reads this** (small) on completion, plus the
  exit code and `git diff --stat`. Codex's own tokens are unchanged: the events already exist; `--json`
  only emits them.
- `--color never` keeps the JSONL clean for tailing/parsing.

## Progress pulses to chat — DEFAULT ON (the visibility fix)
Telling the user a log path is not visibility: a backgrounded Codex shows nothing in the chat (where the
user actually looks) until it exits, and a raw JSONL file they aren't tailing is unwatchable. So while a
backgrounded dispatch runs, **the host emits a one-line progress pulse to chat at each natural check-in**
(when you poll the background shell, and at most ~every 60–90s — never busy-loop):

1. Read only the **tail** of the background output (Bash `BashOutput` on the bg shell, or the last lines of
   `docs/progress/codex-<task>.log`) — never the whole log.
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
The log is a transient build artifact — remove `docs/progress/codex-<task>.log` at worktree/spec
teardown, or add `docs/progress/*.log` to the project `.gitignore` once. Never commit it.
