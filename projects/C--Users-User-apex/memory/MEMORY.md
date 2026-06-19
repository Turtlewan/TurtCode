# APEX Project Memory

- [Cheap-mockup interactive loop](cheap-mockup-interactive-loop.md) — UI design-prototype default: single mockup previews in Cursor's in-editor render (same window as live code diff); Chrome only for multi-variant side-by-side; user comments → Claude view-layer edit → user re-views → repeat to approval; never Playwright's tab
- [Agentic-OS video ingestion mode](agentic-os-video-ingestion.md) — for each suggested video: ingest→research→deep-dive→log verdict; DON'T implement; consolidated report only on request; ledger = docs/research/agentic-os-video-audit.md

- [Parked discussion — handover & context efficiency](parked-discussion-handover.md) — planning→coding handover, token-efficient specs, context minimisation for DeepSeek
- [Project deployment setup](project-deployment.md) — DeepSeek cloud coding backend ALREADY runs on Windows (env-var swap); two gates: `coding-session` (Windows-runnable) vs `mac-gated` (Xcode/Swift/Bitrig only); Mac Mini = dev+prod target; AWS future scale-up
- [Verify env claims live](verify-env-claims-live.md) — never assert "can't run X here"/capability limits from memory or status notes; check live env+settings+hooks first (the 2026-06-15 "Mac-gated" miss)
- [Skill authoring workflow](skill-authoring-workflow.md) — apex-skill-author is source of truth; dogfood the Iron Law; edit skills directly in planning; per-edit backend gate
- [Per-project what+why docs](per-project-what-why-docs.md) — next-session objective: APEX should produce + maintain a human-readable System Overview + ADR log per built project (portability insurance)
- [Be token-efficient](be-token-efficient.md) — keep prose lean, avoid unnecessary tool calls/re-reads
- [Baseline-test isolation](baseline-test-isolation.md) — RED/GREEN subagents get contaminated by the repo's own roadmap/ADRs; forbid planning-doc reads when baseline-testing skill edits
- [~/.claude blanket gitignore](claude-repo-blanket-gitignore.md) — ~/.claude ignores `*`; commit tracked skill/registry files with `git add -f` by name
- [User autonomy preference](user-autonomy-preference.md) — high-autonomy "auto mode"; batch questions to the end, decide autonomously, flag review-needed
- [Iron Law application depth](iron-law-application-depth.md) — default lightweight Iron Law for convention/structural skill edits; reserve full RED/GREEN subagent dogfood for skills flagged for emphasis (new stack/domain)
- [Sweep includes refresh](sweep-includes-refresh.md) — a skill sweep is de-couple PLUS real-world content refresh (research the gaps/fast-moving facts), not just restructure
- [No numeronyms](no-numeronyms.md) — spell terms out in prose ("accessibility" not "a11y") unless a big token save
- [No reflexive UI-render prompt](no-reflexive-ui-render-prompt.md) — don't auto-offer a visual render/screenshot when UI is discussed/changed; only when seeing pixels is the deliverable
- [Absorption-pass protocol](absorption-pass-protocol.md) — external-system compare→absorb: dedup-aware + token-cost-flagged report FIRST, no skill edits until approved
- [Claude Agent SDK billing split](claude-agent-sdk-billing-split.md) — Jun 15 2026: interactive CC (incl. subagents) stays on subscription; headless/programmatic APEX runs hit a capped credit pool
- [Background work overlap](background-work-overlap.md) — pipelining: while a long background task (research/build) runs, keep questioning the user on specs; don't go idle
- [Design style on-demand](design-style-on-demand.md) — don't auto-load fixed-aesthetic style skills; establish the *feel* first (design brief), then install one matching style from `~/.claude/style-library/` (Mechanism A)
- [APEX = sole coding workflow](apex-sole-coding-workflow.md) — absorb good ideas from competing skill-systems (gsd/superpowers/yolo) into APEX, then remove them; never let rival coding workflows co-exist (confuses DeepSeek)
- [Removal over prohibition](removal-over-prohibition.md) — fix a weak-coder skill conflict by removing the source, not adding a "don't do X" rule (prohibition rules decay fastest); if a backstop is needed, phrase it positively
- [RED-probe before absorbing content](absorption-red-probe-before-content.md) — external-skill *content* is often model-redundant; run a cheap bare-agent RED probe before absorbing, and don't let "flagged for rigor" defer real cuts (behaviour rules earn their place; content usually doesn't)
- [APEX ongoing, not Artemis-gated](apex-ongoing-not-artemis-gated.md) — APEX self-improvement + dogfooding is an ongoing end in itself; Artemis is one downstream consumer, not the master gate
- [UI preview = terminal + Chrome](ui-preview-terminal-plus-browser.md) — RUNNING-APP live preview (dev server) via terminal + external Chrome (Win-snap); narrowed 2026-06-16 — static cheap-mockups now render in Cursor's pane ([[cheap-mockup-interactive-loop]]); don't go down editor-layout rabbit holes for the live-app case
- [UI design = cheap-display default](ui-design-cheap-display-default.md) — design UI via logic-free mockup + cheap display, Claude as primary UI hand at this stage, then DeepSeek wires the locked design
- [Cursor co-edit flow](cursor-coedit-flow.md) — user's primary coding flow: APEX in Cursor's terminal, co-edit files live in editor; keep files open + auto-accept + edit mode; integration pushes diffs but can't drive tabs
- [Spec mechanism not just outcome](spec-mechanism-not-just-outcome.md) — spec tasks must state the *producing mechanism*, not just the outcome; a "reuse X" task can't achieve a behaviour X structurally lacks (P6-maths dead-heroes); now enforced by apex-plan readiness-gate Sufficiency audit (v1.22.0)
