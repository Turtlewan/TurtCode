# Codex live observability log (every ▸codex dispatch)

Default ON for every `codex exec` coder dispatch — sequential AND parallel. It is the live window that
makes a long Codex build watchable instead of blind, at ~zero host-context cost. Proven on codex-cli
0.141.0 (Windows, 2026-06-25): `--json` + `-o` split cleanly.

## Recipe
Run the dispatch **backgrounded** (Bash `run_in_background`), splitting Codex's output two ways:

```
printf '%s' "<prompt>" | codex exec -p apex-coder --sandbox workspace-write -m gpt-5.5 \
  -C <repo-or-worktree> --json -o <scratch>/codex-<task>.final --color never \
  > docs/progress/codex-<task>.log 2>&1
```

- `--json` → Codex's event stream (reasoning, every shell command it runs, and per-turn `usage` token
  counts) as JSONL to `docs/progress/codex-<task>.log`. **This is the live feed.** The host tells the
  user the path; they `tail -f` it — or open it in Cursor (in-workspace, Ctrl+P-findable) — and watch
  the build as it happens. The `usage` events also make the log a live Codex-cost meter.
- `-o <…>.final` → only Codex's final message. **The host reads this** (small) on completion, plus the
  exit code and `git diff --stat` — it does NOT read the verbose log, so observability adds ~zero host
  tokens. Codex's own tokens are unchanged: the events already exist; `--json` only emits them.
- `--color never` keeps the JSONL clean for tailing/parsing.

## Why backgrounded (not foreground)
A foreground blocking `codex exec` returns nothing until it exits — that is the "I'm blind" failure, and
it is equally blind whether a design labels it foreground or background. Backgrounding + the log is what
actually surfaces progress. The host waits for the completion notification, then reads `.final`. This is
also why the ADR-029 supervision gate's foreground specs were never truly "watched" — the log fixes that
for every spec; the gate's real reason is host *supervision/intervention*, not raw visibility.

## Teardown
The log is a transient build artifact — remove `docs/progress/codex-<task>.log` at worktree/spec
teardown, or add `docs/progress/*.log` to the project `.gitignore` once. Never commit it.
