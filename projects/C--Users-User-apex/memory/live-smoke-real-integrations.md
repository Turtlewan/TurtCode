---
name: live-smoke-real-integrations
description: "Hermetic mocked tests pass while real integration bugs hide; always run a live smoke against the real engine/service for integration-bearing work, not just mock-based unit tests."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 249e2fd5-e8ad-489d-b78a-16a0ac7ee1b5
---

For Artemis v2 memory work (Slice 2, Cognee), Codex-built code passed `mypy --strict` + the full
hermetic test suite (fake-cognee/fake-ModelPort), yet **live smokes against real Cognee + Ollama
caught three real bugs the mocks could not**: (1) `SearchType.CHUNKS` returns node **dicts**, not
strings (mocks returned strings) → context was serialized-dict garbage; (2) the first consolidating
`write` searched an **uninitialized** store and crashed; (3) supersession used exact content match but
the LLM dropped a trailing period.

**Why:** mocks encode our *assumptions* about the dependency's shape/behavior; real services violate
them. Unit tests prove orchestration logic, not integration reality.

**How to apply:** for any spec that wires a real external engine/SDK/service, after the hermetic suite
is green run a **host live smoke** against the real thing (it's in the spec's "Post-build (host)"
section) before committing. When the live env is constrained (the 8GB box + a background-task reaper
kill slow runs), run the smoke foreground with a long timeout. Fold each finding back into a unit test.
Relates to [[host-verify-full-mypy]] and [[artemis-v2-build-cadence]].

**UI variant (2026-07-09, map-shell-removal):** the "real engine" for UI specs is the RENDERER.
jsdom style-text assertions can't see UA default rendering — deleting the `glass` class exposed the
WebView's native `<button>` background/border and every gate stayed green while every node wore a
white UA-chrome "shell" live (fixed `ef0bd66`: explicit `background:none;border:0;appearance:none`).
A spec that removes/changes a styling class on a native element needs an explicit UA-chrome reset
AND a live app launch as its smoke.

(migrated from Artemis memory 2026-07-19)
