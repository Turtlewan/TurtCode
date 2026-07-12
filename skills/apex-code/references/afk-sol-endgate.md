# AFK end-of-run Sol adversarial pass (ADR-033)

Standing, mandatory end-of-run review for every unattended multi-task build. `gpt-5.6-sol` reviews the
**WHOLE run diff** independently to find production bugs that green tests, lint, and typecheck structurally
miss. It is advisory-only: it never edits code or auto-fixes findings.

## Invocation (read-only, schema-enforced)
From the repo root, after the complete run. Build the input from `git diff <run_base_sha>..HEAD` -- **not**
one task's diff. **Pipe the prompt via stdin -- never pass it as a positional arg** (a bare-arg `codex exec`
hangs in a non-interactive shell waiting on stdin):

```sh
printf '%s' "<adversarial prompt below, placeholders filled; include git diff <run_base_sha>..HEAD>" | \
  codex exec -c approval_policy="never" --sandbox read-only \
    --output-schema ~/.claude/skills/apex-code/references/afk-sol-endgate-schema.json \
    -o <out.json> -m gpt-5.6-sol -c model_reasoning_effort=max -C <repo-root>
```
Then read `<out.json>` -- the schema-constrained final message `{ findings[], verdict }`.

- `-c approval_policy="never"` keeps an unattended read-only review from halting to request an approval.
- `--sandbox read-only` means the pass has zero write blast radius: findings are advisory only.
- `--output-schema <file>` forces the final message into the findings schema. **Strict mode: every property
  must be in `required`** (omitting one causes structured-output HTTP 400). `-o <file>` writes the final
  message cleanly for the host to read.
- `-m gpt-5.6-sol -c model_reasoning_effort=max` pins the standing adversarial reviewer and maximum effort.

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

## Output contract
Schema returns `{ findings: [{severity, issue, file, why}], verdict }`. apex-code routes P1 findings through
its own fix-and-reverify loop (including the specific task/verify recipe) before it writes the handoff. P2
and `note` findings pass through unchanged into the handoff's Sol-pass findings table for morning human
triage; the sibling `afk-sol-endgate` handoff specification defines that table. This pass never auto-edits or
auto-fixes anything.
