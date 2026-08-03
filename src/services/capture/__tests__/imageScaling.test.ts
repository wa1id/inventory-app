import {
  MAX_IMAGE_DIMENSION,
  THUMBNAIL_DIMENSION,
  scaleToFit,
} from '@/services/capture/imageScaling';

/** Pixels in the stored image, which is what the file size tracks. */
function megapixels(size: { width: number; height: number } | null, fallback: number): number {
  return size ? (size.width * size.height) / 1_000_000 : fallback;
}

describe('scaleToFit', () => {
  it('bounds the longer edge of a portrait photo, not its width', () => {
    // The regression this exists for: `resize({ width: 1600 })` left a portrait
    // photo 1600 wide and 2133 tall.
    const target = scaleToFit(3024, 4032, 1400);

    expect(target).toEqual({ width: 1050, height: 1400 });
    expect(Math.max(target!.width, target!.height)).toBe(1400);
  });

  it('bounds the longer edge of a landscape photo', () => {
    const target = scaleToFit(4032, 3024, 1400);

    expect(target).toEqual({ width: 1400, height: 1050 });
    expect(Math.max(target!.width, target!.height)).toBe(1400);
  });

  it('preserves aspect ratio in both orientations', () => {
    const portrait = scaleToFit(3024, 4032, 1400)!;
    const landscape = scaleToFit(4032, 3024, 1400)!;

    expect(portrait.width / portrait.height).toBeCloseTo(3024 / 4032, 3);
    expect(landscape.width / landscape.height).toBeCloseTo(4032 / 3024, 3);
  });

  it('leaves an image that already fits completely alone', () => {
    // Null rather than an identity resize: re-scaling to the same size would
    // still cost a resample.
    expect(scaleToFit(800, 600, 1400)).toBeNull();
    expect(scaleToFit(1400, 1400, 1400)).toBeNull();
  });

  it('never enlarges a small import', () => {
    // A screenshot or a received image. Upscaling adds bytes and no detail.
    for (const [width, height] of [
      [320, 240],
      [240, 320],
      [1399, 20],
      [1, 1],
    ]) {
      expect(scaleToFit(width!, height!, MAX_IMAGE_DIMENSION)).toBeNull();
    }
  });

  it('keeps a pathologically thin image at least one pixel wide', () => {
    const target = scaleToFit(20_000, 3, 1400)!;

    expect(target.width).toBe(1400);
    expect(target.height).toBeGreaterThanOrEqual(1);
  });

  it('cuts a portrait photo to well under half the pixels the old bound kept', () => {
    // What the width-bound produced, versus what the long-edge bound produces.
    const old = { width: 1600, height: Math.round((4032 * 1600) / 3024) };
    const now = scaleToFit(3024, 4032, MAX_IMAGE_DIMENSION);

    expect(megapixels(old, 0)).toBeCloseTo(3.41, 1);
    expect(megapixels(now, 0)).toBeCloseTo(1.47, 1);
    // JPEG/WebP size tracks pixel count closely, so this is most of the saving.
    expect(megapixels(now, 0)).toBeLessThan(megapixels(old, 0) / 2);
  });

  it('produces a thumbnail small enough to be worth having', () => {
    const thumb = scaleToFit(3024, 4032, THUMBNAIL_DIMENSION)!;

    expect(Math.max(thumb.width, thumb.height)).toBe(THUMBNAIL_DIMENSION);
    // A 64pt row at 3x needs 192px; 320 leaves headroom without approaching
    // the cost of decoding the full image.
    expect(THUMBNAIL_DIMENSION).toBeGreaterThanOrEqual(192);
    expect(megapixels(thumb, 0)).toBeLessThan(
      megapixels(scaleToFit(3024, 4032, MAX_IMAGE_DIMENSION), 0) / 15,
    );
  });
});
