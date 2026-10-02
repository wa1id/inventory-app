import { memo } from 'react';
import type { ColorValue } from 'react-native';
import Svg from 'react-native-svg';

import { GLYPHS, type IconName } from '@/ui/icons/glyphs';
import { useTheme } from '@/ui/theme';

export type { IconName } from '@/ui/icons/glyphs';

export interface IconProps {
  name: IconName;
  /** 16, 20, 24 or 28 in chrome; inline icons scale with the text. */
  size?: number;
  color?: ColorValue;
  /** In viewBox units, so it scales with the size, as on the desk. Active tabs use 2. */
  strokeWidth?: number;
}

/**
 * A line icon from the desk's set.
 *
 * Always decorative: the control around an icon owns the label, so the icon is
 * hidden from screen readers and never announced twice.
 */
export const Icon = memo(function Icon({ name, size = 24, color, strokeWidth = 1.75 }: IconProps) {
  const { colors } = useTheme();

  return (
    <Svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke={color ?? colors.ink}
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
    >
      {GLYPHS[name]}
    </Svg>
  );
});
