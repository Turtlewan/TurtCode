---
skill: apex-mobile
backend: claude
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Expo Docs (now official RN start) — docs.expo.dev
  - React Native (New Architecture) — reactnative.dev/docs
  - Flutter — docs.flutter.dev
  - Kotlin Multiplatform — kotlinlang.org/docs/multiplatform.html
  - Apple HIG / Android target API policy — developer.apple.com · developer.android.com
staleness_threshold: 14d
description: >
  Use when building a mobile app or extending to mobile — iOS/Android, the cross-platform
  framework choice (React Native/Expo, Flutter, Kotlin Multiplatform), mobile nav, native
  device APIs (camera/notifications/biometrics), OTA updates, app-store submission. Triggers:
  "build a mobile app", "iOS and Android", "React Native/Expo/Flutter", "publish to the app
  store", "add mobile to our SaaS". Owns the native-vs-cross-platform decision; pure
  Apple-native SwiftUI depth → apex-swift, see § Stack assumptions.
---

# Mobile Development Specialist — Planning Mode

## When to activate
Any spec involving iOS or Android app development, the cross-platform framework choice,
mobile navigation, native device APIs (camera, notifications, biometrics),
app store submission, over-the-air updates, or extending a web SaaS to mobile.

## Stack assumptions

This skill defaults to **cross-platform (React Native + Expo)** but owns the **native-vs-cross
decision first**:
- **One platform, deep OS integration, best feel (esp. Apple-only)** → go **native**. SwiftUI
  depth (incl. Liquid Glass, iOS 26) lives in **apex-swift**; Android-native is Jetpack Compose / Kotlin.
- **Both platforms, one JS/TS team, speed** → **React Native + Expo** (the default below).
- **Both platforms, custom-drawn/animation-heavy UI** → **Flutter** (Dart, Impeller engine).
- **Shared business logic across native apps** → **Kotlin Multiplatform** (logic shared, UI native per platform).

The Expo/RN specifics below are one path; map them to the chosen framework. Native UI/UX
detail → apex-ui-ux-design (+ apex-swift); a11y → apex-accessibility.

## Questions to ask before designing

- iOS only, Android only, or both? (React Native/Expo targets both; Flutter too)
- Expo managed workflow or bare React Native? (start managed, eject only when needed)
- Does it require native modules not available in Expo? (list them first)
- Authentication strategy? (Expo SecureStore for tokens, biometric unlock)
- Offline support required? (MMKV + React Query persistence, SQLite)
- OTA updates needed? (Expo EAS Update for JS-layer hotfixes without app store review)

## Stack selection (current — 2026)

**React Native + Expo (recommended for JS/TS teams; Expo is now the *official* RN start):**
- Single codebase → iOS + Android. **New Architecture is exclusive** as of 2026 (JSI + Fabric +
  TurboModules; the old bridge was **removed in RN 0.82**); **Hermes** is the default engine.
- Expo managed workflow + EAS Build (cloud) + EAS Update (OTA for JS changes, no store review).

**Flutter (~46% share; Dart, own Impeller rendering engine):**
- Compiles to native ARM; best for animation-heavy / pixel-perfect custom UI. Larger bundle.

**Kotlin Multiplatform (KMP — fastest-growing, Google-backed):**
- Share **business logic** (networking, models, persistence) across platforms while keeping
  **UI native** (SwiftUI on Apple, Compose on Android). Best when native feel matters but logic shouldn't be duplicated.

**Native (SwiftUI / Jetpack Compose):**
- One platform or deepest OS integration / best feel → native. Apple-native → **apex-swift**.

**Decision:** Apple-only or native-feel-critical → native (apex-swift) / KMP for shared logic.
JS/TS team, both platforms, speed → Expo. Custom-drawn UI → Flutter. The "one framework for
everything" era is over — **hybrid** (KMP logic + native/RN/Flutter UI) is common in 2026.

## Expo project structure

```
my-app/
├── app/                 # Expo Router file-based routes
│   ├── (tabs)/
│   │   ├── index.tsx   # Home tab
│   │   └── settings.tsx
│   ├── _layout.tsx     # Root layout (navigation, providers)
│   └── modal.tsx
├── components/          # Shared UI components
├── hooks/               # Custom React hooks
├── stores/              # State management (Zustand)
├── services/            # API clients
├── assets/              # Images, fonts
├── app.json             # Expo config
└── eas.json             # EAS Build + Update profiles
```

## Navigation — Expo Router (file-based)

Expo Router is the standard for new Expo projects. File structure maps to routes:
```
app/index.tsx          → /
app/profile.tsx        → /profile
app/(tabs)/home.tsx    → /home  (tab group)
app/[id].tsx           → /:id  (dynamic route)
```

For apps that need native stack navigation: React Navigation v7 with `@react-navigation/native-stack`.

## Native device APIs (Expo SDK)

```typescript
// Push notifications
import * as Notifications from 'expo-notifications';
const token = await Notifications.getExpoPushTokenAsync();

// Camera
import { CameraView, useCameraPermissions } from 'expo-camera';

// Biometrics
import * as LocalAuthentication from 'expo-local-authentication';
const result = await LocalAuthentication.authenticateAsync({ promptMessage: 'Confirm identity' });

// Secure storage (tokens, credentials)
import * as SecureStore from 'expo-secure-store';
await SecureStore.setItemAsync('token', accessToken);

// File system
import * as FileSystem from 'expo-file-system';
```

## State management

**Zustand** — minimal, no boilerplate, works in React Native:
```typescript
const useAuthStore = create<AuthState>((set) => ({
  user: null,
  setUser: (user) => set({ user }),
  logout: () => set({ user: null }),
}));
```

**React Query (TanStack Query)** — server state, offline caching:
```typescript
// Persist queries to MMKV for offline support
import { createSyncStoragePersister } from '@tanstack/query-sync-storage-persister';
import { MMKV } from 'react-native-mmkv';
```

**MMKV** — fast key-value storage (replaces AsyncStorage for performance):
```typescript
import { MMKV } from 'react-native-mmkv';
const storage = new MMKV();
storage.set('key', 'value');
```

## EAS Build + Submit

```json
// eas.json
{
  "cli": { "version": ">= 12.0.0" },
  "build": {
    "development": {
      "developmentClient": true,
      "distribution": "internal"
    },
    "preview": {
      "distribution": "internal",
      "channel": "preview"
    },
    "production": {
      "autoIncrement": true,
      "channel": "production"
    }
  },
  "submit": {
    "production": {
      "ios": { "appleId": "dev@example.com", "ascAppId": "1234567890" },
      "android": { "serviceAccountKeyPath": "./service-account.json" }
    }
  }
}
```

```bash
# Build for iOS TestFlight
eas build --platform ios --profile preview

# Build for production + submit to stores
eas build --platform all --profile production --auto-submit

# OTA update (JS only — no store review needed)
eas update --channel production --message "Fix login bug"
```

## App store preparation checklist

**iOS (App Store Connect):**
- Bundle ID set in `app.json` (`ios.bundleIdentifier`)
- Provisioning profile and signing certificate (EAS handles this)
- App Store screenshot sizes: 6.7", 6.5", 5.5" (iPhone); 12.9" (iPad if universal)
- Privacy manifest (`PrivacyInfo.xcprivacy`) required for any API usage
- App Privacy labels declared (data collection, tracking)

**Android (Google Play Console):**
- Package name set (`android.package`)
- Keystore managed by EAS (or provide own — never lose it)
- Target API level: Google Play requires targeting a **recent** API (rises ~yearly — verify current; was API 35 / Android 15, trending to 36) for new submissions & updates
- 64-bit support: required; iOS builds target the current SDK (iOS 26 era)

## Common pitfalls

- **Android back button:** React Navigation handles it; test explicitly
- **Keyboard avoiding view:** Use `KeyboardAvoidingView` on iOS; different behaviour on Android
- **Safe area insets:** Always use `SafeAreaView` or `useSafeAreaInsets()` — notches, home bar
- **Image caching:** Use `expo-image` not React Native's `Image` — better caching and performance
- **Metro bundler:** Hot reload only works for JS changes — native changes require a full rebuild
- **Expo Go limitations:** Some native modules require a development build (`npx expo run:ios`)

## Review checklist

- [ ] Expo managed workflow used (not bare) unless specific native modules require it
- [ ] EAS Build configured for dev, preview, production profiles
- [ ] EAS Update channel set for OTA updates
- [ ] Sensitive data in `expo-secure-store` — not AsyncStorage
- [ ] Push notification permissions requested with proper UX (explain before asking)
- [ ] SafeAreaView used on all screens
- [ ] Tested on both iOS simulator AND Android emulator
- [ ] Deep links configured (`app.json scheme`)
- [ ] App store metadata ready before first submission (screenshots, descriptions)

## Standards

Expo Docs: docs.expo.dev
React Navigation: reactnavigation.org
EAS Build: docs.expo.dev/build/introduction
React Native performance: reactnative.dev/docs/performance
