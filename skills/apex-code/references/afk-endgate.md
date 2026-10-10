# AFK end-of-run adversarial pass (ADR-033 A1, model per ADR-034)

Standing, mandatory end-of-run review for every unattended multi-task build. An **Opus** reviewer reads the
**WHOLE run diff** independently to find production bugs that green tests, lint, and typecheck structurally
miss. It is advisory-only: it never edits code or auto-fixes findings.

**Why Opus and not the coder's own family (ADR-034).** `gpt-6.1-sol` is the default coder. An end-gate run on
Sol would be Sol reviewing its own run — self-review reliably under-reports the reviewer's own failure modes,
which is exactly the class of bug an unattended gate exists to catch. The gate is therefore **cross-family**:
Codex builds, Claude reviews — the same rule the per-task reviewer already follows (ADR-032). Evaluator-
independence is a dispatch invariant, not a preference.

## Invocation (read-only, host-dispatched)
From the repo root, after the complete run, dispatch **one fresh `apex-critic` through the Agent tool** with
`mode: code` and Agent tool parameter `model: opus`. Pass `model: opus` on every dispatch; it overrides the
agent file's default frontmatter `model: sonnet`. Supply the run spec and the whole-run diff from
`git diff <run_base_sha>..HEAD` — **not** one task's diff.

This dispatch is the single whole-build round 1, a fresh full review of the complete code-review sequence. Do
not launch another full review at build end. The pass is an independent read,
so give it the run spec + whole-run diff and nothing else. **Never** give it earlier Critic findings or a coder
summary. If fixes are made, use the normal fix-check rounds 2–3 under the normal review cap: each dispatch uses
`apex-critic`, `mode: code`, and Agent tool parameter `model: opus`, and receives the prior round's findings file
plus the current full whole-run diff. A fix check checks prior findings and defects in text touched by fixes; it
does not re-audit unchanged text or become a second fresh whole-build review.

This is a Claude Agent dispatch, not the wrapper's separate Codex endgate mode. Enforce the return contract in
the prompt and reject and re-ask once if the agent returns anything else. `afk-endgate-schema.json` remains
owned by the wrapper's Codex endgate mode; it does not declare the Claude agent's contract.

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
> This is round 1: perform a fresh full adversarial read. For each issue, use severity `block`, `flag`, or
> `note`; include its class, file, line, evidence, and concise summary. Do not invent findings to seem
> thorough. `status` is the worst finding severity. Note-only or empty findings use `status: clean`, so
> `clean` may still carry `note` findings.
>
> Return ONLY this JSON object, no prose before or after:
> `{ "status": "clean|flag|block", "findings": [{"severity": "block|flag|note", "class": "...", "file": "...", "line": 0, "evidence": "...", "summary": "..."}] }`

## Output contract
Returns `{ status, findings: [{severity, class, file, line, evidence, summary}] }`, where `status` is
`clean|flag|block` and finding severity is `block|flag|note`. Map findings into the existing handoff end-gate
table as follows:

| Critic severity | Handoff severity |
|---|---|
| `block` | P1 |
| `flag` | P2 |
| `note` | note |

`clean` yields no P1/P2 findings but may still carry mapped `note` findings. apex-code routes mapped P1
findings through its fix-and-reverify loop before handoff; mapped P2 and note findings go to morning human
triage. The Critic is advisory-only and never edits or auto-fixes anything.

## Cost
One fresh Opus whole-build pass per AFK *run* — not per task — followed only by fix checks when fixes are
made. It draws the shared Anthropic Max pool, which is the deliberate trade in ADR-034: the safety gate on
unattended work is where an Opus escalation is warranted.
