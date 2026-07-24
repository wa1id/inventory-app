import { useEffect } from 'react';
import { Stack, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { DatabaseProvider, useDatabase } from '@/providers/DatabaseProvider';
import { OnboardingProvider, useOnboarding } from '@/providers/OnboardingProvider';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { useTheme } from '@/ui/theme';

/**
 * Gates the app on two things: the database being migrated and ready, and
 * onboarding having been seen. Screens below this point can assume both.
 */
function RootNavigator() {
  const { state, retry } = useDatabase();
  const { colors, isDark } = useTheme();
  const router = useRouter();
  const segments = useSegments();
  const onboarding = useOnboarding();

  useEffect(() => {
    if (onboarding.status === 'loading' || state.status !== 'ready') return;
    const inOnboarding = segments[0] === 'onboarding';

    if (onboarding.status === 'pending' && !inOnboarding) {
      router.replace('/onboarding');
    }
  }, [onboarding.status, state.status, segments, router]);

  if (state.status === 'loading' || onboarding.status === 'loading') {
    return (
      <Screen>
        <LoadingState label="Opening your inventory…" />
      </Screen>
    );
  }

  if (state.status === 'error') {
    return (
      <Screen>
        <ErrorState
          title="Inventory could not be opened"
          message={`${state.message}\n\nYour data is still on this device. Try again, and if this keeps happening, restart the app.`}
          onRetry={retry}
        />
      </Screen>
    );
  }

  return (
    <>
      <StatusBar style={isDark ? 'light' : 'dark'} />
      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: colors.surface },
          headerTintColor: colors.text,
          headerTitleStyle: { color: colors.text },
          contentStyle: { backgroundColor: colors.background },
        }}
      >
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="onboarding" options={{ headerShown: false, gestureEnabled: false }} />
        <Stack.Screen name="settings" options={{ title: 'Settings' }} />
        <Stack.Screen name="privacy" options={{ title: 'Privacy' }} />
        <Stack.Screen name="space/new" options={{ title: 'New space', presentation: 'modal' }} />
        <Stack.Screen name="space/[id]/index" options={{ title: 'Space' }} />
        <Stack.Screen
          name="space/[id]/edit"
          options={{ title: 'Edit space', presentation: 'modal' }}
        />
        <Stack.Screen
          name="container/new"
          options={{ title: 'New container', presentation: 'modal' }}
        />
        <Stack.Screen name="container/[id]/index" options={{ title: 'Container' }} />
        <Stack.Screen
          name="container/[id]/edit"
          options={{ title: 'Edit container', presentation: 'modal' }}
        />
        <Stack.Screen name="container/[id]/qr" options={{ title: 'QR label' }} />
        <Stack.Screen name="item/new" options={{ title: 'New item' }} />
        <Stack.Screen name="item/[id]/index" options={{ title: 'Item' }} />
        <Stack.Screen name="item/[id]/edit" options={{ title: 'Edit item' }} />
        <Stack.Screen
          name="capture"
          options={{ headerShown: false, presentation: 'fullScreenModal' }}
        />
        <Stack.Screen name="c/[token]" options={{ title: 'QR label' }} />
      </Stack>
    </>
  );
}

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <DatabaseProvider>
        <OnboardingProvider>
          <RootNavigator />
        </OnboardingProvider>
      </DatabaseProvider>
    </SafeAreaProvider>
  );
}
