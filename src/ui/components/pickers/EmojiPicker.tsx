import { Pressable, StyleSheet, View } from 'react-native';

import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { SpaceTile } from '@/ui/components/SpaceTile';
import { haptics } from '@/ui/haptics';
import { MIN_TOUCH_TARGET, SPACE_PRESETS, radius, space, useTheme } from '@/ui/theme';

export interface EmojiPickerProps {
  label: string;
  options: readonly string[];
  value: string;
  onChange: (value: string) => void;
  /** The space's colour, so each choice is previewed as it will look. */
  color: string;
}

/**
 * A space's icon, as a wrapping grid of tiles tinted in the chosen colour
 * (no horizontal scroller hiding choices off screen). The presets' icons are
 * offered too, so a Wardrobe made from a preset can be edited back to its
 * shirt, and a stored icon that is in neither list comes first, selected.
 * Each tile is announced by name ("Toolbox"), not by its emoji description.
 */
export function EmojiPicker({ label, options, value, onChange, color }: EmojiPickerProps) {
  const { colors } = useTheme();
  const offered = [
    ...options,
    ...SPACE_PRESETS.map((preset) => preset.icon).filter((icon) => !options.includes(icon)),
  ];
  const choices = offered.includes(value) || !value.trim() ? offered : [value, ...offered];

  return (
    <View style={styles.container}>
      <AppText variant="label">{label}</AppText>
      <View style={styles.grid} accessibilityRole="radiogroup" accessibilityLabel={label}>
        {choices.map((icon, index) => {
          const selected = icon === value;
          const name = strings.entities.iconNames[icon] ?? strings.entities.currentIcon;
          return (
            <Pressable
              key={icon}
              onPress={() => {
                if (selected) return;
                haptics.choice();
                onChange(icon);
              }}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
              accessibilityLabel={name}
              testID={`space-icon-${index}`}
              style={[
                styles.target,
                selected ? [styles.selectedRing, { outlineColor: colors.ink }] : null,
              ]}
            >
              <SpaceTile icon={icon} color={color} size={48} />
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
  grid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: space.sm,
  },
  target: {
    minWidth: MIN_TOUCH_TARGET,
    minHeight: MIN_TOUCH_TARGET,
    borderRadius: radius.control + 1,
  },
});
