import { StyleSheet, View } from 'react-native';

import type { IconName } from '@/ui/icons/glyphs';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon } from '@/ui/components/Icon';
import { space, useTheme } from '@/ui/theme';

export interface EmptyStateAction {
  label: string;
  onPress: () => void;
  icon?: IconName;
  /** The action is running: the button shows its spinner and ignores presses. */
  loading?: boolean;
  testID?: string;
}

export interface EmptyStateProps {
  title: string;
  body: string;
  /** A line icon in a soft circle. */
  icon?: IconName;
  action?: EmptyStateAction;
  secondary?: EmptyStateAction;
  align?: 'start' | 'center';
  testID?: string;
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
}: EmptyStateProps) {
  const { colors } = useTheme();
  const centered = align === 'center';

  return (
    <View style={[styles.container, centered ? styles.centered : null]} testID={testID}>
      {icon ? (
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
      {action || secondary ? (
        <View style={[styles.actions, centered ? styles.centered : null]}>
          {action ? (
            <Button
              label={action.label}
              onPress={action.onPress}
              icon={action.icon}
              loading={action.loading}
              testID={action.testID}
            />
          ) : null}
          {secondary ? (
            // Quiet under a primary, lined up with the text; on its own it is
            // the next step, so it is bordered rather than loose text.
            <Button
              label={secondary.label}
              onPress={secondary.onPress}
              icon={secondary.icon}
              loading={secondary.loading}
              testID={secondary.testID}
              variant={action ? 'quiet' : 'secondary'}
              flush={!centered}
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
