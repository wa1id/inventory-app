import { useState } from 'react';
import {
  Platform,
  StyleSheet,
  View,
  type PressableAndroidRippleConfig,
  type ViewStyle,
} from 'react-native';

import { useTheme, type ThemeColors } from '@/ui/theme';

/**
 * Press and focus feedback shared by every pressable, so a row, a tile and a
 * quiet button all answer a touch the same way: a translucent overlay on iOS,
 * the system ripple on Android.
 */
export const usesRipple = Platform.OS === 'android';

/** `android_ripple` for a pressable, or undefined on iOS. */
export function rippleFor(
  colors: ThemeColors,
  options: { borderless?: boolean; radius?: number; color?: string } = {},
): PressableAndroidRippleConfig | undefined {
  if (!usesRipple) return undefined;
  return {
    color: options.color ?? colors.ripple,
    foreground: !options.borderless,
    borderless: options.borderless ?? false,
    radius: options.radius,
  };
}

/**
 * The iOS pressed state: the `pressed` token laid over whatever fill the
 * control has, under its content. Render it first inside the pressable.
 */
export function PressedOverlay({ pressed, radius }: { pressed: boolean; radius?: number }) {
  const { colors } = useTheme();
  if (!pressed || usesRipple) return null;
  return (
    <View
      pointerEvents="none"
      style={[
        StyleSheet.absoluteFill,
        { backgroundColor: colors.pressed, borderRadius: radius ?? 0 },
      ]}
    />
  );
}

/**
 * A 2 pt ink outline while a hardware keyboard or Switch Control has focus.
 * `Pressable`'s state callback does not report focus, so it is tracked here.
 */
export function useFocusRing(): {
  onFocus: () => void;
  onBlur: () => void;
  ringStyle: ViewStyle | null;
} {
  const { colors } = useTheme();
  const [focused, setFocused] = useState(false);
  return {
    onFocus: () => setFocused(true),
    onBlur: () => setFocused(false),
    ringStyle: focused
      ? { outlineWidth: 2, outlineColor: colors.ink, outlineOffset: 2, outlineStyle: 'solid' }
      : null,
  };
}
