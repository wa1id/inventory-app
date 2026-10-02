import { useState } from 'react';
import type { LayoutChangeEvent } from 'react-native';

/**
 * The column gap that spreads fixed-width tiles across a row of `width`, so
 * full rows reach both edges of the column (no ragged gap at the end) and a
 * short last row stays aligned with the columns above it.
 *
 * As many columns fit as `minGap` allows, at most `columns`. Rounded down,
 * so rounding never pushes a row's last tile onto the next line. `minGap`
 * until the row is measured.
 */
export function spreadGap(width: number, tile: number, minGap: number, columns?: number): number {
  if (width <= 0) return minGap;
  const fit = Math.min(
    columns ?? Number.POSITIVE_INFINITY,
    Math.floor((width + minGap) / (tile + minGap)),
  );
  if (fit < 2) return minGap;
  return Math.max(minGap, Math.floor(((width - fit * tile) / (fit - 1)) * 10) / 10);
}

/** `spreadGap` for a wrapping row: put `onLayout` on the row and `columnGap` in its style. */
export function useSpreadGap(
  tile: number,
  minGap: number,
  columns?: number,
): { columnGap: number; onLayout: (event: LayoutChangeEvent) => void } {
  const [width, setWidth] = useState(0);
  return {
    columnGap: spreadGap(width, tile, minGap, columns),
    onLayout: (event) => setWidth(event.nativeEvent.layout.width),
  };
}
