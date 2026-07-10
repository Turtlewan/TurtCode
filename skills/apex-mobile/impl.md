---
skill: apex-mobile
backend: coding
version: 1.2.0
last_updated: 2026-06-10
sources:
  - Expo Docs — docs.expo.dev
  - React Native (New Architecture) — reactnative.dev
staleness_threshold: 14d
description: >
  Coding-mode enforcement for the React Native + Expo path — secure storage, expo-image,
  SafeArea, EAS build/submit/OTA. This is the RN/Expo lane; native (SwiftUI → apex-swift,
  Jetpack Compose) and Flutter/KMP differ — see § Stack assumptions. Loads when building a
  cross-platform mobile app.
---

# Mobile (React Native + Expo) — Coding Patterns

## Stack assumptions

These patterns are the **React Native + Expo** path (the cross-platform default; **New
Architecture** is on — keep `newArchEnabled: true`). If the bound stack is **native** the
mechanism differs entirely: **Apple/SwiftUI → apex-swift** (Keychain not SecureStore, native
nav, no EAS); **Android → Jetpack Compose/Kotlin**; **Flutter** → Dart/pub/`flutter build`;
**KMP** → shared Kotlin logic + native UI. Don't apply Expo APIs off the RN path.

## NEVER / ALWAYS

NEVER:
- Store tokens or secrets in AsyncStorage — use `expo-secure-store`
- Use React Native's built-in `Image` component — use `expo-image` for caching
- Hardcode API URLs — use `expo-constants` with `app.json` `extra` field
- Skip SafeAreaView on any screen — notches and home bars vary per device

ALWAYS:
- Use Expo managed workflow; only eject to bare when a native module requires it
- Wrap root layout with all providers (TanStack Query, auth, toast, safe area)
- Handle the `KeyboardAvoidingView` difference between iOS and Android explicitly
- Request permissions with an explanation screen before calling the permission prompt
- Use `expo-router` file-based routing for new projects
- Add `app.json` `scheme` for deep links before first store submission

## Project bootstrap

```bash
# Create new Expo project
npx create-expo-app@latest MyApp --template

# Install core dependencies
npx expo install \
  expo-router \
  expo-secure-store \
  expo-image \
  expo-notifications \
  expo-local-authentication \
  expo-constants \
  @tanstack/react-query \
  zustand \
  react-native-mmkv \
  react-native-safe-area-context \
  react-native-screens

# Install EAS CLI
npm install -g eas-cli
eas login
eas build:configure
```

## app.json — essential config

```json
{
  "expo": {
    "name": "MyApp",
    "slug": "myapp",
    "scheme": "myapp",
    "version": "1.0.0",
    "orientation": "portrait",
    "newArchEnabled": true,
    "ios": {
      "bundleIdentifier": "com.example.myapp",
      "supportsTablet": false
    },
    "android": {
      "package": "com.example.myapp",
      "adaptiveIcon": {
        "foregroundImage": "./assets/adaptive-icon.png",
        "backgroundColor": "#ffffff"
      }
    },
    "extra": {
      "apiUrl": "https://api.example.com",
      "eas": {
        "projectId": "your-eas-project-id"
      }
    },
    "plugins": [
      "expo-router",
      "expo-secure-store",
      [
        "expo-notifications",
        { "icon": "./assets/notification-icon.png" }
      ]
    ]
  }
}
```

> Full wiring: read references/expo-patterns.md when the task touches the root layout/providers,
> auth/token storage, API client/server state, screens (SafeArea + keyboard), or push notifications.

## EAS commands

```bash
# Build for development (installs dev client)
eas build --platform all --profile development

# Build for internal testing (no store)
eas build --platform all --profile preview

# Build for production + auto-submit
eas build --platform all --profile production --auto-submit

# OTA update (JS-only, no store review)
eas update --channel production --message "Fix login crash"
eas update --channel staging --message "Test new feature"

# View builds
eas build:list

# View updates
eas update:list --branch production

# Submit to stores manually
eas submit --platform ios
eas submit --platform android
```

## Verification Recipe

Run after every task — all three must pass with exit code 0:

```bash
npx tsc --noEmit      # typecheck
npx expo-doctor       # Expo config + dependency health
npx eslint .          # lint
```

## Verification checklist

- [ ] Run the Verification Recipe above — `npx tsc --noEmit`, `npx expo-doctor`, `npx eslint .` all pass
- [ ] Tokens stored in `expo-secure-store` — not AsyncStorage
- [ ] `expo-image` used instead of React Native `Image`
- [ ] `SafeAreaView` / `useSafeAreaInsets` on every screen
- [ ] `KeyboardAvoidingView` with platform-specific `behavior`
- [ ] Push notification permissions requested with explanation before prompt
- [ ] **Device testing (iOS simulator AND Android emulator)**: detect available simulators/emulators on the host and run what's feasible; for each platform that can't be run, report it as not-run with the reason and flag it for planning-mode / human review before any production push — do not guess or mark it done.
- [ ] `app.json` `scheme` set for deep links
- [ ] Bundle identifier (iOS) and package name (Android) set before first EAS build
- [ ] EAS project configured: dev / preview / production profiles in `eas.json`
- [ ] OTA update channel set (`channel` in EAS build profile)
- [ ] No secrets committed — only `Constants.expoConfig.extra` for public config
