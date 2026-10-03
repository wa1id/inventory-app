import { useEffect } from 'react';
import { AccessibilityInfo, Platform, StyleSheet, View } from 'react-native';

import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon } from '@/ui/components/Icon';
import { describeError } from '@/ui/errors';
import { space, useTheme } from '@/ui/theme';

type ErrorContext = Parameters<typeof describeError>[1];
type ErrorSubject = Parameters<typeof describeError>[2];

export interface ErrorStateProps {
  /** What was thrown (or the `null` a read returned). Described in plain words, never shown raw. */
  cause?: unknown;
  context?: ErrorContext;
  subject?: ErrorSubject;
  /** Overrides the described title (conflicts, where the screen knows the sentence). */
  title?: string;
  /**
   * Overrides the described body with the screen's own sentence from `strings`
   * (the boot gate's reassurance). Never an `Error.message`: raw codes must not
   * reach the screen.
   */
  body?: string;
  /** Always the query's own `reload`, never a state no-op. */
  onRetry?: () => void;
  secondary?: { label: string; onPress: () => void; testID?: string };
  testID?: string;
}

/**
 * Shown when a screen's data could not be read.
 *
 * Persistence failures are surfaced with a retry rather than an empty list, so
 * a database problem never looks like "you own nothing" (issues #4, #14). The
 * words come from `describeError`, so raw codes and `Error.message` never
 * reach the screen; the copy says what happened and what is still safe.
 */
export function ErrorState({
  cause,
  context,
  subject,
  title,
  body: bodyOverride,
  onRetry,
  secondary,
  testID,
}: ErrorStateProps) {
  const { colors } = useTheme();
  const described =
    cause !== undefined || title === undefined || bodyOverride === undefined
      ? describeError(cause, context, subject)
      : null;
  const heading = title ?? described?.title ?? '';
  const body = bodyOverride ?? described?.body ?? '';

  // Android reads the assertive live region; iOS needs the title announced.
  useEffect(() => {
    if (Platform.OS === 'ios' && heading) AccessibilityInfo.announceForAccessibility(heading);
  }, [heading]);

  return (
    <View style={styles.container} accessibilityLiveRegion="assertive" testID={testID}>
      <View style={[styles.iconCircle, { backgroundColor: colors.sheet2 }]}>
        <Icon name="refresh" size={28} color={colors.graphite} />
      </View>
      <AppText variant="heading">{heading}</AppText>
      {body ? (
        <AppText variant="body" tone="graphite" style={styles.body}>
          {body}
        </AppText>
      ) : null}
      {onRetry || secondary ? (
        <View style={styles.actions}>
          {onRetry ? (
            <Button
              label={strings.common.tryAgain}
              onPress={onRetry}
              icon="refresh"
              variant="secondary"
            />
          ) : null}
          {secondary ? (
            <Button
              label={secondary.label}
              onPress={secondary.onPress}
              testID={secondary.testID}
              variant="quiet"
            />
          ) : null}
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    paddingVertical: space.xxxl,
    paddingHorizontal: space.lg,
    gap: space.sm,
    alignItems: 'flex-start',
  },
  iconCircle: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: 'center',
    justifyContent: 'center',
  },
  body: {
    maxWidth: 420,
  },
  actions: {
    marginTop: space.md,
    gap: space.sm,
    alignItems: 'flex-start',
  },
});
