---
skill: apex-swift
backend: claude
version: 0.1.0
last_updated: 2026-05-31
sources:
  - docs/research/swift-stack-best-practices.md
  - Apple SwiftUI / Swift 6 concurrency docs (Context7 /websites/developer_apple_swiftui)
staleness_threshold: 30d
description: >
  Use when building or designing an Apple app in Swift / SwiftUI (macOS, iOS, iPadOS) — Swift 6
  strict concurrency, @Observable view-models, SwiftData, NavigationStack, multiplatform structure.
  The stack layer for native Apple surfaces. Not the RAG/AI engine (that's the apex-python sidecar),
  auth mechanics (apex-auth), or whether to pick Swift at all (apex-stack).
---

# apex-swift — Swift 6 / SwiftUI (planning)

Stack skill (ADR-005) for **Swift 6 + SwiftUI** across macOS / iOS / iPadOS. The meat is in
`impl.md`; this file is the planning "what to weigh."

> ⚠️ **Version 0.1.0 — recipe authored but unvalidated** (no Mac/Xcode on the authoring machine).
> The `## Verification Recipe` in `impl.md` is a candidate; validate it on the first real Mac build,
> then bump to 1.0.0. See `docs/research/swift-stack-best-practices.md`.

## Boundary — what this skill is NOT

- **RAG / embeddings / LLM / vector search → the `apex-python` sidecar** (runs as a local service
  the Swift hub calls). Swift does the *client/hub UI + orchestration*, not the AI compute.
- **Auth mechanics → `apex-auth`.** Here: only where the check sits in the app.
- **Whether to choose Swift at all → `apex-stack`.** This skill assumes Apple-native is chosen.

## Research findings (verified 2026-05-31 — see docs/research/swift-stack-best-practices.md)

| Fact | Implication |
|------|-------------|
| Swift 6 strict concurrency is compiler-enforced (Sendable / actors / `@MainActor`) | The compiler is the verifiability buy-back — enable Swift 6 language mode; never disable to silence errors |
| `@Observable` macro replaces `ObservableObject`+`@Published` | View-models are `@MainActor @Observable final class`; plain, testable |
| SwiftData (`@Model`) + NavigationStack are the 2026 persistence + routing defaults | Use them for new code; keep `@Model` separate from wire DTOs |
| SwiftUI is multiplatform but UI adapts per platform | One codebase, `#if os(...)` in the *view* layer only; shared logic in an SPM module |
| SwiftUI is `@MainActor`-isolated | No blocking work on main; offload to actors/`Task`, `await` back |

## What to weigh (planning)

1. **Module boundary:** shared business-logic SPM module (platform-agnostic, Swift 6) vs app targets
   (macOS hub, iOS/iPad clients) that depend on it. Decide what's shared vs platform-specific early.
2. **Concurrency model:** which state is `@MainActor` (UI/view-models) vs an `actor` (shared mutable
   services). Plan `Sendable` boundaries — they're compile-time, so plan them, don't discover them.
3. **Hub ↔ sidecar contract:** the Swift hub talks to the `apex-python` FastAPI engine over the local
   API; the iOS/iPad clients talk to the hub. Plan those boundaries (this skill owns the Swift side).
4. **Persistence:** SwiftData `@Model` for local store; keep it distinct from network models.

## Hard blocks (planning)

- Never plan a Swift app with Swift 6 language mode / strict concurrency disabled.
- Never plan the RAG/AI compute in Swift — it belongs in the `apex-python` sidecar.
- Never plan `ObservableObject`+`@Published` for new view-models (use `@Observable`).
- Never sign off the recipe as proven until it has been run on a real Mac build (v0.1.0 → 1.0.0).

## Review checklist

- [ ] Swift 6 language mode (strict concurrency) planned ON
- [ ] Shared SPM module vs platform app targets delineated
- [ ] `@MainActor` (UI) vs `actor` (shared state) boundaries planned; `Sendable` types identified
- [ ] `@Observable` view-models, SwiftData `@Model`, NavigationStack for new code
- [ ] RAG/AI delegated to the `apex-python` sidecar (not Swift); auth → apex-auth
- [ ] Recipe validation status tracked (v0.1.0 unproven until first Mac build)
