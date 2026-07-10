---
skill: apex-swift
backend: coding
version: 0.2.0
last_updated: 2026-06-12
sources:
  - Apple — Adopting strict concurrency in Swift 6; SwiftUI docs (Context7 /websites/developer_apple_swiftui)
  - docs/research/swift-stack-best-practices.md
  - Context7 /avdlee/swiftui-agent-skill, /twostraws/swiftui-agent-skill
  - Apple — Xcode 27 agent skills (WWDC 2026); docs/research/swiftui-design-tooling/ (2026-06-12)
staleness_threshold: 30d
description: >
  Coding-mode patterns for Swift 6 + SwiftUI (macOS/iOS/iPadOS) — strict concurrency, @Observable,
  SwiftData, and the Verification Recipe. Loaded when stack_skills includes apex-swift.
---

# apex-swift — Implementation patterns

Swift 6 (strict-concurrency language mode) + SwiftUI multiplatform (macOS hub + iOS/iPad clients).
Pre-resolved defaults — apply directly.

> ⚠️ **RECIPE NOT YET VALIDATED.** Version 0.1.0 — authored from research, **never run** (no
> Xcode/macOS on the authoring machine). The `## Verification Recipe` below is a *candidate*. On the
> first real Mac build, RUN it, fix the commands to reality (scheme/destination/lint-tool names),
> and bump to 1.0.0. Until then, treat recipe output as unproven.

## NEVER do

- Disable Swift 6 language mode / strict concurrency to silence errors — it's the correctness gate.
- Use `ObservableObject` + `@Published` for new view-models — use the `@Observable` macro.
- Slap `@unchecked Sendable` on a type to quiet a data-race error — fix the actual sharing (make it
  an actor, make state immutable, or isolate it).
- Do blocking / long work on `@MainActor` (the SwiftUI context) — offload to a background `Task` /
  actor, `await` back for UI.
- Reuse a SwiftData `@Model` as a network/Codable DTO — keep persisted models separate from wire models.
- Put business logic behind `#if os(...)` — only the *view* layer is platform-conditional.

## ALWAYS do

- Enable Swift 6 language mode (`// swift-tools-version:6.0`+, `SWIFT_VERSION = 6.0`) from creation.
- View-models: `@MainActor @Observable final class VM { ... }`.
- Mark cross-actor types `Sendable`; use `actor` for shared mutable state.
- Shared business logic in a Swift 6 SPM module; app targets depend on it; UI adapts per platform.
- Use `NavigationStack` (type-safe paths) and `SwiftData` (`@Model`) for new code.

## Apple agent skills — load as context when present (Xcode 27)

Xcode 27 (WWDC 2026) ships Apple-authored SwiftUI agent skills as plain Markdown. When building
SwiftUI, **load these as context if present** — they raise the idiomatic-SwiftUI floor and cover
post-training-cutoff APIs the patterns below can't:
- `swiftui-specialist` — idiomatic patterns, data flow, deprecated-API guidance.
- `swiftui-whats-new-27` — Liquid Glass 2 + new APIs with no model training data.

Expected path: `~/.claude/skills/apple-swiftui/` (export from Xcode 27 → drop the `.md` files there).
⚠️ **Gated on Xcode 27** (beta as of 2026-06): if the files are absent, proceed on the patterns below
and **flag** "Apple SwiftUI agent skills not yet installed (Xcode 27)" — never block on them.

## Pattern — observable view-model (main-actor isolated)

```swift
import Observation

@MainActor @Observable final class NotesViewModel {
    private(set) var notes: [Note] = []
    private let store: NotesStore          // an `actor` or Sendable service

    init(store: NotesStore) { self.store = store }

    func search(_ query: String) async {
        notes = await store.search(query)  // await hops off/on main safely
    }
}
```

## Pattern — actor for shared mutable state (Sendable boundary)

```swift
actor NotesStore {
    private var items: [Note] = []
    func add(_ note: Note) { items.append(note) }
    func search(_ q: String) -> [Note] {
        items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
}
// Note must be Sendable to cross the actor boundary:
struct Note: Sendable, Identifiable { let id: UUID; var title: String; var body: String }
```

## Pattern — platform-conditional view, shared logic

```swift
struct NotesView: View {
    @State private var vm: NotesViewModel
    var body: some View {
        List(vm.notes) { NoteRow($0) }
        #if os(macOS)
        .frame(minWidth: 600)          // hub window sizing — view layer only
        #endif
    }
}
```

## Verification Recipe

> ⚠️ Candidate — validate on first Mac build, then bump to 1.0.0.

**Language / shared-module layer (SPM) — the compiler is the Swift 6 safety gate:**
```bash
swift build            # 0 errors under Swift 6 strict concurrency
swift test             # Swift Testing (@Test) / XCTest
```

**App layer (Xcode project) — build per platform destination (authoritative):**
```bash
xcodebuild -scheme <App> -destination 'platform=macOS' build
xcodebuild -scheme <App> -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme <App> -destination 'platform=macOS' test
```

**Style layer:**
```bash
swiftlint              # realm/SwiftLint — or: swift format lint --recursive Sources/
```

**The loop (per task):** `swift build` (fix first concurrency/type error, re-run) → `swift test` →
`xcodebuild` per platform (catches platform-specific + UI build errors) → `swiftlint`. One
hypothesis per failure (apex-debug discipline). The compiler is authoritative for concurrency safety.

**Composition:** the RAG/AI engine is **not** Swift — it's the bound `apex-python` sidecar the app
calls over the local API. apex-swift covers only the Apple client/hub surface.

## Common errors → fix (Swift 6 concurrency)

| Error fragment | Cause | Fix |
|----------------|-------|-----|
| `Sending '…' risks causing data races` | non-Sendable value crosses isolation | make the type `Sendable`, or pass a value copy / immutable |
| `Main actor-isolated property can not be referenced from a Sendable closure` | UI state touched off main | `await MainActor.run { }` or mark the context `@MainActor` |
| `Call to main actor-isolated initializer in a synchronous nonisolated context` | building UI off main | hop to `@MainActor` |
| `Type '…' does not conform to the 'Sendable' protocol` | shared across actors | conform it (value type / immutable) or wrap in an `actor` |
| `Reference to captured var '…' in concurrently-executing code` | mutable capture in `Task` | capture a `let` copy, or isolate the state |
