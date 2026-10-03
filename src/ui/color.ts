/**
 * Colour maths for space colours.
 *
 * Pure on purpose: no React Native import and no import from `theme.ts`, so
 * the logic tests run it in plain Node. Stored space colours are any string
 * (the drop zone's teal, preset colours, and whatever an older build or the
 * desk wrote), so everything here starts from `safeColor()`.
 */

/** Mirrors `fixed.spaceFallback` in `tokens.ts`; a literal keeps this file pure. */
const SPACE_FALLBACK = '#8A948D';
const HEX = /^#?([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;

/** Any stored value → '#RRGGBB'. Invalid → the desk's fallback grey. Alpha is dropped. */
export function safeColor(value: string | null | undefined): string {
  const match = HEX.exec((value ?? '').trim());
  if (!match) return SPACE_FALLBACK;
  let hex = match[1]!;
  if (hex.length <= 4) {
    hex = [...hex.slice(0, 3)].map((c) => c + c).join('');
  }
  return `#${hex.slice(0, 6).toUpperCase()}`;
}

/** Channels of a colour, after `safeColor()`. */
export function rgb(hex: string): [number, number, number] {
  const value = safeColor(hex);
  return [
    parseInt(value.slice(1, 3), 16),
    parseInt(value.slice(3, 5), 16),
    parseInt(value.slice(5, 7), 16),
  ];
}

function byte(channel: number): string {
  const clamped = Math.min(255, Math.max(0, Math.round(channel)));
  return clamped.toString(16).padStart(2, '0').toUpperCase();
}

/** '#RRGGBB' from 0–255 channels (rounded and clamped). */
export function toHex(r: number, g: number, b: number): string {
  return `#${byte(r)}${byte(g)}${byte(b)}`;
}

/** color-mix(in srgb, a weight, b): per-channel sRGB lerp, rounded. */
export function mixHex(a: string, b: string, weightA: number): string {
  const [ar, ag, ab] = rgb(a);
  const [br, bg, bb] = rgb(b);
  const mix = (x: number, y: number) => x * weightA + y * (1 - weightA);
  return toHex(mix(ar, br), mix(ag, bg), mix(ab, bb));
}

const tintCache = new Map<string, string>();
const TINT_CACHE_LIMIT = 256;

/**
 * Tint of a space colour on a surface: the 24 % fill behind a space's emoji.
 *
 * Blended in JS against the actual surface rather than drawn as a translucent
 * layer, so dark-mode tints lean toward the dark sheet and ink on any tint
 * stays ≥ 6.2:1. Cached because every row of a long list asks for the same few.
 */
export function spaceTint(color: string, surface: string, amount = 0.24): string {
  const key = `${color}|${surface}|${amount}`;
  const cached = tintCache.get(key);
  if (cached) return cached;
  if (tintCache.size >= TINT_CACHE_LIMIT) tintCache.clear();
  const tint = mixHex(color, surface, amount);
  tintCache.set(key, tint);
  return tint;
}

/** '#RRGGBBAA' (React Native accepts 8-digit hex), e.g. the 45 % tile edge. */
export function withAlpha(color: string, alpha: number): string {
  const clamped = Math.min(1, Math.max(0, alpha));
  return `${safeColor(color)}${byte(clamped * 255)}`;
}

/** WCAG 2.x relative luminance. */
export function luminance(hex: string): number {
  const channel = (value: number) => {
    const srgb = value / 255;
    return srgb <= 0.03928 ? srgb / 12.92 : ((srgb + 0.055) / 1.055) ** 2.4;
  };
  const [r, g, b] = rgb(hex);
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

/** WCAG contrast ratio between two colours, 1–21. */
export function contrast(a: string, b: string): number {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}
