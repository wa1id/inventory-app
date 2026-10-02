import { useColorScheme } from 'react-native';

import type { ContainerVisualType } from '@/db/types';
import type { IconName } from '@/ui/icons/glyphs';
import { darkColors, lightColors, type ColorTokens } from '@/ui/tokens';

export {
  BOTTOM_BAR_PADDING,
  CONTENT_MAX_WIDTH,
  GUTTER,
  NARROW_WIDTH,
  OPTION_MIN,
  ROW_GAP,
  ROW_MIN,
  ROW_MIN_PHOTO,
  ROW_PADDING,
  STACK_FONT_SCALE,
  TAB_BAR_CONTENT,
  THUMB,
  THUMB_DETAIL,
  THUMB_PHOTO,
  THUMB_SMALL,
  camera,
  fixed,
  radius,
  shadowFloat,
  space,
  type ColorTokens,
} from '@/ui/tokens';

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

/**
 * One-tap starting points offered above the custom-name field.
 *
 * The reference app's fastest path to a space costs zero typing, which matters
 * because most people set up several spaces back to back. Each preset carries
 * its own icon and colour so the tile grid stays legible without asking the
 * user to make two cosmetic decisions before they have any content.
 */
export const SPACE_PRESETS = [
  { name: 'Garage', icon: '🚗', color: SPACE_COLORS[0] },
  { name: 'Wardrobe', icon: '👕', color: SPACE_COLORS[3] },
  { name: 'Loft', icon: '🏠', color: SPACE_COLORS[2] },
  { name: 'Cellar', icon: '🚪', color: SPACE_COLORS[4] },
] as const;

const ON_LIGHT = '#12161C';
const ON_DARK = '#FFFFFF';

/** WCAG relative luminance of a hex colour. */
function luminance(hex: string): number {
  const value = hex.replace('#', '');
  const full =
    value.length === 3
      ? value
          .split('')
          .map((c) => c + c)
          .join('')
      : value;
  const channel = (offset: number) => {
    const srgb = parseInt(full.slice(offset, offset + 2), 16) / 255;
    return srgb <= 0.03928 ? srgb / 12.92 : ((srgb + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
}

/**
 * Readable foreground for an arbitrary space colour.
 *
 * Space tiles and headers fill with the user's colour, so label contrast
 * depends on that choice rather than the theme. Rather than flipping at a
 * guessed lightness, this compares the actual WCAG contrast ratio of both
 * candidates and returns the better one — the mid-tone blues and teals in the
 * palette look like they want white text but measure far better with dark
 * (3.2:1 against 5.6:1 for the default blue), which is the difference between
 * failing and passing AA (issue #8).
 */
export function onColor(hex: string): typeof ON_DARK | typeof ON_LIGHT {
  const background = luminance(hex);
  const ratio = (a: number, b: number) => (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);

  return ratio(luminance(ON_DARK), background) >= ratio(luminance(ON_LIGHT), background)
    ? ON_DARK
    : ON_LIGHT;
}

/**
 * Container types are line icons of the same name. Typed as a plain record so
 * a stored type this build does not know falls back with `?? 'other'`.
 */
export const TYPE_ICON: Record<string, IconName> = {
  box: 'box',
  drawer: 'drawer',
  shelf: 'shelf',
  cabinet: 'cabinet',
  bin: 'bin',
  bag: 'bag',
  crate: 'crate',
  other: 'other',
} satisfies Record<ContainerVisualType, IconName>;

/** The colours `useTheme()` returns: the desk's tokens for one scheme. */
export type ThemeColors = ColorTokens;

/**
 * Minimum interactive size.
 *
 * 48dp is the Android accessibility guideline and comfortably exceeds Apple's
 * 44pt, so one number satisfies both platforms (issue #8).
 */
export const MIN_TOUCH_TARGET = 48;

/**
 * Colours for the current scheme.
 *
 * Follows the system setting; there is no in-app override.
 */
export function useTheme(): { colors: ThemeColors; isDark: boolean } {
  const scheme = useColorScheme();
  const isDark = scheme === 'dark';
  return { colors: isDark ? darkColors : lightColors, isDark };
}
