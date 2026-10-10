# Codex independent review recipe (ADR-026)

Loaded on demand when apex-code runs the family-aware cross-model review (apex-code § Post-build). Codex
(`gpt-6.1-sol`, the wrapper default) is the **independent reviewer for Claude-fallback-built code (Sonnet 5)** (ADR-027 —
Codex is the default *builder*, so this review path fires only on the Claude fallback — Sonnet 5, per
A1); it **never edits code**, and its *findings* are advisory — but its **verdict routes**: `BLOCK` →
exit 67, which is a HARD STOP on the pipeline (do not commit, do not build a dependent spec).
**The HOST receives, adjudicates, and routes a build-side review BLOCK on the manual path**; the HOST relays it to
the user only when the call needs human judgment. It is not auto-dismissable and not merely a suggestion.
The HOST owns the later Critic cadence against the integrated tip (apex-code § Post-build). At an Engine
high-risk `awaiting-review` pause, the HOST runs Opus Critic on the recorded integrated-wave diff and supplies
`-Resume <runId> -ReviewVerdict clean|reject -ReviewDigest <64 lowercase hex> -ReviewRecord <existing absolute path outside every Git worktree>`.
The Engine consumes only that HOST-supplied verdict bound to the recorded tree digest and review record;
`reject` parks the run. This cross-model `BLOCK` is not an Engine review verdict.
`FLAG` → exit 68, carried into the review. Note: the Claude fallback builds only via the three fallback triggers
(see model-routing), so this Codex review usually can't run either → apex-code degrades to
single-model + human flag. Codex-built work receives no additional Sol cross-family pass.

## Invocation — through the WRAPPER, always

A hand-rolled pipe into `codex exec` is **hard-blocked** by `hooks/codex-dispatch-guard.js` and will be
denied. That is deliberate: the raw path has no ledger, no watchdog, no `-Adopt`, and — the one that
matters most here — **it does not read the verdict.** Codex exits **0** even when its review returns
`"verdict": "BLOCK"`, so a hand-rolled review reports success on a blocking result. Two reviews of the
harness itself did exactly that before anyone noticed.

Write the prompt to a file, then:

```powershell
$pack = Get-Content -Raw <review-prompt.txt>
scripts/codex-dispatch.ps1 `
  -Spec <spec> -Task review -Phase review `
  -Worktree <repo-root> -BaseSha <sha> `
  -Schema review `
  -Effort high `
  -SkipScopeCheck `
  -Prompt $pack
```

The wrapper supplies the rest of what this recipe used to spell out by hand:

- **`-Sandbox read-only` is forced** for `-Phase review` / `-Schema review`. A reviewer that can edit
  the tree it is judging is not a reviewer — and the standing end-gate ran with repo write access for
  months despite a runbook promising it "never auto-edits anything".
- **`--output-schema` is selected from `-Schema`**, so the findings can't be silently dropped by a
  mismatched schema.
- **The tree is pinned** before the review and verified after; if it moved, the verdict is **VOID**
  (exit 69) rather than a stale opinion about a tree that no longer exists.
- **The verdict is routed**: `BLOCK` → exit 67, `FLAG` → exit 68, anything unrecognised → **fails
  closed**. Read the report at the `[dispatch] report:` path it prints.

- `-c approval_policy="never"` → in non-interactive `exec`, any other policy turns the first
  sandboxed-command failure into a halt-to-escalate that nobody can answer → the review stalls. `never`
  feeds failures back to the model so it finishes the review. (Coder path uses the `apex-coder` profile;
  the reviewer is read-only so it just needs this one override, not the profile.)
- `--sandbox read-only` → the reviewer cannot modify the tree (zero blast radius).
- `--output-schema <file>` → forces the final message into the findings schema. **Strict mode: every
  property must be in `required`; keep `line`/`criterion` nullable** (omitting them → HTTP 400). `-o <file>`
  writes that final message (cleaner than parsing `--json` JSONL).
- Model: the wrapper default is `gpt-6.1-sol`; an explicit `-Model` may pin another allowed model (Codex churns IDs — re-check after a Codex upgrade).
- Guard first: if `codex --version` fails, do **not** silently skip — apex-code records the flag
  (apex-code § Post-build).

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

Also apply the four silent-regression lenses (`references/silent-regression-lenses.md`, ADR-033 A2) to every diff under review.

## Output contract
Schema returns `{ findings: [{severity, file, line?, criterion?, rationale}], verdict }`. apex-code
surfaces BLOCK/FLAG findings in the build report as **advisory cross-model findings** and combines them
with `apex-critic` in `mode: code` (apex-code § Post-build) (both-raise → high-confidence; one-raises → human-adjudicate).
Never feed `apex-critic` code findings into this prompt — the reviewer must stay independent.
