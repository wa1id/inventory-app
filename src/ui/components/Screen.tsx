import { createContext, useContext, type ReactNode } from 'react';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { SafeAreaView, type Edge } from 'react-native-safe-area-context';

import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { ConnectionBanner } from '@/ui/components/ConnectionBanner';
import { FRAME_EDGES } from '@/ui/components/ScreenFrame';
import { space, useTheme } from '@/ui/theme';

export { ErrorState, type ErrorStateProps } from '@/ui/components/ErrorState';
export { ScreenFrame, TabRootHeader } from '@/ui/components/ScreenFrame';

const LegacyTabRootContext = createContext(false);

/**
 * @deprecated Compatibility only, removed in cleanup with `Screen`.
 *
 * The tabs layout wraps every tab scene in this. Tab roots used to sit under
 * the tab navigator's header and asked `Screen` for no top edge; the new tab
 * shell has no header, so inside a tab `Screen` pads the top itself and
 * leaves the bottom to the tab bar, without each old tab screen changing.
 */
export function LegacyTabRoot({ children }: { children: ReactNode }) {
  return <LegacyTabRootContext.Provider value={true}>{children}</LegacyTabRootContext.Provider>;
}

interface ScreenProps {
  children?: ReactNode;
  edges?: Edge[];
}

/**
 * @deprecated Use `ScreenFrame`. Kept until every screen has moved: the
 * plaster background, the given safe-area edges and the connection banner.
 */
export function Screen({ children, edges = ['top', 'left', 'right'] }: ScreenProps) {
  const { colors } = useTheme();
  const tabRoot = useContext(LegacyTabRootContext);
  return (
    <SafeAreaView
      style={[styles.screen, { backgroundColor: colors.plaster }]}
      edges={tabRoot ? FRAME_EDGES.tabRoot : edges}
    >
      <ConnectionBanner />
      {children}
    </SafeAreaView>
  );
}

/**
 * A centred spinner. Lists and details use `Skeleton` instead; this stays for
 * waits with no shape to show, such as the camera permission check.
 */
export function LoadingState({ label = strings.common.loading }: { label?: string }) {
  const { colors } = useTheme();
  return (
    <View style={styles.centered} accessibilityLiveRegion="polite">
      <ActivityIndicator color={colors.graphite} />
      <AppText variant="meta" tone="graphite" center>
        {label}
      </AppText>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.md,
    padding: space.xl,
  },
});
