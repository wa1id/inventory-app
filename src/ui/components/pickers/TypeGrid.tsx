import { Pressable, StyleSheet, View, useWindowDimensions } from 'react-native';

import { CONTAINER_VISUAL_TYPES, type ContainerVisualType } from '@/db/types';
import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { haptics } from '@/ui/haptics';
import { NARROW_WIDTH, TYPE_ICON, space, useTheme } from '@/ui/theme';

export interface TypeGridProps {
  label: string;
  value: ContainerVisualType;
  onChange: (value: ContainerVisualType) => void;
}

/**
 * Container types as large line-icon tiles, four to a row (three on the
 * narrowest phones). Types read faster as pictures than as words, so only the
 * selected tile spells its name out underneath (PR #28); every tile still
 * announces its name.
 */
export function TypeGrid({ label, value, onChange }: TypeGridProps) {
  const { colors } = useTheme();
  const { width } = useWindowDimensions();
  const basis = width < NARROW_WIDTH ? '33.33%' : '25%';

  return (
    <View style={styles.container}>
      <AppText variant="label">{label}</AppText>
      <View style={styles.grid} accessibilityRole="radiogroup" accessibilityLabel={label}>
        {CONTAINER_VISUAL_TYPES.map((type) => {
          const selected = type === value;
          const name = strings.entities.typeNames[type] ?? type;
          return (
            <View key={type} style={[styles.cell, { flexBasis: basis }]}>
              <Pressable
                onPress={() => {
                  if (selected) return;
                  haptics.choice();
                  onChange(type);
                }}
                accessibilityRole="radio"
                accessibilityState={{ selected }}
                accessibilityLabel={name}
                testID={`tile-${type}`}
                style={[
                  styles.tile,
                  selected
                    ? { backgroundColor: colors.selected, borderColor: colors.ink, borderWidth: 2 }
                    : { backgroundColor: colors.sheet, borderColor: colors.rule, borderWidth: 1 },
                ]}
              >
                <Icon name={TYPE_ICON[type] ?? 'other'} size={28} color={colors.ink} />
              </Pressable>
              {selected ? (
                <AppText
                  variant="caption"
                  weight={600}
                  center
                  accessibilityElementsHidden
                  importantForAccessibility="no"
                >
                  {name}
                </AppText>
              ) : null}
            </View>
          );
        })}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: space.sm,
  },
  grid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    rowGap: space.md,
  },
  cell: {
    alignItems: 'center',
    gap: space.xs,
  },
  tile: {
    width: 72,
    height: 72,
    borderRadius: 10,
    borderCurve: 'continuous',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
