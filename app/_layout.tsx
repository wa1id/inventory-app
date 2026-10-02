import { useEffect, useMemo } from 'react';
import { Platform, Pressable, StyleSheet, View } from 'react-native';
import {
  DarkTheme,
  DefaultTheme,
  Stack,
  ThemeProvider,
  router,
  type NativeStackNavigationOptions,
  type Theme,
} from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import * as SystemUI from 'expo-system-ui';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

import { strings } from '@/i18n/strings';
import { ConnectionProvider } from '@/providers/ConnectionProvider';
import { DatabaseProvider, useDatabase } from '@/providers/DatabaseProvider';
import { FontProvider, useBoldText, useFontsReady } from '@/providers/FontProvider';
import { HouseholdProvider, useHousehold } from '@/providers/HouseholdProvider';
import { OnboardingProvider, useOnboarding } from '@/providers/OnboardingProvider';
import { SyncProvider } from '@/providers/SyncProvider';
import { ToastProvider } from '@/providers/ToastProvider';
import { AppText } from '@/ui/components/AppText';
import { BootScreen } from '@/ui/components/BootScreen';
import { ErrorState } from '@/ui/components/ErrorState';
import { IconButton } from '@/ui/components/IconButton';
import { OverlayHost } from '@/ui/components/Toast';
import { useReducedMotion } from '@/ui/motion';
import { MIN_TOUCH_TARGET, space, useTheme, type ThemeColors } from '@/ui/theme';
import { FONT_FAMILY, textStyle } from '@/ui/typography';

/**
 * A deep link opened from cold (a QR label read by the iPhone Camera) gets
 * Home underneath it, so Back has somewhere to go.
 */
export const unstable_settings = { anchor: '(tabs)' };

/** Header and background colours for native chrome, so nothing flashes white behind a sheet. */
function navigationTheme(colors: ThemeColors, isDark: boolean, fontsReady: boolean): Theme {
  const base = isDark ? DarkTheme : DefaultTheme;
  return {
    ...base,
    dark: isDark,
    colors: {
      primary: colors.ink,
      background: colors.plaster,
      card: colors.plaster,
      text: colors.ink,
      border: colors.rule,
      notification: colors.tape,
    },
    fonts: fontsReady
      ? {
          regular: { fontFamily: FONT_FAMILY[400], fontWeight: 'normal' },
          medium: { fontFamily: FONT_FAMILY[500], fontWeight: 'normal' },
          bold: { fontFamily: FONT_FAMILY[700], fontWeight: 'normal' },
          heavy: { fontFamily: FONT_FAMILY[800], fontWeight: 'normal' },
        }
      : base.fonts,
  };
}

/**
 * The top-left of every modal sheet: "Cancel" in words on iOS, a close icon
 * on Android. It goes back like a swipe-down would, so a dirty form's guard
 * (`useDirtyGuard`) asks first either way.
 */
function SheetClose() {
  if (Platform.OS === 'android') {
    return (
      <IconButton
        icon="close"
        accessibilityLabel={strings.common.close}
        onPress={() => router.back()}
        testID="sheet-close"
      />
    );
  }
  return (
    <Pressable
      onPress={() => router.back()}
      accessibilityRole="button"
      accessibilityLabel={strings.common.cancel}
      hitSlop={space.sm}
      testID="sheet-close"
      style={({ pressed }) => [styles.cancel, { opacity: pressed ? 0.6 : 1 }]}
    >
      <AppText variant="body">{strings.common.cancel}</AppText>
    </Pressable>
  );
}

const sheet: NativeStackNavigationOptions = {
  presentation: 'modal',
  headerLeft: () => <SheetClose />,
};

const fullScreen: NativeStackNavigationOptions = {
  presentation: 'fullScreenModal',
  headerShown: false,
};

/**
 * Gates the app on three things: the database being migrated and ready,
 * onboarding having been seen or not, and the household session having come
 * back from secure storage. Screens below this point can assume all three;
 * before the session is known, a paired phone would otherwise query its local
 * copy first and flash the wrong inventory (B1). Fonts are never waited for.
 */
function RootNavigator() {
  const { state, retry } = useDatabase();
  const onboarding = useOnboarding();
  const household = useHousehold();
  const { colors, isDark } = useTheme();
  const fontsReady = useFontsReady();
  const boldText = useBoldText();
  const reduceMotion = useReducedMotion();

  useEffect(() => {
    SystemUI.setBackgroundColorAsync(colors.plaster).catch(() => undefined);
  }, [colors.plaster]);

  const theme = useMemo(
    () => navigationTheme(colors, isDark, fontsReady),
    [colors, isDark, fontsReady],
  );

  const screenOptions = useMemo((): NativeStackNavigationOptions => {
    const title = textStyle('name', fontsReady, boldText);
    return {
      // Safe with a background colour: no screen uses a large title (iOS 26 hides it then).
      headerStyle: { backgroundColor: colors.plaster },
      headerShadowVisible: false,
      headerTintColor: colors.ink,
      headerTitleStyle: {
        fontFamily: title.fontFamily,
        fontSize: title.fontSize,
        fontWeight: title.fontWeight,
        color: colors.ink,
      },
      headerBackButtonDisplayMode: 'minimal',
      contentStyle: { backgroundColor: colors.plaster },
      fullScreenGestureEnabled: true,
      animation: reduceMotion && Platform.OS === 'android' ? 'fade' : 'default',
    };
  }, [boldText, colors, fontsReady, reduceMotion]);

  if (state.status === 'error') {
    return (
      <SafeAreaView style={[styles.fill, { backgroundColor: colors.plaster }]}>
        <ErrorState
          title={strings.boot.failedTitle}
          message={strings.boot.failedBody}
          onRetry={retry}
        />
      </SafeAreaView>
    );
  }

  if (state.status === 'loading' || onboarding.status === 'loading' || !household.ready) {
    return <BootScreen />;
  }

  return (
    <ThemeProvider value={theme}>
      <ToastProvider>
        <View style={styles.fill}>
          <StatusBar style="auto" />
          <Stack screenOptions={screenOptions}>
            {/* Nothing below mounts, or queries, until onboarding is known to be done. */}
            <Stack.Protected guard={onboarding.status === 'completed'}>
              <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
              <Stack.Screen name="settings" options={{ title: strings.settings.title }} />
              <Stack.Screen name="household" options={{ title: strings.household.screenTitle }} />
              <Stack.Screen name="backup" options={{ title: strings.backup.title }} />
              <Stack.Screen name="privacy" options={{ title: strings.privacy.title }} />
              <Stack.Screen
                name="space/new"
                options={{ ...sheet, title: strings.spaceForm.newTitle }}
              />
              {/* Detail screens show their title in the content (useCollapsingTitle). */}
              <Stack.Screen name="space/[id]/index" options={{ title: '' }} />
              <Stack.Screen
                name="space/[id]/edit"
                options={{ ...sheet, title: strings.spaceForm.editTitle }}
              />
              <Stack.Screen
                name="container/new"
                options={{ ...sheet, title: strings.containerForm.newTitle }}
              />
              <Stack.Screen name="container/[id]/index" options={{ title: '' }} />
              <Stack.Screen
                name="container/[id]/edit"
                options={{ ...sheet, title: strings.containerForm.editTitle }}
              />
              <Stack.Screen name="container/[id]/qr" options={{ title: '' }} />
              <Stack.Screen name="container/[id]/link" options={fullScreen} />
              <Stack.Screen name="item/new" options={{ ...sheet, title: strings.add.title }} />
              <Stack.Screen name="item/[id]/index" options={{ title: '' }} />
              <Stack.Screen
                name="item/[id]/edit"
                options={{ ...sheet, title: strings.editItem.title }}
              />
              {/* Titled by the screen, which knows the item's name. */}
              <Stack.Screen name="item/[id]/move" options={{ ...sheet, title: '' }} />
              <Stack.Screen name="item/[id]/photo" options={{ ...fullScreen, animation: 'fade' }} />
              <Stack.Screen name="capture/index" options={fullScreen} />
              <Stack.Screen
                name="capture/review"
                options={{ title: '', headerBackVisible: false }}
              />
              <Stack.Screen name="c/[token]" options={{ title: strings.deepLink.title }} />
            </Stack.Protected>
            <Stack.Protected guard={onboarding.status === 'pending'}>
              <Stack.Screen
                name="onboarding"
                options={{ headerShown: false, gestureEnabled: false }}
              />
            </Stack.Protected>
          </Stack>
          {/* After the stack, so toasts and the removed-phone layer sit above every screen. */}
          <OverlayHost />
        </View>
      </ToastProvider>
    </ThemeProvider>
  );
}

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      {/* Outermost and never gating: text uses the system font until the fonts arrive. */}
      <FontProvider>
        <DatabaseProvider>
          <HouseholdProvider>
            {/* Needs the session; above Sync so both see the same connection. */}
            <ConnectionProvider>
              {/*
               * Inside DatabaseProvider because it needs the repositories, but above
               * the readiness gate: it handles a not-yet-ready database itself, and
               * mounting it below the gate would restart every sync pass each time
               * the gate re-rendered.
               */}
              <SyncProvider>
                <OnboardingProvider>
                  <RootNavigator />
                </OnboardingProvider>
              </SyncProvider>
            </ConnectionProvider>
          </HouseholdProvider>
        </DatabaseProvider>
      </FontProvider>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  cancel: {
    minHeight: MIN_TOUCH_TARGET,
    justifyContent: 'center',
  },
});
