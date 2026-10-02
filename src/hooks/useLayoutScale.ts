import { useWindowDimensions } from 'react-native';

import { NARROW_WIDTH, STACK_FONT_SCALE } from '@/ui/tokens';

/**
 * Whether layouts should stack rather than sit side by side.
 *
 * At large text sizes (and on the narrowest phones) a row's trailing control,
 * a two-button bar or a wide stepper no longer fits beside its text without
 * squeezing the text into a column a few letters wide. Stacking keeps the text
 * readable and every target full size (issue #8).
 */
export function useLayoutScale(): { fontScale: number; stacked: boolean } {
  const { fontScale, width } = useWindowDimensions();
  return { fontScale, stacked: fontScale >= STACK_FONT_SCALE || width < NARROW_WIDTH };
}

/** Size of an icon set inline with text: it grows with the text, up to 1.6×. */
export function inlineIconSize(base: number, fontScale: number): number {
  return Math.round(base * Math.min(Math.max(fontScale, 1), 1.6));
}
