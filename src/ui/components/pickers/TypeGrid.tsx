import { Pressable, StyleSheet, View, useWindowDimensions } from 'react-native';

import { CONTAINER_VISUAL_TYPES, type ContainerVisualType } from '@/db/types';
import { useSpreadGap } from '@/hooks/useSpreadGap';
import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { haptics } from '@/ui/haptics';
import { NARROW_WIDTH, TYPE_ICON, space, useTheme } from '@/ui/theme';

const TILE = 72;

export interface TypeGridProps {
  label: string;
  value: ContainerVisualType;
  onChange: (value: ContainerVisualType) => void;
}

/**
 * Container types as large line-icon tiles, four to a row (three on the
 * narrowest phones), flush with both edges of the form. Types read faster as
 * pictures than as words, so only the selected tile spells its name out
 * underneath (PR #28); every tile still announces its name. Every tile keeps
 * room for its name, so choosing one never moves the others under the finger.
 */
export function TypeGrid({ label, value, onChange }: TypeGridProps) {
  const { colors } = useTheme();
  const { width } = useWindowDimensions();
  const spread = useSpreadGap(TILE, space.sm, width < NARROW_WIDTH ? 3 : 4);

  return (
    <View style={styles.container}>
      <AppText variant="label">{label}</AppText>
      <View
        onLayout={spread.onLayout}
        style={[styles.grid, { columnGap: spread.columnGap }]}
        accessibilityRole="radiogroup"
        accessibilityLabel={label}
      >
        {CONTAINER_VISUAL_TYPES.map((type) => {
          const selected = type === value;
          const name = strings.entities.typeNames[type] ?? type;
          return (
            <View key={type} style={styles.cell}>
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
                // An unselected tile's edge is a control's (3:1), not a decorative rule.
                style={[
                  styles.tile,
                  selected
                    ? { backgroundColor: colors.selected, borderColor: colors.ink, borderWidth: 2 }
                    : {
                        backgroundColor: colors.sheet,
                        borderColor: colors.control,
                        borderWidth: 1,
                      },
                ]}
              >
                <Icon name={TYPE_ICON[type] ?? 'other'} size={28} color={colors.ink} />
              </Pressable>
              <AppText
                variant="caption"
                weight={600}
                center
                accessibilityElementsHidden
                importantForAccessibility="no"
                style={selected ? null : styles.hidden}
              >
                {name}
              </AppText>
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
    width: TILE,
    alignItems: 'center',
    gap: space.xs,
  },
  hidden: {
    opacity: 0,
  },
  tile: {
    width: TILE,
    height: TILE,
    borderRadius: 10,
    borderCurve: 'continuous',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
