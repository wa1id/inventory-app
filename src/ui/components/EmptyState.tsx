import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/ui/components/Button';
import { spacing, useTheme } from '@/ui/theme';

interface EmptyStateProps {
  icon: string;
  title: string;
  body: string;
  actionLabel?: string;
  onAction?: () => void;
  secondaryActionLabel?: string;
  onSecondaryAction?: () => void;
  testID?: string;
}

/**
 * Every list in the app routes its zero-state through here so an empty screen
 * always explains itself and offers the next step (issue #12).
 */
export function EmptyState({
  icon,
  title,
  body,
  actionLabel,
  onAction,
  secondaryActionLabel,
  onSecondaryAction,
  testID,
}: EmptyStateProps) {
  const { colors } = useTheme();

  return (
    <View style={styles.container} testID={testID}>
      <Text style={styles.icon} accessibilityElementsHidden importantForAccessibility="no">
        {icon}
      </Text>
      <Text style={[styles.title, { color: colors.text }]} accessibilityRole="header">
        {title}
      </Text>
      <Text style={[styles.body, { color: colors.textMuted }]}>{body}</Text>
      {actionLabel && onAction ? (
        <View style={styles.action}>
          <Button label={actionLabel} onPress={onAction} />
        </View>
      ) : null}
      {secondaryActionLabel && onSecondaryAction ? (
        <View style={styles.secondaryAction}>
          <Button label={secondaryActionLabel} onPress={onSecondaryAction} variant="ghost" />
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    paddingHorizontal: spacing.xl,
    paddingVertical: spacing.xxl,
    gap: spacing.sm,
  },
  icon: {
    fontSize: 44,
    marginBottom: spacing.sm,
  },
  title: {
    fontSize: 18,
    fontWeight: '700',
    textAlign: 'center',
  },
  body: {
    fontSize: 15,
    lineHeight: 21,
    textAlign: 'center',
  },
  action: {
    marginTop: spacing.lg,
  },
  secondaryAction: {
    marginTop: spacing.xs,
  },
});
