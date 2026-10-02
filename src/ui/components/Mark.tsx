import { StyleSheet, View } from 'react-native';

import { useTheme } from '@/ui/theme';

const SIZES = {
  52: { width: 52, height: 46, radius: 10 },
  72: { width: 72, height: 64, radius: 14 },
} as const;

/**
 * The household mark: the desk's favicon drawn in Views, an ink box with a
 * strip of label tape across it. Decorative.
 */
export function Mark({ size = 52 }: { size?: 52 | 72 }) {
  const { colors } = useTheme();
  const box = SIZES[size];

  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[
        styles.box,
        {
          width: box.width,
          height: box.height,
          borderRadius: box.radius,
          backgroundColor: colors.ink,
        },
      ]}
    >
      <View
        style={[
          styles.tape,
          {
            top: box.height * 0.36,
            left: box.width * 0.2,
            right: box.width * 0.2,
            height: box.height * 0.3,
            backgroundColor: colors.tape,
          },
        ]}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  box: {
    borderCurve: 'continuous',
  },
  tape: {
    position: 'absolute',
    borderRadius: 3,
  },
});
