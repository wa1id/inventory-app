import { onColor, SPACE_COLORS, SPACE_PRESETS } from '@/ui/theme';

describe('onColor', () => {
  it('puts light text on dark fills and dark text on light fills', () => {
    expect(onColor('#000000')).toBe('#FFFFFF');
    expect(onColor('#FFFFFF')).toBe('#12161C');
  });

  it('accepts shorthand hex and a missing leading hash', () => {
    expect(onColor('#000')).toBe('#FFFFFF');
    expect(onColor('fff')).toBe('#12161C');
  });

  it('weights green more than blue, so it is not a naive average', () => {
    // Pure blue is far darker to the eye than pure green despite both being a
    // single full channel; a mean-of-channels implementation would tie them.
    expect(onColor('#0000FF')).toBe('#FFFFFF');
    expect(onColor('#00FF00')).toBe('#12161C');
  });

  it('clears WCAG AA for large text on every space colour', () => {
    const lum = (hex: string) => {
      const channel = (offset: number) => {
        const srgb = parseInt(hex.replace('#', '').slice(offset, offset + 2), 16) / 255;
        return srgb <= 0.03928 ? srgb / 12.92 : ((srgb + 0.055) / 1.055) ** 2.4;
      };
      return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
    };
    const contrast = (a: string, b: string) =>
      (Math.max(lum(a), lum(b)) + 0.05) / (Math.min(lum(a), lum(b)) + 0.05);

    for (const color of SPACE_COLORS) {
      expect(contrast(onColor(color), color)).toBeGreaterThanOrEqual(3);
    }
  });

  it('picks the higher-contrast foreground, not the intuitive one', () => {
    // The default blue reads as a "white text" colour but measures 3.2:1
    // against white and 5.6:1 against ink.
    expect(onColor('#5B8DEF')).toBe('#12161C');
  });
});

describe('SPACE_PRESETS', () => {
  it('offers distinct one-tap names drawn from the shared palette', () => {
    const names = SPACE_PRESETS.map((preset) => preset.name);
    expect(new Set(names).size).toBe(names.length);

    for (const preset of SPACE_PRESETS) {
      expect(SPACE_COLORS).toContain(preset.color);
      expect(preset.icon).not.toHaveLength(0);
    }
  });
});
