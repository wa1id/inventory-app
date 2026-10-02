import { Pressable, StyleSheet, View, type ColorValue } from 'react-native';

import { Icon, type IconName } from '@/ui/components/Icon';
import { rippleFor, useFocusRing, usesRipple } from '@/ui/components/PressFeedback';
import { MIN_TOUCH_TARGET, camera, radius, useTheme } from '@/ui/theme';

export interface IconButtonProps {
  icon: IconName;
  /** Required, and item-specific where it matters: "Edit Tool chest", not "Edit". */
  accessibilityLabel: string;
  onPress: () => void;
  onLongPress?: () => void;
  variant?: 'plain' | 'outlined' | 'chip' | 'camera';
  /** A toggle (torch, flash): announced as selected, drawn in the camera accent. */
  selected?: boolean;
  disabled?: boolean;
  accessibilityHint?: string;
  testID?: string;
  /** Overrides the variant's icon colour (the toast's dismiss uses `toastInk`). */
  iconColor?: ColorValue;
  iconSize?: number;
}

/**
 * An icon-only control. Whatever it looks like, the target is 48 × 48 (issue #8).
 *
 * - `plain`: header and toolbar buttons; a 40 pt pressed circle.
 * - `outlined`: the icon-only secondary button in bottom bars.
 * - `chip`: a small filled circle (clearing a search field).
 * - `camera`: chrome over the live picture, readable on any scene.
 */
export function IconButton({
  icon,
  accessibilityLabel,
  onPress,
  onLongPress,
  variant = 'plain',
  selected,
  disabled = false,
  accessibilityHint,
  testID,
  iconColor,
  iconSize,
}: IconButtonProps) {
  const { colors } = useTheme();
  const focus = useFocusRing();

  const defaultColor: string =
    variant === 'camera' ? (selected ? camera.accent : camera.ink) : colors.ink;
  const size = iconSize ?? (variant === 'chip' ? 16 : 24);

  return (
    <Pressable
      testID={testID}
      onPress={onPress}
      onLongPress={onLongPress}
      onFocus={focus.onFocus}
      onBlur={focus.onBlur}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      accessibilityHint={accessibilityHint}
      accessibilityState={{ disabled, selected }}
      android_ripple={
        variant === 'plain' || variant === 'chip'
          ? rippleFor(colors, { borderless: true, radius: 24 })
          : rippleFor(colors, {
              color: variant === 'camera' ? camera.chipPressed : undefined,
            })
      }
      style={[
        styles.target,
        variant === 'outlined'
          ? [styles.outlined, { backgroundColor: colors.sheet, borderColor: colors.control }]
          : null,
        variant === 'camera' ? [styles.round, { backgroundColor: camera.chip }] : null,
        { opacity: disabled ? 0.45 : 1 },
        focus.ringStyle,
      ]}
    >
      {({ pressed }) => {
        const showPressed = pressed && !usesRipple;
        return (
          <>
            {showPressed && variant === 'plain' ? (
              <View
                pointerEvents="none"
                style={[styles.pressedCircle, { backgroundColor: colors.pressed }]}
              />
            ) : null}
            {showPressed && (variant === 'outlined' || variant === 'camera') ? (
              <View
                pointerEvents="none"
                style={[
                  StyleSheet.absoluteFill,
                  variant === 'camera' ? styles.round : styles.outlinedRadius,
                  { backgroundColor: variant === 'camera' ? camera.chipPressed : colors.pressed },
                ]}
              />
            ) : null}
            {variant === 'chip' ? (
              <View
                style={[
                  styles.chip,
                  { backgroundColor: showPressed ? colors.selected : colors.sheet2 },
                ]}
              >
                <Icon name={icon} size={size} color={iconColor ?? defaultColor} />
              </View>
            ) : (
              <Icon
                name={icon}
                size={size}
                color={iconColor ?? defaultColor}
                strokeWidth={selected && variant !== 'camera' ? 2 : 1.75}
              />
            )}
          </>
        );
      }}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  target: {
    width: MIN_TOUCH_TARGET,
    height: MIN_TOUCH_TARGET,
    alignItems: 'center',
    justifyContent: 'center',
  },
  outlined: {
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  outlinedRadius: {
    borderRadius: radius.control,
  },
  round: {
    borderRadius: MIN_TOUCH_TARGET / 2,
  },
  pressedCircle: {
    position: 'absolute',
    width: 40,
    height: 40,
    borderRadius: 20,
  },
  chip: {
    width: 28,
    height: 28,
    borderRadius: 14,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
