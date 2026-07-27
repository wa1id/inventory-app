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

  it('returns a legible foreground for every space colour', () => {
    for (const color of SPACE_COLORS) {
      expect(['#FFFFFF', '#12161C']).toContain(onColor(color));
    }
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
