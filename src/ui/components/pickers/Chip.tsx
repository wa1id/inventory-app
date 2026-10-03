import type { ReactNode } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { AppText } from '@/ui/components/AppText';
import { PressedOverlay, rippleFor, useFocusRing } from '@/ui/components/PressFeedback';
import { radius, space, useTheme } from '@/ui/theme';

export interface ChipProps {
  label: string;
  /** Without it the chip is a display tag; with it, a choice. */
  onPress?: () => void;
  selected?: boolean;
  leading?: ReactNode;
  testID?: string;
}

/**
 * A small pill: a tag on the item screen, or a tappable suggestion (recent
 * categories under the Category field). Selectable chips keep a 48 pt target
 * through `hitSlop` around their 40 pt pill.
 */
export function Chip({ label, onPress, selected = false, leading, testID }: ChipProps) {
  const { colors } = useTheme();
  const focus = useFocusRing();

  if (!onPress) {
    return (
      <View
        testID={testID}
        style={[
          styles.chip,
          styles.display,
          { backgroundColor: colors.sheet2, borderColor: colors.rule },
        ]}
      >
        {leading}
        <AppText variant="meta">{label}</AppText>
      </View>
    );
  }

  return (
    <Pressable
      testID={testID}
      onPress={onPress}
      onFocus={focus.onFocus}
      onBlur={focus.onBlur}
      hitSlop={4}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ selected }}
      android_ripple={rippleFor(colors)}
      style={[
        styles.chip,
        styles.selectable,
        selected
          ? { backgroundColor: colors.selected, borderColor: colors.ink, borderWidth: 2 }
          : { backgroundColor: colors.sheet, borderColor: colors.control, borderWidth: 1 },
        focus.ringStyle,
      ]}
    >
      {({ pressed }) => (
        <>
          <PressedOverlay pressed={pressed} radius={radius.pill} />
          {leading}
          <AppText variant="meta" weight={600}>
            {label}
          </AppText>
        </>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    gap: space.xs,
    borderRadius: radius.pill,
    overflow: 'hidden',
  },
  display: {
    borderWidth: 1,
    paddingVertical: space.xs,
    paddingHorizontal: 10,
  },
  selectable: {
    minHeight: 40,
    paddingHorizontal: space.md,
  },
});
