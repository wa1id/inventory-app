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
