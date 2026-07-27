import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

interface Option<T> {
  value: T;
  label: string;
}

interface ChoiceRowProps<T> {
  label: string;
  options: readonly Option<T>[];
  value: T;
  onChange: (value: T) => void;
}

/** Horizontally scrolling single-select used for icon, colour, and type. */
export function ChoiceRow<T extends string>({
  label,
  options,
  value,
  onChange,
}: ChoiceRowProps<T>) {
  const { colors } = useTheme();

  return (
    <View style={styles.container} accessibilityRole="radiogroup">
      <Text style={[styles.label, { color: colors.textMuted }]}>{label}</Text>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={styles.row}
      >
        {options.map((option) => {
          const selected = option.value === value;
          return (
            <Pressable
              key={option.value}
              onPress={() => onChange(option.value)}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
              accessibilityLabel={option.label}
              style={[
                styles.chip,
                {
                  backgroundColor: selected ? colors.primary : colors.surface,
                  borderColor: selected ? colors.primary : colors.border,
                },
              ]}
            >
              <Text
                style={[styles.chipText, { color: selected ? colors.primaryText : colors.text }]}
              >
                {option.label}
              </Text>
            </Pressable>
          );
        })}
      </ScrollView>
    </View>
  );
}

interface ColorRowProps {
  label: string;
  colors: readonly string[];
  value: string;
  onChange: (value: string) => void;
}

export function ColorRow({ label, colors: swatches, value, onChange }: ColorRowProps) {
  const { colors } = useTheme();

  return (
    <View style={styles.container} accessibilityRole="radiogroup">
      <Text style={[styles.label, { color: colors.textMuted }]}>{label}</Text>
      <View style={styles.row}>
        {swatches.map((swatch, index) => {
          const selected = swatch === value;
          return (
            <Pressable
              key={swatch}
              onPress={() => onChange(swatch)}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
              accessibilityLabel={`Colour ${index + 1}${selected ? ', selected' : ''}`}
              style={[
                styles.swatch,
                {
                  backgroundColor: swatch,
                  borderColor: selected ? colors.text : 'transparent',
                  borderWidth: selected ? 3 : 0,
                },
              ]}
            >
              {selected ? <Text style={styles.check}>✓</Text> : null}
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

interface TileRowProps<T> {
  label: string;
  options: readonly { value: T; glyph: string; label: string }[];
  value: T;
  onChange: (value: T) => void;
}

/**
 * Large glyph tiles for choices that are recognised by shape, not by word.
 *
 * Container types read faster as pictures than as the text chips `ChoiceRow`
 * renders, so the tile carries the glyph and only the selected option spells
 * its name out underneath — the same trade the reference app makes.
 */
export function TileRow<T extends string>({ label, options, value, onChange }: TileRowProps<T>) {
  const { colors } = useTheme();
  const selectedOption = options.find((option) => option.value === value);

  return (
    <View style={styles.container} accessibilityRole="radiogroup">
      <Text style={[styles.label, { color: colors.textMuted }]}>{label}</Text>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={styles.tileRow}
      >
        {options.map((option) => {
          const selected = option.value === value;
          return (
            <Pressable
              key={option.value}
              onPress={() => onChange(option.value)}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
              accessibilityLabel={option.label}
              testID={`tile-${option.value}`}
              style={[
                styles.tile,
                {
                  backgroundColor: colors.surface,
                  borderColor: selected ? colors.primary : colors.border,
                  borderWidth: selected ? 2 : 1,
                },
              ]}
            >
              <Text
                style={styles.tileGlyph}
                accessibilityElementsHidden
                importantForAccessibility="no"
              >
                {option.glyph}
              </Text>
            </Pressable>
          );
        })}
      </ScrollView>
      {selectedOption ? (
        <Text style={[styles.tileCaption, { color: colors.text }]}>{selectedOption.label}</Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: spacing.sm,
  },
  label: {
    fontSize: 13,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.sm,
  },
  chip: {
    minHeight: MIN_TOUCH_TARGET,
    minWidth: MIN_TOUCH_TARGET,
    paddingHorizontal: spacing.md,
    borderRadius: radius.pill,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  chipText: {
    fontSize: 16,
    fontWeight: '600',
  },
  tileRow: {
    flexDirection: 'row',
    gap: spacing.sm,
    paddingVertical: spacing.xs,
  },
  tile: {
    width: 72,
    height: 72,
    borderRadius: radius.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  tileGlyph: {
    fontSize: 34,
  },
  tileCaption: {
    fontSize: 14,
    fontWeight: '600',
  },
  swatch: {
    width: MIN_TOUCH_TARGET,
    height: MIN_TOUCH_TARGET,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
  },
  check: {
    color: '#FFFFFF',
    fontSize: 20,
    fontWeight: '700',
  },
});
