import { Pressable, StyleSheet, View } from 'react-native';

import { useSpreadGap } from '@/hooks/useSpreadGap';
import { strings } from '@/i18n/strings';
import { safeColor } from '@/ui/color';
import { AppText } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { haptics } from '@/ui/haptics';
import { MIN_TOUCH_TARGET, onColor, space, useTheme } from '@/ui/theme';

export interface SwatchPickerProps {
  label: string;
  colors: readonly string[];
  value: string;
  onChange: (value: string) => void;
}

function sameColor(a: string, b: string): boolean {
  return safeColor(a) === safeColor(b);
}

/**
 * A space's colour. Every swatch is announced by name ("Amber"; the radio
 * state adds "selected") rather than "Colour 5", and the check on the
 * selected one uses `onColor`, so it reads on every palette entry (the old
 * white check on amber was 2.15:1). A stored colour outside the palette, from
 * an older build or the desk, comes first as the selected "Current colour",
 * so editing a space never silently changes it. The swatches spread to the
 * column's full width.
 */
export function SwatchPicker({ label, colors: palette, value, onChange }: SwatchPickerProps) {
  const { colors } = useTheme();
  const listed = palette.some((swatch) => sameColor(swatch, value));
  const swatches = listed ? palette : [value, ...palette];
  const spread = useSpreadGap(MIN_TOUCH_TARGET, space.xs);

  return (
    <View style={styles.container}>
      <AppText variant="label">{label}</AppText>
      <View
        onLayout={spread.onLayout}
        style={[styles.row, { columnGap: spread.columnGap }]}
        accessibilityRole="radiogroup"
        accessibilityLabel={label}
      >
        {swatches.map((swatch, index) => {
          const selected = listed ? sameColor(swatch, value) : index === 0;
          const fill = safeColor(swatch);
          const name =
            !listed && index === 0
              ? strings.entities.currentColour
              : (strings.entities.colourNames[fill] ?? strings.entities.currentColour);
          return (
            <Pressable
              key={`${swatch}-${index}`}
              onPress={() => {
                if (selected) return;
                haptics.choice();
                onChange(swatch);
              }}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
              accessibilityLabel={name}
              testID={`space-colour-${fill}`}
              style={styles.target}
            >
              <View
                style={[
                  styles.swatch,
                  { backgroundColor: fill, borderColor: colors.pipRing },
                  selected ? [styles.selectedRing, { outlineColor: colors.ink }] : null,
                ]}
              >
                {selected ? <Icon name="check" size={20} color={onColor(fill)} /> : null}
              </View>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  // Solid is the native default, but web draws no outline without it.
  selectedRing: {
    outlineWidth: 2,
    outlineOffset: 2,
    outlineStyle: 'solid',
  },
  container: {
    gap: space.sm,
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    rowGap: space.xs,
  },
  target: {
    width: MIN_TOUCH_TARGET,
    height: MIN_TOUCH_TARGET,
    alignItems: 'center',
    justifyContent: 'center',
  },
  swatch: {
    width: 44,
    height: 44,
    borderRadius: 22,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
