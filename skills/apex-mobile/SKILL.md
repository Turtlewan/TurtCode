---
skill: apex-mobile
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Expo Docs — docs.expo.dev
  - React Native Docs — reactnative.dev/docs
  - EAS Docs — docs.expo.dev/eas
staleness_threshold: 14d
---

# Mobile Development Specialist — Planning Mode

## When to activate
Any spec involving iOS or Android app development, React Native/Expo setup,
mobile navigation, native device APIs (camera, notifications, biometrics),
app store submission, over-the-air updates, or extending a web SaaS to mobile.

## Questions to ask before designing

- iOS only, Android only, or both? (React Native/Expo targets both; Flutter too)
- Expo managed workflow or bare React Native? (start managed, eject only when needed)
- Does it require native modules not available in Expo? (list them first)
- Authentication strategy? (Expo SecureStore for tokens, biometric unlock)
- Offline support required? (MMKV + React Query persistence, SQLite)
- OTA updates needed? (Expo EAS Update for JS-layer hotfixes without app store review)

## Stack selection

**React Native + Expo (recommended for JS/TS teams):**
- Single codebase → iOS + Android
- Expo managed workflow: no Xcode/Android Studio needed for most work
- EAS Build: cloud build service (no local build environment needed)
- EAS Update: OTA updates for JS changes without App Store review

**Flutter (if team knows Dart or needs pixel-perfect custom UI):**
- Dart language; strong typing; own rendering engine (not native components)
- Better performance for animation-heavy, custom-drawn UIs
- Larger initial bundle size

**Decision:** If team already knows React/TypeScript → Expo. If starting fresh with complex custom UI → Flutter.

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
- Target API level: Android 14 (API 34) minimum for new submissions
- 64-bit support: required

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
