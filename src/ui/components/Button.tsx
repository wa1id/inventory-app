import {
  ActivityIndicator,
  Platform,
  Pressable,
  StyleSheet,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { isIconName, type IconName } from '@/ui/icons/glyphs';
import { delay } from '@/ui/motion';
import { AppText, toneColor, type TextTone } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { PressedOverlay, rippleFor, useFocusRing } from '@/ui/components/PressFeedback';
import { MIN_TOUCH_TARGET, radius, space, useTheme } from '@/ui/theme';

export type ButtonVariant = 'primary' | 'secondary' | 'quiet' | 'destructive';

/** @deprecated Pre-redesign names: `ghost` is `quiet`, `danger` is `destructive`. */
type LegacyButtonVariant = 'ghost' | 'danger';

export interface ButtonProps {
  label: string;
  onPress: () => void;
  variant?: ButtonVariant | LegacyButtonVariant;
  size?: 'md' | 'sm';
  /**
   * Leading glyph, decorative. Legacy call sites still pass an emoji string;
   * anything that is not a glyph name renders nothing until cleanup.
   */
  icon?: IconName | (string & {});
  fullWidth?: boolean;
  disabled?: boolean;
  loading?: boolean;
  /** Defaults to `label`; pass the item-specific form ("Move “Cordless drill”…"). */
  accessibilityLabel?: string;
  accessibilityHint?: string;
  testID?: string;
  /** Layout only, e.g. `flex` inside a bottom bar. */
  style?: StyleProp<ViewStyle>;
}

function resolveVariant(variant: ButtonVariant | LegacyButtonVariant): ButtonVariant {
  if (variant === 'ghost') return 'quiet';
  if (variant === 'danger') return 'destructive';
  return variant;
}

const TONE: Record<ButtonVariant, TextTone> = {
  primary: 'onInk',
  secondary: 'ink',
  quiet: 'ink',
  destructive: 'signal',
};

/**
 * The app's one button.
 *
 * Primary is solid ink, the only filled control on a screen. There is no
 * filled red button: destructive actions are quiet signal-coloured text at the
 * end of a screen and always lead to a confirm (the old white-on-coral danger
 * button measured 2.55:1). Labels wrap to two lines at large text and the
 * button grows rather than clipping (issue #8).
 */
export function Button({
  label,
  onPress,
  variant = 'primary',
  size = 'md',
  icon,
  fullWidth = false,
  disabled = false,
  loading = false,
  accessibilityLabel,
  accessibilityHint,
  testID,
  style,
}: ButtonProps) {
  const { colors } = useTheme();
  const focus = useFocusRing();
  const kind = resolveVariant(variant);
  const tone = TONE[kind];
  const foreground = toneColor(colors, tone);
  // The label stays put while busy, so there is no width jump and screen
  // readers still hear the action; a spinner joins it only if the wait is real.
  const showSpinner = useDelayedFlag(loading, delay.spinner);
  const small = size === 'sm';
  const iconSize = small ? 18 : 20;
  const glyph = isIconName(icon) ? icon : null;
  const primary = kind === 'primary';

  return (
    <Pressable
      testID={testID}
      onPress={onPress}
      onFocus={focus.onFocus}
      onBlur={focus.onBlur}
      disabled={disabled || loading}
      hitSlop={small ? 4 : undefined}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityHint={accessibilityHint}
      accessibilityState={{ disabled, busy: loading }}
      android_ripple={primary ? undefined : rippleFor(colors)}
      style={({ pressed }) => [
        styles.base,
        small ? styles.small : styles.medium,
        kind === 'secondary'
          ? { backgroundColor: colors.sheet, borderColor: colors.control, borderWidth: 1 }
          : null,
        primary ? { backgroundColor: pressed ? colors.inkPressed : colors.ink } : null,
        { alignSelf: fullWidth ? 'stretch' : 'flex-start', opacity: disabled ? 0.45 : 1 },
        focus.ringStyle,
        style,
      ]}
    >
      {({ pressed }) => (
        <>
          {primary ? null : <PressedOverlay pressed={pressed} radius={radius.control} />}
          <View style={styles.content}>
            {showSpinner ? (
              <ActivityIndicator size="small" color={foreground} />
            ) : glyph ? (
              <Icon name={glyph} size={iconSize} color={foreground} />
            ) : null}
            <AppText
              variant={small ? 'label' : 'button'}
              tone={tone}
              numberOfLines={2}
              center
              style={styles.label}
            >
              {label}
            </AppText>
          </View>
        </>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    borderRadius: radius.control,
    borderCurve: 'continuous',
    justifyContent: 'center',
    alignItems: 'center',
    overflow: Platform.OS === 'android' ? 'hidden' : 'visible',
  },
  medium: {
    minHeight: MIN_TOUCH_TARGET,
    paddingHorizontal: space.lg,
    paddingVertical: space.sm + 2,
  },
  small: {
    minHeight: 40,
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
  },
  content: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.sm,
  },
  label: {
    flexShrink: 1,
  },
});
