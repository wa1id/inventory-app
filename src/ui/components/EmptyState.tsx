import { StyleSheet, View } from 'react-native';

import { isIconName, type IconName } from '@/ui/icons/glyphs';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon } from '@/ui/components/Icon';
import { space, useTheme } from '@/ui/theme';

export interface EmptyStateAction {
  label: string;
  onPress: () => void;
  icon?: IconName;
  testID?: string;
}

export interface EmptyStateProps {
  title: string;
  body: string;
  /** A line icon in a soft circle. Legacy emoji strings are ignored. */
  icon?: IconName | (string & {});
  action?: EmptyStateAction;
  secondary?: Omit<EmptyStateAction, 'icon'>;
  align?: 'start' | 'center';
  testID?: string;
  /** @deprecated Use `action`. */
  actionLabel?: string;
  /** @deprecated Use `action`. */
  onAction?: () => void;
  /** @deprecated Use `secondary`. */
  secondaryActionLabel?: string;
  /** @deprecated Use `secondary`. */
  onSecondaryAction?: () => void;
}

/**
 * Every list in the app routes its zero-state through here so an empty screen
 * always explains itself and offers the next step (issue #12).
 *
 * Placed at the top and left-aligned, as on the desk, rather than floating in
 * the middle: it reads calmly and survives the largest text sizes.
 */
export function EmptyState({
  title,
  body,
  icon,
  action,
  secondary,
  align = 'start',
  testID,
  actionLabel,
  onAction,
  secondaryActionLabel,
  onSecondaryAction,
}: EmptyStateProps) {
  const { colors } = useTheme();
  const primary =
    action ?? (actionLabel && onAction ? { label: actionLabel, onPress: onAction } : undefined);
  const quiet =
    secondary ??
    (secondaryActionLabel && onSecondaryAction
      ? { label: secondaryActionLabel, onPress: onSecondaryAction }
      : undefined);
  const centered = align === 'center';

  return (
    <View style={[styles.container, centered ? styles.centered : null]} testID={testID}>
      {isIconName(icon) ? (
        <View style={[styles.iconCircle, { backgroundColor: colors.sheet2 }]}>
          <Icon name={icon} size={28} color={colors.graphite} />
        </View>
      ) : null}
      <AppText variant="heading" center={centered}>
        {title}
      </AppText>
      <AppText variant="body" tone="graphite" center={centered} style={styles.body}>
        {body}
      </AppText>
      {primary || quiet ? (
        <View style={[styles.actions, centered ? styles.centered : null]}>
          {primary ? (
            <Button
              label={primary.label}
              onPress={primary.onPress}
              icon={primary.icon}
              testID={primary.testID}
            />
          ) : null}
          {quiet ? (
            <Button
              label={quiet.label}
              onPress={quiet.onPress}
              testID={quiet.testID}
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
  centered: {
    alignItems: 'center',
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
