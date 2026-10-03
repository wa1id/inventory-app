import { Pressable, StyleSheet, View } from 'react-native';

import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { PressedOverlay, rippleFor, useFocusRing } from '@/ui/components/PressFeedback';
import { MIN_TOUCH_TARGET, radius, space, useTheme } from '@/ui/theme';

export interface QuantityChipProps {
  /** The live, optimistic value from the row's `useSavedQuantity`. */
  quantity: number;
  itemName: string;
  itemId: string;
  expanded: boolean;
  onToggle: () => void;
}

/**
 * How many are left, on every row, and the way to change it.
 *
 * "×1" shows too, so there is always something to tap; at zero it says "None
 * left" in signal. Tapping opens plus and minus under the row: two taps to
 * change a count from a search result, without opening the item (`fe6e940`).
 */
export function QuantityChip({
  quantity,
  itemName,
  itemId,
  expanded,
  onToggle,
}: QuantityChipProps) {
  const { colors } = useTheme();
  const focus = useFocusRing();
  const empty = quantity === 0;

  return (
    <Pressable
      testID={`qty-chip-${itemId}`}
      onPress={onToggle}
      onFocus={focus.onFocus}
      onBlur={focus.onBlur}
      accessibilityRole="button"
      accessibilityLabel={strings.quantity.chipA11y(
        itemName,
        empty ? strings.quantity.noneLeftValue : String(quantity),
      )}
      accessibilityHint={strings.quantity.chipHint}
      accessibilityState={{ expanded }}
      android_ripple={rippleFor(colors, { borderless: true, radius: 24 })}
      style={[styles.target, focus.ringStyle]}
    >
      {({ pressed }) => (
        <View
          style={[
            styles.pill,
            {
              backgroundColor: empty ? colors.signalWash : colors.sheet,
              borderColor: expanded ? colors.ink : colors.control,
            },
            expanded ? styles.pillExpanded : null,
          ]}
        >
          <PressedOverlay pressed={pressed} radius={radius.pill} />
          <AppText variant="aside" tone={empty ? 'signal' : 'ink'} numberOfLines={1}>
            {empty ? strings.rows.noneLeft : strings.rows.times(quantity)}
          </AppText>
          {expanded ? (
            <View style={styles.chevron}>
              <Icon name="chevronDown" size={16} color={colors.ink} />
            </View>
          ) : null}
        </View>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  target: {
    minWidth: MIN_TOUCH_TARGET,
    minHeight: MIN_TOUCH_TARGET,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pill: {
    minHeight: 32,
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.xs,
    paddingHorizontal: space.md,
    borderWidth: 1,
    borderRadius: radius.pill,
    overflow: 'hidden',
  },
  pillExpanded: {
    borderWidth: 2,
    paddingHorizontal: space.md - 1,
  },
  chevron: {
    transform: [{ rotate: '180deg' }],
  },
});
