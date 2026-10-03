import { StyleSheet, View } from 'react-native';

import { safeColor } from '@/ui/color';
import { useTheme } from '@/ui/theme';

export interface SpacePipProps {
  color: string | null | undefined;
  /** 10 inline and on camera chrome, 12 in rows and picker headers, 14 on the where card. */
  size?: 10 | 12 | 14;
}

/**
 * The space's colour as a small dot before its name.
 *
 * The ring is a real border rather than an inset shadow so it shows on Android
 * 9 too; it keeps a white space visible on a white sheet. The name always
 * follows, so colour never carries meaning alone.
 */
export function SpacePip({ color, size = 12 }: SpacePipProps) {
  const { colors } = useTheme();
  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[
        styles.pip,
        {
          width: size,
          height: size,
          borderRadius: size / 2,
          backgroundColor: safeColor(color),
          borderColor: colors.pipRing,
        },
      ]}
    />
  );
}

const styles = StyleSheet.create({
  pip: {
    borderWidth: 1,
    flexShrink: 0,
  },
});
