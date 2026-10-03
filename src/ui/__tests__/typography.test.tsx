import { FONT_FAMILY, boldWeight, textStyle } from '@/ui/typography';

describe('textStyle', () => {
  it('uses the system font at the numeric weight until the fonts are ready', () => {
    const style = textStyle('name', false);
    expect(style.fontWeight).toBe('600');
    expect(style.fontFamily).toBeUndefined();
    expect(style).toMatchObject({ fontSize: 17, lineHeight: 22 });
  });

  it('switches to the weight’s own family, with no fontWeight, once ready', () => {
    const style = textStyle('name', true);
    expect(style.fontFamily).toBe(FONT_FAMILY[600]);
    expect(style.fontWeight).toBeUndefined();
  });

  it('bumps one step for iOS Bold Text, after any weight override', () => {
    expect(textStyle('body', true, true).fontFamily).toBe(FONT_FAMILY[600]);
    expect(textStyle('body', false, true, 700).fontWeight).toBe('800');
    expect(boldWeight(800)).toBe(800);
  });

  it('keeps changing numbers tabular', () => {
    expect(textStyle('stepper', true).fontVariant).toEqual(['tabular-nums']);
    expect(textStyle('body', true).fontVariant).toBeUndefined();
  });

  it('never sets the location smaller than the name above it', () => {
    expect(textStyle('where', true).fontSize).toBe(textStyle('name', true).fontSize);
  });
});
