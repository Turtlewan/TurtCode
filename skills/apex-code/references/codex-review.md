# Codex independent review recipe (ADR-026)

Loaded on demand when apex-code runs the family-aware cross-model review (§ Cross-model review). Codex
(`gpt-5.5`) is the **independent reviewer for DeepSeek-built code**; it is **advisory** — it never
blocks the pipeline and never edits code.

## Invocation (read-only, schema-enforced) — PROVEN on Windows 2026-06-22
From the repo root, after the build. **Pipe the prompt via stdin — never pass it as a positional arg**
(a bare-arg `codex exec` hangs in a non-interactive shell waiting on stdin):

```sh
printf '%s' "<review prompt below, placeholders filled>" | \
  codex exec --sandbox read-only \
    --output-schema ~/.claude/skills/apex-code/references/codex-review-schema.json \
    -o <out.json> -m gpt-5.5 -C <repo-root>
```
Then read `<out.json>` — the schema-constrained final message `{ findings[], verdict }`.

- `--sandbox read-only` → the reviewer cannot modify the tree (zero blast radius).
- `--output-schema <file>` → forces the final message into the findings schema. **Strict mode: every
  property must be in `required`; keep `line`/`criterion` nullable** (omitting them → HTTP 400). `-o <file>`
  writes that final message (cleaner than parsing `--json` JSONL).
- `-m gpt-5.5` → pin the model (Codex churns IDs — re-check after a Codex upgrade).
- Guard first: if `codex --version` fails, do **not** silently skip — apex-code records the flag
  (§ Cross-model review graceful-degrade).

## Review prompt (fill the placeholders)
> You are an independent code reviewer from a different model family than the author. Review ONLY the
> change below against its acceptance criteria. Do NOT propose rewrites — classify issues.
>
> Spec: `<spec_path>`
> Acceptance criteria:
> `<paste the spec's ## Acceptance Criteria>`
>
> Changed files (git diff):
> `<paste git diff for files_changed>`
>
> For each issue, output a finding `{severity: BLOCK|FLAG|CLEAN, file, line, criterion, rationale}`.
> BLOCK = an acceptance criterion is unmet, or a correctness/security defect. FLAG = a real concern,
> not a blocker. If the change is clean, return one CLEAN finding and `verdict: CLEAN`. Judge the code,
> not intent. Do not invent issues to seem thorough.

## Output contract
Schema returns `{ findings: [{severity, file, line?, criterion?, rationale}], verdict }`. apex-code
surfaces BLOCK/FLAG findings in the build report as **advisory cross-model findings** and combines them
with apex-reviewer per § Cross-model review (both-raise → high-confidence; one-raises → human-adjudicate).
Never feed apex-reviewer's findings into this prompt — the reviewer must stay independent.
