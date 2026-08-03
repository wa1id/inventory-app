/**
 * Sizing rules for stored photos.
 *
 * Deliberately imports nothing native, so the arithmetic that decides how large
 * every photo in the app ends up is testable in plain Node rather than only on
 * a device — the same reason `services/config.ts` is kept import-free.
 *
 * Photos are the only thing in this app that grows without bound, so the size
 * of one is the size of the whole app at scale: a few hundred items is the
 * difference between tens and hundreds of megabytes, on the device and in the
 * backup bucket both.
 */

/**
 * Longest edge of a stored photo, whichever way it is turned.
 *
 * 1400 rather than 1600 because nothing downstream benefits from more. The
 * recognition backend's vision model downsamples to roughly 1568px on the long
 * edge before it looks at anything, and the largest an item photo is ever drawn
 * is a full-width detail view.
 */
export const MAX_IMAGE_DIMENSION = 1400;
export const IMAGE_QUALITY = 0.8;

/**
 * Thumbnails exist because list rows are 52–64pt and were decoding the
 * full-size image to fill them. Thirty rows meant decoding tens of megapixels
 * of bitmap to paint a few thousand points of screen.
 *
 * 320 covers a 64pt slot at 3x with headroom, and costs single-digit kilobytes.
 */
export const THUMBNAIL_DIMENSION = 320;
export const THUMBNAIL_QUALITY = 0.7;

/**
 * Target dimensions that fit `maxEdge` on the **longer** side, or null when the
 * image already fits and should be left alone.
 *
 * Two properties this has to hold, both of which the previous `{ width: 1600 }`
 * got wrong:
 *
 * - **Bound the longer edge, not the width.** Pinning width means a portrait
 *   photo keeps a long edge of `maxEdge × aspect` — for a typical 3:4 phone
 *   photo that is 2133px and about 78% more pixels than intended, on the
 *   orientation people actually use.
 * - **Never enlarge.** An image that arrives smaller than the target must be
 *   left as it is. Scaling it up spends bytes inventing detail the source does
 *   not contain.
 */
export function scaleToFit(
  width: number,
  height: number,
  maxEdge: number,
): { width: number; height: number } | null {
  const longest = Math.max(width, height);
  if (longest <= maxEdge) return null;

  const scale = maxEdge / longest;
  return {
    // At least 1px: a pathologically thin source must not round to zero.
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}
