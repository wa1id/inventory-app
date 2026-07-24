import { useColorScheme } from 'react-native';

/**
 * Palette options offered when creating a space.
 *
 * Deliberately small (issue #4 asks for "one of a small set of colors") and
 * each hue is distinguishable in both light and dark mode.
 */
export const SPACE_COLORS = [
  '#5B8DEF',
  '#2E9E4F',
  '#E4572E',
  '#B15BEF',
  '#E0A800',
  '#0F9BB0',
] as const;

export const SPACE_ICONS = ['🛋️', '🍳', '🛏️', '🚗', '🧰', '📚', '🧺', '🏠', '🪴', '🎒'] as const;

export const CONTAINER_ICONS: Record<string, string> = {
  box: '📦',
  drawer: '🗄️',
  shelf: '🗂️',
  cabinet: '🚪',
  bin: '🗑️',
  bag: '👜',
  crate: '🧰',
  other: '📥',
};

const light = {
  background: '#F6F7F9',
  surface: '#FFFFFF',
  surfaceAlt: '#EEF1F5',
  border: '#DDE2E9',
  text: '#12161C',
  textMuted: '#5A6675',
  primary: '#2F6FED',
  primaryText: '#FFFFFF',
  danger: '#C7351B',
  dangerSurface: '#FDECE8',
  success: '#1F8A4C',
  warning: '#8A5A00',
  warningSurface: '#FFF6E0',
  overlay: 'rgba(0,0,0,0.5)',
};

const dark: typeof light = {
  background: '#0F1115',
  surface: '#181C23',
  surfaceAlt: '#222831',
  border: '#2C333D',
  text: '#F2F4F7',
  textMuted: '#9AA6B5',
  primary: '#6699FF',
  primaryText: '#0B1220',
  danger: '#FF7A66',
  dangerSurface: '#3A1D18',
  success: '#5BD08A',
  warning: '#E8B44A',
  warningSurface: '#3A2E14',
  overlay: 'rgba(0,0,0,0.6)',
};

export type ThemeColors = typeof light;

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const radius = {
  sm: 8,
  md: 12,
  lg: 16,
  pill: 999,
} as const;

/**
 * Minimum interactive size.
 *
 * 48dp is the Android accessibility guideline and comfortably exceeds Apple's
 * 44pt, so one number satisfies both platforms (issue #8).
 */
export const MIN_TOUCH_TARGET = 48;

export function useTheme(): { colors: ThemeColors; isDark: boolean } {
  const scheme = useColorScheme();
  const isDark = scheme === 'dark';
  return { colors: isDark ? dark : light, isDark };
}
