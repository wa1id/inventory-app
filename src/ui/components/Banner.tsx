import { useEffect } from 'react';
import { AccessibilityInfo, Platform, StyleSheet, View } from 'react-native';

import { inlineIconSize, useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon, type IconName } from '@/ui/components/Icon';
import { IconButton } from '@/ui/components/IconButton';
import { radius, space, useTheme } from '@/ui/theme';

export interface BannerAction {
  label: string;
  onPress: () => void;
  accessibilityHint?: string;
  testID?: string;
}

export interface BannerProps {
  tone: 'info' | 'warning';
  /** Defaults to `info` or `warning` by tone. */
  icon?: IconName;
  title?: string;
  message: string;
  action?: BannerAction;
  /**
   * A second, quieter choice after `action` (Home's "Not now"). With one, the
   * main action becomes the bordered button so the two are told apart.
   */
  secondary?: BannerAction;
  onDismiss?: () => void;
  /**
   * How the banner announces itself. `off` for copy that follows typing
   * keystroke by keystroke, which would otherwise talk over the person typing.
   */
  live?: 'polite' | 'assertive' | 'off';
  testID?: string;
}

/**
 * An inline notice. Info is quiet (`sheet2`); warning is the one place signal
 * colour fills a surface, and even then the body stays ink. The action is a
 * quiet button at the end that drops under the message when it does not fit.
 */
export function Banner({
  tone,
  icon,
  title,
  message,
  action,
  secondary,
  onDismiss,
  live = 'polite',
  testID,
}: BannerProps) {
  const { colors } = useTheme();
  const { fontScale } = useLayoutScale();
  const warning = tone === 'warning';
  const announcement = title ? `${title}. ${message}` : message;

  // Android has live regions; iOS needs telling when the banner arrives or its
  // copy changes (never on a plain re-render).
  useEffect(() => {
    if (Platform.OS === 'ios' && live !== 'off') {
      AccessibilityInfo.announceForAccessibility(announcement);
    }
  }, [announcement, live]);

  return (
    <View
      testID={testID}
      accessibilityLiveRegion={live === 'off' ? 'none' : live}
      style={[styles.banner, { backgroundColor: warning ? colors.signalWash : colors.sheet2 }]}
    >
      <View style={styles.icon}>
        <Icon
          name={icon ?? (warning ? 'warning' : 'info')}
          size={inlineIconSize(20, fontScale)}
          color={warning ? colors.signal : colors.ink}
        />
      </View>
      <View style={styles.main}>
        <View style={styles.text}>
          {title ? (
            <AppText variant="name" tone={warning ? 'signal' : 'ink'} weight={700}>
              {title}
            </AppText>
          ) : null}
          <AppText variant="meta">{message}</AppText>
        </View>
        {action ? (
          <Button
            label={action.label}
            onPress={action.onPress}
            accessibilityHint={action.accessibilityHint}
            testID={action.testID}
            variant={secondary ? 'secondary' : 'quiet'}
            size="sm"
          />
        ) : null}
        {secondary ? (
          <Button
            label={secondary.label}
            onPress={secondary.onPress}
            accessibilityHint={secondary.accessibilityHint}
            testID={secondary.testID}
            variant="quiet"
            size="sm"
          />
        ) : null}
      </View>
      {onDismiss ? (
        <IconButton
          icon="close"
          iconSize={20}
          accessibilityLabel={strings.common.dismiss}
          onPress={onDismiss}
        />
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  banner: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: space.md,
    paddingVertical: space.md,
    paddingStart: 14,
    paddingEnd: 14,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  icon: {
    paddingTop: 1,
  },
  main: {
    flex: 1,
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    columnGap: space.sm,
    rowGap: space.xs,
  },
  text: {
    flexGrow: 1,
    flexBasis: 180,
    gap: space.xxs,
  },
});
