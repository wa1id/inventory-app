import { Platform, type TextStyle } from 'react-native';

export type FontWeight = 400 | 500 | 600 | 700 | 800;

/**
 * Atkinson Hyperlegible Next, one family name per static weight.
 *
 * Each name is also the key `FontProvider` passes to `loadAsync`, so a style
 * picks a weight by family. Android ignores `fontWeight` on custom families and
 * iOS may synthesise one, so with these families no `fontWeight` is ever set.
 */
export const FONT_FAMILY: Record<FontWeight, string> = {
  400: 'AtkinsonHyperlegibleNext_400Regular',
  500: 'AtkinsonHyperlegibleNext_500Medium',
  600: 'AtkinsonHyperlegibleNext_600SemiBold',
  700: 'AtkinsonHyperlegibleNext_700Bold',
  800: 'AtkinsonHyperlegibleNext_800ExtraBold',
};

interface VariantSpec {
  size: number;
  lineHeight: number;
  weight: FontWeight;
  tracking: number;
  /** `maxFontSizeMultiplier`: text scales up to here, then layout reflows instead. */
  maxScale: number;
  /** Numbers that change in place (`tnum`; the font has no `lnum`). */
  tabular?: boolean;
}

/**
 * The type scale. Sizes are pt/dp at font scale 1; line heights scale with the
 * font. The location line (`where`) is the same size as the name above it on
 * purpose: the answer is never smaller than the question (`111b579`).
 */
export const TEXT_VARIANTS = {
  display: { size: 32, lineHeight: 40, weight: 800, tracking: -0.4, maxScale: 1.4 },
  title: { size: 26, lineHeight: 32, weight: 700, tracking: -0.3, maxScale: 1.5 },
  whereCard: { size: 24, lineHeight: 30, weight: 700, tracking: 0, maxScale: 1.6 },
  itemTitle: { size: 22, lineHeight: 28, weight: 700, tracking: 0, maxScale: 1.6 },
  heading: { size: 19, lineHeight: 25, weight: 700, tracking: 0, maxScale: 1.8 },
  search: { size: 19, lineHeight: 24, weight: 500, tracking: 0, maxScale: 1.6 },
  code: { size: 19, lineHeight: 26, weight: 700, tracking: 1.5, maxScale: 1.6, tabular: true },
  name: { size: 17, lineHeight: 22, weight: 600, tracking: 0, maxScale: 2.0 },
  where: { size: 17, lineHeight: 22, weight: 500, tracking: 0, maxScale: 2.0 },
  body: { size: 17, lineHeight: 24, weight: 400, tracking: 0, maxScale: 2.2 },
  section: { size: 16, lineHeight: 21, weight: 700, tracking: 0, maxScale: 1.8 },
  button: { size: 16, lineHeight: 20, weight: 600, tracking: 0, maxScale: 1.6 },
  label: { size: 15, lineHeight: 20, weight: 600, tracking: 0, maxScale: 2.0 },
  meta: { size: 15, lineHeight: 20, weight: 500, tracking: 0, maxScale: 2.0 },
  aside: { size: 15, lineHeight: 20, weight: 600, tracking: 0, maxScale: 2.0, tabular: true },
  caption: { size: 13, lineHeight: 18, weight: 500, tracking: 0.1, maxScale: 2.0 },
  factLabel: { size: 13, lineHeight: 18, weight: 700, tracking: 0.1, maxScale: 2.0 },
  tab: { size: 12, lineHeight: 16, weight: 600, tracking: 0.1, maxScale: 1.3 },
  badge: { size: 12, lineHeight: 16, weight: 700, tracking: 0, maxScale: 1.3, tabular: true },
  tapeS: { size: 13, lineHeight: 16, weight: 700, tracking: 0.9, maxScale: 1.6, tabular: true },
  tapeM: { size: 16, lineHeight: 19, weight: 700, tracking: 1.1, maxScale: 1.6, tabular: true },
  tapeL: { size: 22, lineHeight: 26, weight: 800, tracking: 1.8, maxScale: 1.5, tabular: true },
  stepper: { size: 17, lineHeight: 22, weight: 800, tracking: 0, maxScale: 1.6, tabular: true },
  stepperL: { size: 22, lineHeight: 28, weight: 800, tracking: 0, maxScale: 1.6, tabular: true },
} satisfies Record<string, VariantSpec>;

export type TextVariant = keyof typeof TEXT_VARIANTS;

/** Variants that announce as headers unless the caller opts out. */
export const HEADER_VARIANTS: readonly TextVariant[] = ['display', 'title', 'itemTitle', 'heading'];

/**
 * iOS Bold Text bumps one step. The system does this for its own font but not
 * for a custom family, so it is done by hand.
 */
export function boldWeight(weight: FontWeight): FontWeight {
  switch (weight) {
    case 400:
      return 600;
    case 500:
    case 600:
      return 700;
    default:
      return 800;
  }
}

/** How far a variant may scale with the system text size. */
export function maxScale(variant: TextVariant): number {
  return TEXT_VARIANTS[variant].maxScale;
}

/**
 * Style for a variant.
 *
 * Until the fonts are ready (or forever, if they fail) text renders in the
 * system font at the equivalent numeric weight, so start-up never waits on a
 * font. `weight` overrides the variant's own weight before the Bold Text bump.
 */
export function textStyle(
  variant: TextVariant,
  fontsReady: boolean,
  boldText = false,
  weight?: FontWeight,
): TextStyle {
  const spec: VariantSpec = TEXT_VARIANTS[variant];
  const base = weight ?? spec.weight;
  const resolved = boldText ? boldWeight(base) : base;

  return {
    fontSize: spec.size,
    lineHeight: spec.lineHeight,
    letterSpacing: spec.tracking,
    ...(fontsReady
      ? { fontFamily: FONT_FAMILY[resolved] }
      : { fontWeight: String(resolved) as TextStyle['fontWeight'] }),
    ...(spec.tabular ? { fontVariant: ['tabular-nums'] } : null),
    ...(Platform.OS === 'android' ? { includeFontPadding: false } : null),
  };
}
