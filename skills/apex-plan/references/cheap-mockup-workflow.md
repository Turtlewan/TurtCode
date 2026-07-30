# Cheap-mockup workflow — full procedure

Loaded on demand when running the cheap-mode mockup loop. `design-workflow.md` carries the two-loop rule + the
SwiftUI hard gate; this file carries the side-by-side mechanics and the headless-render tiers.

## Interactive co-review — browser alternative
The default preview surface is Cursor's in-editor render (see SKILL.md). If the user prefers a browser,
the same `docs/research/mockups/<name>.html` opens in their **own** Chrome tab (`file://…` or served) —
it **stays open the whole loop**; never a Playwright-controlled tab (that is Claude's *separate* headless
screenshot instance and is **never `browser_close`d on the user's view**). Optional `live-server`/`vite`
for auto-reload.

## Multiple options → all tabs in ONE persistent Chrome window
The one case external Chrome beats Cursor's single-pane render (true side-by-side). When the user asks
for options/variants, write each to its own `docs/research/mockups/<name>.html`, then open them **all at
once as tabs in the user's own Chrome window** in a single launch — Windows:
`Start-Process chrome -ArgumentList 'file:///…A.html','file:///…B.html',…` (Chrome opens multiple URL
args as tabs in one window; appends to the existing window if Chrome is already running). They **persist**
for side-by-side comparison. **Never present option tabs via Playwright** — its browser closes on context
end. Iterate per option: user comments on one → edit that file → user refreshes that tab.

## Headless-render tiers — get a PNG without booting a heavy emulator/window
- **Tier A — headless host-render → PNG** (no emulator; cheapest, scriptable): **Flutter** goldens
  (`flutter test --update-goldens`), **Android Compose** (Paparazzi / Compose Preview Screenshot Testing
  / Roborazzi), **Avalonia** desktop (headless Skia `CaptureRenderedFrame()`). All Windows-runnable.
- **Tier B — browser preview + Playwright screenshot** (= the web loop): Web, **Electron/Tauri**
  (Chromium under the hood — mock in Chrome like a website), Expo/RN via Storybook-RN-Web.
- **Tier C — run on emulator/device/window + capture**: Android `adb exec-out screencap -p > x.png`;
  WinUI/WPF window via FlaUI / PowerShell; iOS simulator (Mac).

**Apple SwiftUI** has no Windows render path at all — fall back to a CI macOS runner (render + upload PNG
artifacts) or a web-mockup proxy for layout/feel. Full per-target table + commands + caveats:
`docs/research/cheap-mode-native/`.
