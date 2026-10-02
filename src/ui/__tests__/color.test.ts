import {
  contrast,
  luminance,
  mixHex,
  rgb,
  safeColor,
  spaceTint,
  toHex,
  withAlpha,
} from '@/ui/color';
import { darkColors, lightColors, type ColorTokens } from '@/ui/tokens';

describe('safeColor', () => {
  it('normalises 6-digit hex to upper case with a hash', () => {
    expect(safeColor('#5b8def')).toBe('#5B8DEF');
    expect(safeColor('5B8DEF')).toBe('#5B8DEF');
    expect(safeColor('  #0F9BB0 ')).toBe('#0F9BB0');
  });

  it('expands 3- and 4-digit shorthand and drops alpha', () => {
    expect(safeColor('#abc')).toBe('#AABBCC');
    expect(safeColor('#abcd')).toBe('#AABBCC');
    expect(safeColor('#11223344')).toBe('#112233');
  });

  it.each([null, undefined, '', 'blue', '#12', '#12345', '#GGGGGG', 'rgb(0,0,0)'])(
    'falls back to the desk grey for %p',
    (value) => {
      expect(safeColor(value)).toBe('#8A948D');
    },
  );
});

describe('rgb and toHex', () => {
  it('round-trips channels', () => {
    expect(rgb('#5B8DEF')).toEqual([91, 141, 239]);
    expect(toHex(91, 141, 239)).toBe('#5B8DEF');
  });

  it('rounds and clamps', () => {
    expect(toHex(-4, 255.6, 127.5)).toBe('#00FF80');
  });
});

describe('mixHex', () => {
  it('returns each end at weight 1 and 0', () => {
    expect(mixHex('#5B8DEF', '#FFFFFF', 1)).toBe('#5B8DEF');
    expect(mixHex('#5B8DEF', '#FFFFFF', 0)).toBe('#FFFFFF');
  });

  it('lerps per channel', () => {
    expect(mixHex('#000000', '#FFFFFF', 0.5)).toBe('#808080');
  });
});

describe('spaceTint', () => {
  it('matches the desk’s 24 % colour-mix', () => {
    expect(spaceTint('#5B8DEF', '#FFFFFF', 0.24)).toBe('#D8E4FB');
  });

  it('defaults to 24 % and tolerates junk colours', () => {
    expect(spaceTint('#5B8DEF', '#FFFFFF')).toBe('#D8E4FB');
    expect(spaceTint('not a colour', '#FFFFFF')).toBe(mixHex('#8A948D', '#FFFFFF', 0.24));
  });

  it('keeps ink readable on the tint of any colour, light and dark', () => {
    for (const color of ['#000000', '#FFFFFF', '#E0A800', '#0F9BB0', '#5B8DEF']) {
      expect(contrast(lightColors.ink, spaceTint(color, lightColors.sheet))).toBeGreaterThan(9);
      expect(contrast(darkColors.ink, spaceTint(color, darkColors.sheet))).toBeGreaterThan(6);
    }
  });
});

describe('withAlpha', () => {
  it('appends the alpha byte', () => {
    expect(withAlpha('#5B8DEF', 0.45)).toBe('#5B8DEF73');
    expect(withAlpha('#abc', 1)).toBe('#AABBCCFF');
    expect(withAlpha('#5B8DEF', 0)).toBe('#5B8DEF00');
  });
});

describe('luminance and contrast', () => {
  it('measures the WCAG extremes', () => {
    expect(luminance('#000000')).toBe(0);
    expect(luminance('#FFFFFF')).toBe(1);
    expect(contrast('#000000', '#FFFFFF')).toBeCloseTo(21, 5);
    expect(contrast('#FFFFFF', '#000000')).toBeCloseTo(21, 5);
  });
});

describe('token contrast', () => {
  // Opaque text pairs from the spec's measured table; translucent tokens are
  // composited and measured in the design script instead.
  const textPairs: [keyof ColorTokens, keyof ColorTokens][] = [
    ['ink', 'sheet'],
    ['ink', 'plaster'],
    ['ink', 'sheet2'],
    ['ink', 'selected'],
    ['graphite', 'sheet'],
    ['graphite', 'plaster'],
    ['graphite', 'sheet2'],
    ['graphite', 'selected'],
    ['signal', 'sheet'],
    ['signal', 'plaster'],
    ['signal', 'signalWash'],
    ['ink', 'signalWash'],
    ['tapeInk', 'tape'],
    ['onInk', 'ink'],
    ['onInk', 'inkPressed'],
    ['toastInk', 'toastBg'],
    ['toastAction', 'toastBg'],
    ['ink', 'mark'],
    ['ink', 'numberFocus'],
  ];

  it.each(textPairs)('%s on %s clears AA in both schemes', (text, surface) => {
    for (const colors of [lightColors, darkColors]) {
      expect(contrast(colors[text], colors[surface])).toBeGreaterThanOrEqual(4.5);
    }
  });

  it.each(['sheet', 'plaster', 'sheet2'] as const)('control borders clear 3:1 on %s', (surface) => {
    for (const colors of [lightColors, darkColors]) {
      expect(contrast(colors.control, colors[surface])).toBeGreaterThanOrEqual(3);
    }
  });
});
