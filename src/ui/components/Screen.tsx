import type { ReactNode } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView, type Edge } from 'react-native-safe-area-context';

import { Button } from '@/ui/components/Button';
import { spacing, useTheme } from '@/ui/theme';

interface ScreenProps {
  children?: ReactNode;
  edges?: Edge[];
}

export function Screen({ children, edges = ['top', 'left', 'right'] }: ScreenProps) {
  const { colors } = useTheme();
  return (
    <SafeAreaView style={[styles.screen, { backgroundColor: colors.background }]} edges={edges}>
      {children}
    </SafeAreaView>
  );
}

export function LoadingState({ label = 'Loading…' }: { label?: string }) {
  const { colors } = useTheme();
  return (
    <View style={styles.centered} accessibilityLiveRegion="polite">
      <ActivityIndicator color={colors.primary} />
      <Text style={[styles.centeredText, { color: colors.textMuted }]}>{label}</Text>
    </View>
  );
}

/**
 * Shown when a screen's data could not be read.
 *
 * Persistence failures are surfaced with a retry rather than an empty list, so
 * a database problem never looks like "you own nothing" (issues #4, #14).
 */
export function ErrorState({
  title = 'Something went wrong',
  message,
  onRetry,
}: {
  title?: string;
  message: string;
  onRetry?: () => void;
}) {
  const { colors } = useTheme();
  return (
    <View style={styles.centered} accessibilityLiveRegion="assertive">
      <Text style={[styles.errorTitle, { color: colors.text }]} accessibilityRole="header">
        {title}
      </Text>
      <Text style={[styles.centeredText, { color: colors.textMuted }]}>{message}</Text>
      {onRetry ? <Button label="Try again" onPress={onRetry} variant="secondary" /> : null}
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
    gap: spacing.md,
    padding: spacing.xl,
  },
  centeredText: {
    fontSize: 15,
    textAlign: 'center',
    lineHeight: 21,
  },
  errorTitle: {
    fontSize: 18,
    fontWeight: '700',
    textAlign: 'center',
  },
});
