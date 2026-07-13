# AFK end-of-run adversarial pass (ADR-033 A1, model per ADR-034)

Standing, mandatory end-of-run review for every unattended multi-task build. An **Opus** reviewer reads the
**WHOLE run diff** independently to find production bugs that green tests, lint, and typecheck structurally
miss. It is advisory-only: it never edits code or auto-fixes findings.

**Why Opus and not the coder's own family (ADR-034).** `gpt-5.6-sol` is the default coder. An end-gate run on
Sol would be Sol reviewing its own run — self-review reliably under-reports the reviewer's own failure modes,
which is exactly the class of bug an unattended gate exists to catch. The gate is therefore **cross-family**:
Codex builds, Claude reviews — the same rule the per-task reviewer already follows (ADR-032). Evaluator-
independence is a dispatch invariant, not a preference.

## Invocation (read-only, host-dispatched)
From the repo root, after the complete run. Dispatch **one fresh `model: opus` subagent** from the host with
read-only tools (`Read`, `Glob`, `Grep`, and `Bash` for `git diff` only — never `Edit`/`Write`). Build its
input from `git diff <run_base_sha>..HEAD` — **not** one task's diff.

This is a Claude subagent, not a `codex exec` subprocess: there is no `--output-schema` flag, so the return
contract is enforced by the prompt. The reviewer must return **only** the JSON object in § Output contract —
no prose around it. Reject and re-ask once if it returns anything else.

The pass is a fresh context: give it the run spec + the whole-run diff and nothing else. **Never** give it
apex-reviewer's findings or the coder's own summary — that contaminates an independent read.

## Adversarial prompt (fill the placeholders)
> You are an independent adversarial reviewer of an UNATTENDED multi-task build. Review the WHOLE run
> change below, not each task in isolation. Identify real production risks that tests, lint, and typecheck
> can pass while structurally failing to catch. Do NOT edit code, propose rewrites, or auto-fix anything --
> classify findings only.
>
> Run context/spec:
> `<paste the applicable run specification and task intent>`
>
> Whole-run changed files (git diff `<run_base_sha>..HEAD`):
> `<paste git diff <run_base_sha>..HEAD>`
>
> Trace interactions between tasks across the complete build. Focus specifically on:
> - temporal/async behavior: races, lifecycle mistakes, timing or ordering assumptions that tests satisfy
>   but production does not;
> - source-to-sink data provenance: values silently flowing from an untrusted or wrong source to a sensitive
>   sink without appropriate validation; and
> - program-intent regressions: behavior that technically passes tests yet subtly differs from what the
>   specification asked for -- drift a human skimming the whole diff would catch.
>
> For each issue, output `{severity: P1|P2|note, issue, file, why}`. P1 = a real production bug that must
> be fixed before handoff. P2 = a real concern worth flagging for morning triage but not build-blocking.
> note = worth mentioning but not actionable. Do not invent findings to seem thorough. If there are no
> findings, return an empty `findings` array and a short overall `verdict`.
>
> Return ONLY this JSON object, no prose before or after:
> `{ "findings": [{"severity": "...", "issue": "...", "file": "...", "why": "..."}], "verdict": "..." }`

## Output contract
Returns `{ findings: [{severity, issue, file, why}], verdict }` (shape also declared in
`afk-endgate-schema.json`). apex-code routes P1 findings through its own fix-and-reverify loop (including the
specific task/verify recipe) before it writes the handoff. P2 and `note` findings pass through unchanged into
the handoff's end-gate findings table for morning human triage. This pass never auto-edits or auto-fixes
anything.

## Cost
One Opus pass per AFK *run* — not per task. It draws the shared Anthropic Max pool, which is the deliberate
trade in ADR-034: the safety gate on unattended work is where an Opus escalation is warranted.
