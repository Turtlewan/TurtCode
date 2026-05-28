---
skill: apex-mobile
backend: deepseek
mode: coding
version: 1.0.0
last_updated: 2026-05-28
---

# Mobile (React Native + Expo) — Coding Patterns

## NEVER / ALWAYS

NEVER:
- Store tokens or secrets in AsyncStorage — use `expo-secure-store`
- Use React Native's built-in `Image` component — use `expo-image` for caching
- Hardcode API URLs — use `expo-constants` with `app.json` `extra` field
- Skip SafeAreaView on any screen — notches and home bars vary per device
- Push to production without testing on both iOS simulator AND Android emulator
- Commit `.env` or any file with real API keys/secrets

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

## Root layout — app/_layout.tsx

```typescript
import { Stack } from 'expo-router';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { GestureHandlerRootView } from 'react-native-gesture-handler';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5,    // 5 minutes
      retry: 2,
    },
  },
});

export default function RootLayout() {
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <QueryClientProvider client={queryClient}>
          <Stack>
            <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
            <Stack.Screen name="modal" options={{ presentation: 'modal' }} />
          </Stack>
        </QueryClientProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
```

## Auth store — Zustand + SecureStore

```typescript
import { create } from 'zustand';
import * as SecureStore from 'expo-secure-store';

interface AuthState {
  token: string | null;
  user: User | null;
  isLoading: boolean;
  signIn: (token: string, user: User) => Promise<void>;
  signOut: () => Promise<void>;
  hydrate: () => Promise<void>;
}

export const useAuthStore = create<AuthState>((set) => ({
  token: null,
  user: null,
  isLoading: true,

  signIn: async (token, user) => {
    await SecureStore.setItemAsync('auth_token', token);
    await SecureStore.setItemAsync('auth_user', JSON.stringify(user));
    set({ token, user });
  },

  signOut: async () => {
    await SecureStore.deleteItemAsync('auth_token');
    await SecureStore.deleteItemAsync('auth_user');
    set({ token: null, user: null });
  },

  hydrate: async () => {
    try {
      const token = await SecureStore.getItemAsync('auth_token');
      const userStr = await SecureStore.getItemAsync('auth_user');
      const user = userStr ? JSON.parse(userStr) : null;
      set({ token, user, isLoading: false });
    } catch {
      set({ isLoading: false });
    }
  },
}));
```

## API client — React Query + auth

```typescript
import Constants from 'expo-constants';
import { useAuthStore } from '@/stores/auth';

const API_URL = Constants.expoConfig?.extra?.apiUrl ?? 'http://localhost:3000';

async function apiFetch<T>(path: string, options?: RequestInit): Promise<T> {
  const token = useAuthStore.getState().token;
  const res = await fetch(`${API_URL}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...options?.headers,
    },
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({ message: 'Request failed' }));
    throw new Error(error.message ?? `HTTP ${res.status}`);
  }

  return res.json();
}

// React Query hook
export function useProfile() {
  return useQuery({
    queryKey: ['profile'],
    queryFn: () => apiFetch<User>('/api/profile'),
    enabled: !!useAuthStore.getState().token,
  });
}
```

## Screen template — SafeArea + keyboard

```typescript
import { KeyboardAvoidingView, Platform, ScrollView, StyleSheet } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Image } from 'expo-image';

export default function ProfileScreen() {
  const insets = useSafeAreaInsets();

  return (
    <KeyboardAvoidingView
      style={{ flex: 1 }}
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
    >
      <ScrollView
        contentContainerStyle={[
          styles.content,
          { paddingBottom: insets.bottom + 16 },
        ]}
        keyboardShouldPersistTaps="handled"
      >
        {/* expo-image: caching, blurhash placeholder, faster than RN Image */}
        <Image
          source={{ uri: user.avatarUrl }}
          placeholder={{ blurhash: user.avatarBlurhash }}
          style={styles.avatar}
          contentFit="cover"
          transition={200}
        />
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: 16,
    gap: 16,
  },
  avatar: {
    width: 80,
    height: 80,
    borderRadius: 40,
  },
});
```

## Push notifications

```typescript
import * as Notifications from 'expo-notifications';
import * as Device from 'expo-device';
import Constants from 'expo-constants';

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: true,
    shouldSetBadge: true,
  }),
});

export async function registerForPushNotifications(): Promise<string | null> {
  if (!Device.isDevice) return null;  // simulators can't receive push

  const { status: existing } = await Notifications.getPermissionsAsync();
  let finalStatus = existing;

  if (existing !== 'granted') {
    const { status } = await Notifications.requestPermissionsAsync();
    finalStatus = status;
  }

  if (finalStatus !== 'granted') return null;

  const projectId = Constants.expoConfig?.extra?.eas?.projectId;
  const { data: token } = await Notifications.getExpoPushTokenAsync({ projectId });
  return token;
}
```

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

## Verification checklist

- [ ] Tokens stored in `expo-secure-store` — not AsyncStorage
- [ ] `expo-image` used instead of React Native `Image`
- [ ] `SafeAreaView` / `useSafeAreaInsets` on every screen
- [ ] `KeyboardAvoidingView` with platform-specific `behavior`
- [ ] Push notification permissions requested with explanation before prompt
- [ ] App tested on iOS simulator AND Android emulator
- [ ] `app.json` `scheme` set for deep links
- [ ] Bundle identifier (iOS) and package name (Android) set before first EAS build
- [ ] EAS project configured: dev / preview / production profiles in `eas.json`
- [ ] OTA update channel set (`channel` in EAS build profile)
- [ ] No secrets committed — only `Constants.expoConfig.extra` for public config
