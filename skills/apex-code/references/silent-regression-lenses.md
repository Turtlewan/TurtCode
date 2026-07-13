# Silent-regression review lenses (ADR-033 A2)

A2 is a fixed checklist applied at every Codex-diff integration/review, independent of host vigilance. It complements A1's fresh adversarial read in `afk-endgate.md`, but is not a model call.

1. **Await-before-first-yield in an SSE/async generator** — Detect: an async generator `await`s before its first `yield`. Why: live streaming can silently delay or break because the consumer waits for the first chunk; buffered/non-streaming tests only assert eventual output, not timing.

2. **Unshielded `create_task` + `await`** — Detect: `asyncio.create_task(...)` (or runtime equivalent) is immediately followed by `await` of that task without `asyncio.shield()` (or equivalent). Why: outer-context cancellation reaches the supposedly detached task; tests that never cancel the outer context miss it.

3. **Provider/adapter return types that drop safety metadata** — Detect: an adapter narrows or reshapes a provider response; verify metadata used by downstream safety mechanisms survives, not merely that the declared return type seems reasonable. Why: missing rate-limit, content-safety, or usage metadata can make a safety check a no-op or wrong default without exercising that path in tests.

4. **Optimistic re-entry guards registered after the first await** — Detect: a concurrent re-entry flag, lock, or mutex is set after an `await`, rather than synchronously on entry before yielding to the event loop. Why: a second call can enter through that race window; an optimistic guard works only when registered before the first yield point.

## How this is applied

At integration time, when apex-reviewer or the Codex cross-model review examines a diff, explicitly check these four patterns in addition to the rest of the review; flag every match as a finding.
