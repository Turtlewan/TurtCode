---
name: llm-authored-checks-regenerate-collisions
description: "Doctrine-sweep lesson (2026-07-30): when an LLM author writes both a spec's prose and its zero-hit grep checks, new prose keeps colliding with existing checks round after round — and the author confirms fixes it didn't fully make. Derive checks mechanically from prescriptions; host spot-verifies reviewer claims against the raw text."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c0615a98-e0e0-45eb-b6b1-a9aee936af5d
  modified: 2026-08-01T00:09:23.360Z
---

Seven Sol plan-check rounds on the doctrine-sweep spec (2026-07-30) never converged to zero: the
Opus spec-author's fixes kept generating fresh self-defeating pairs (inserted text matching its own
zero-hit sweep), and its confirmation reports were partially FALSE — one dictated deletion survived
three consecutive "done" confirmations (spec line 256), and a banned-phrase AC evaded the author's
own self-audit via a wording variant ("passes by construction" vs the checked "same tree by
construction").

**Why:** prose and checks written by the same generative process drift independently; a literal
self-audit only catches exact-string collisions, and the author grades its own homework.

**How to apply:**
- Zero-hit / positive-assertion checks in specs should be DERIVED from the prescription strings
  mechanically (extract the exact inserted/retired literals), not authored as parallel prose.
- Never accept an author's "done" list at face value at the tail of a long loop — the host
  spot-verifies the reviewer's citations against the raw file (three Sol claims checked directly in
  round 7; all three were right, the author was wrong).
- Cap adversarial-review loops with an announced pass-or-park rule BEFORE entering them
  (this session parked at round 7 per the pre-committed rule; the risk-high Sol gate held).
- Related: [[sol-deliberation-feed-evidence]], [[prove-design-against-reality-first]].

**2026-07-30 evening reconfirmation (retro-wrapper-hygiene, 4 Sol rounds):** the collision class
extends beyond check/prescription pairs to **dictated-fix vs standing-invariant pairs** — late
rounds resolved mechanism findings by adding structures (an obligation event row, a
preserve-never-synthesize rule) that contradicted the spec's own Intent invariants written rounds
earlier ("refusals leave nothing at all", "every row carries all three fields"). The HOST's
dictations caused these, not just the author — when dictating a fix, re-read the Intent invariants
it touches and qualify them in the same dictation. Convergence 18→5→3 still hit the pass-or-park
wall; the pre-committed cap held again (parked at r4).

**2026-08-01 build-phase extensions (retro-wrapper-hygiene, 6 repair rounds):** two more instances
of the same disease, both caught only by independent verification. (a) **Fictional test fixtures:**
family-gate-test seeded an obligation-row shape the wrapper never writes, so the suite stayed green
while the gate exit-13'd every REAL obligation row — the build's one review BLOCK. Fixtures must be
derived FIELD-FOR-FIELD from the production writer's emit site, and a test-first red proof against
the real shape demanded. (b) **Console-rendered assertions:** asserting contractual text from
captured console output circled through three channels (Write-Host → stdout → information stream),
each green in the coder's console and red in the host's. Terminal fix: persist contractual values
to an artifact (ledger row) and assert byte-exact from there; console is display-only. Also
reconfirmed ×3: coder "done" claims refuted by host re-runs — the host re-running EVERY suite
(not the repair's subset) is what caught both regressions.
