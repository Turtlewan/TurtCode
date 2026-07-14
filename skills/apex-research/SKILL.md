---
skill: apex-research
backend: claude
version: 2.0.0
last_updated: 2026-07-14
sources:
  - docs/technical/adr/ADR-015-dispatch-return-contract.md
  - docs/technical/adr/ADR-023-pre-authorise-before-dispatch.md
staleness_threshold: 30d
description: >
  Use when researching before a decision — comparing tools or options, verifying current best
  practice, or studying an external repo/system to absorb. Triggers: "research X", "compare A vs B",
  "is this still current", "study repo Y", an absorption pass. Not the decision or spec itself
  (apex-plan), and not an uncertain-approach deep dive (apex-deep-dive).
---

# Research

## First: should you research at all?

Research is for decisions that are **contested, consequential, and hard to reverse** — all three.
Otherwise decide, and write down what would make you revisit.

Skip it when: the decision is cheap to undo · one option is already load-bearing in the stack
(existing Terraform state → OpenTofu; decide in ten minutes) · the cost of research exceeds the
spread between the options · **no discoverable fact would change the answer.**

The most valuable research output is often *"don't."*

## The three-phase model contract — hard rule

| Phase | Who | Why |
|---|---|---|
| **1. Plan** | you, in-context (Opus) | frame the decision, derive falsifiable questions, name the sources |
| **2. Retrieve** | **dispatched cheap agents** (Sonnet/Haiku), in parallel | high-token, low-judgment, embarrassingly parallel |
| **3. Synthesise** | you, in-context | cross-source contradiction, weighting, the recommendation |

**The expensive model never does mechanical retrieval.** The split is drawn at **judgment vs
fetching**, not at hard vs easy. At ~30× the per-token cost, eight cheap retrievers cost less than
one expensive model reading the same pages, and the quality delta on *copying a quote* is ~zero.
Spend the premium only where reasoning depth changes the output.

## The return contract (ADR-015)

A retrieval agent returns **the conclusion, not its context**. Five fetched pages are 30–60k tokens
of navigation, changelog noise, and marketing. If it hands you that, it has failed — you paid twice
and gained nothing. Its context is a *disposable buffer*; yours is not.

Required shape, ≤10 rows, ≤400 words, no prose essay, **no recommendation**:

```
CLAIM | EVIDENCE (≤25 words, quoted) | URL | DATE | CONFIDENCE (H/M/L) | SOURCE CLASS | DISCONFIRMING?
```

**Cite or drop.** A claim without a quote + URL + date gets **deleted, not softened.** The quote is
the audit trail — you can re-fetch the one page that matters.

## Web access under dispatch — the non-interactive wall

Dispatched agents run **non-interactively**, so a `WebFetch` to a domain not in `permissions.allow`
**auto-denies with no prompt** ([[background-agents-no-interactive-approval]]). `WebSearch` is
allow-listed and works dispatched; `WebFetch` is gated **per domain**. Open research hits *novel*
domains, so the retrieve phase silently loses sources unless you clear the gate first (ADR-023).

Resolve it **without breaking the contract — you authorise, you never fetch:**

1. **Pre-authorise in Phase 1.** When the plan names its source domains, add each to
   `permissions.allow` as `WebFetch(domain:<host>)` *before* dispatch. Editing the allow-list is a
   permission action, not retrieval.
2. **Discovery-first when sources are unknown.** Dispatch a `WebSearch` sweep (works dispatched) →
   agents return candidate **URLs** → you authorise the domains → re-dispatch the **fetch** to the
   cheap tier.
3. **Agents flag, never fail silently.** An agent needing an unauthorised domain returns
   `NEEDS-DOMAIN: <host>` rather than an empty result — so the source can be authorised and
   re-fetched instead of just vanishing.

## The failure mode to guard against

**Consensus laundering.** The model reads five posts that all crib from one another, converges on the
popular narrative, and returns a balanced-sounding "it depends" that is really SEO sediment with
citations bolted on. It *reads* like research. Hallucination is not the risk here — fluency is.

Three guards:
1. **Source class on every claim** (primary / secondary / anecdote). A claim supported only by three
   secondary blogs is a **rumour**, however many times it appears.
2. **Recency date on every claim.** A confident two-year-old post is the single likeliest way the
   research goes wrong.
3. **A dedicated red-team pass** — one agent whose only job is the strongest case *against* wherever
   the evidence is leaning, plus "who regretted this and why." Disconfirmation has to be **someone's
   assigned job**, not a polite instruction to yourself to stay balanced.

And: **name up front the facts that would flip the recommendation.** If you can't name them, you
haven't reasoned — you've rationalised.

## Output

Synthesis, not a transcript. Per option: what it is · the evidence for and against, cited · the
trade-off being accepted. Then the recommendation, the runner-up and why it lost, and **what would
change this answer.** Tag anything unverified. Report total token spend once.
