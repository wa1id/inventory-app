/**
 * Design tokens: the desk's language on the phone.
 *
 * Names and values follow the household desk (`home-server/web/app.css:29-90`)
 * so both surfaces can share one token sheet later (#53). One quiet sheet on a
 * plaster wall; the only loud colour is the yellow label tape. Keys the desk
 * does not have are native additions: touch needs a stronger pressed state
 * than a mouse hover, and form controls need a ≥ 3:1 boundary (WCAG 1.4.11)
 * that the desk's `rule-strong` does not reach.
 *
 * Plain data only: no React Native import, so pure modules and Node tests can
 * read it too.
 */

export const lightColors = {
  /** Screen background, native headers, navigation theme background. */
  plaster: '#E9ECE7',
  /** Bordered lists, cards, inputs, tab bar, bottom bars. */
  sheet: '#FFFFFF',
  /** Thumb placeholder, display chips, info banners, skeleton blocks. */
  sheet2: '#F3F5F2',
  /** Selected option or row, always with a 3 pt ink bar on the leading edge. */
  selected: '#E4EBE2',
  /** iOS pressed overlay; the desk's 5 % wash is too faint under a finger. */
  pressed: 'rgba(28,33,30,0.08)',
  /** Android `android_ripple.color`. */
  ripple: 'rgba(28,33,30,0.12)',
  ink: '#1C211E',
  /** Pressed primary button: ink 86 % over sheet, the desk's hover. */
  inkPressed: '#3C403E',
  /** Text and icons on ink. */
  onInk: '#FFFFFF',
  graphite: '#59625C',
  /** 1 pt separators and sheet borders (decorative). */
  rule: '#D6DCD5',
  /** Stepper dividers and disabled stepper glyphs (decorative). */
  ruleStrong: '#B6BEB6',
  /** Borders of inputs, steppers, chips and secondary buttons: ≥ 3:1 on sheet and plaster. */
  control: '#7D877F',
  tape: '#FFD23F',
  tapeInk: '#1D1A0E',
  /** Search-term highlight behind ink text. */
  mark: '#FFE48C',
  /** Stepper number field while typing (desk `.stepper-num:focus`). */
  numberFocus: '#FFF5D5',
  signal: '#B3361A',
  signalWash: '#FBECE7',
  toastBg: '#1C211E',
  toastInk: '#F4F6F3',
  toastAction: '#FFD23F',
  /** Leading bar on error toasts; the toast is inverted, so it borrows dark's signal. */
  toastSignal: '#FF9573',
  /** Reserved for desk parity; no v1 surface uses a scrim. */
  scrim: 'rgba(20,24,22,0.42)',
  /** Toasts and the photo viewer's close button only. */
  shadowFloat: '0 18px 40px rgba(20,26,22,0.20), 0 2px 8px rgba(20,26,22,0.08)',
  /** 1 pt ring on pips and swatches so a white space stays visible on a white sheet. */
  pipRing: 'rgba(0,0,0,0.12)',
};

export type ColorTokens = typeof lightColors;

export const darkColors: ColorTokens = {
  plaster: '#141715',
  sheet: '#1C201E',
  sheet2: '#242926',
  selected: '#2B332E',
  pressed: 'rgba(232,236,232,0.10)',
  ripple: 'rgba(232,236,232,0.16)',
  ink: '#E8ECE8',
  inkPressed: '#CBCFCC',
  onInk: '#1C201E',
  graphite: '#A3ACA5',
  rule: '#2F3632',
  ruleStrong: '#47514B',
  control: '#6B756E',
  tape: '#F4CA3C',
  tapeInk: '#1D1A0E',
  mark: '#5D5327',
  numberFocus: '#4C4525',
  signal: '#FF9573',
  signalWash: '#3A231C',
  toastBg: '#E8ECE8',
  toastInk: '#141715',
  toastAction: '#7A5B00',
  toastSignal: '#B3361A',
  scrim: 'rgba(0,0,0,0.60)',
  shadowFloat: '0 18px 40px rgba(0,0,0,0.50), 0 2px 8px rgba(0,0,0,0.30)',
  // Differs from the desk so a black or navy space still shows its edge.
  pipRing: 'rgba(255,255,255,0.16)',
};

/** `boxShadow` for the few floating surfaces, by scheme. */
export const shadowFloat = {
  light: lightColors.shadowFloat,
  dark: darkColors.shadowFloat,
} as const;

/** Scheme-independent colours. */
export const fixed = {
  /** Any stored space colour that is not a valid hex (desk `safeColor`). */
  spaceFallback: '#8A948D',
  /** The QR card is black on white in both schemes so every scanner reads it. */
  qrPaper: '#FFFFFF',
  qrInk: '#000000',
  photoBackdrop: 'rgba(12,14,13,0.96)',
} as const;

/**
 * Camera chrome sits on a live picture, not on plaster, so it ignores the
 * scheme. Error text stays white: signal on a chip over a bright scene is only
 * 2.54:1, so errors get the `errorBar` instead.
 */
export const camera = {
  bg: '#000000',
  ink: '#FFFFFF',
  chip: 'rgba(12,14,13,0.62)',
  chipPressed: 'rgba(255,255,255,0.18)',
  selected: 'rgba(255,255,255,0.22)',
  accent: '#FFD23F',
  errorBar: '#FF9573',
} as const;

export const space = {
  xxs: 2,
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
  xxxl: 40,
} as const;

export const radius = {
  tape: 3,
  tapeL: 4,
  thumb: 7,
  /** Buttons, inputs, steppers, bordered chips. */
  control: 8,
  /** Search field, where card, toast, banners. */
  card: 10,
  /** Bordered lists, settings groups, QR card. */
  sheet: 12,
  dialog: 14,
  pill: 999,
} as const;

/** Side padding of every screen, at every width. */
export const GUTTER = 16;
/** Content is centred at this width on iPad (`supportsTablet: true`). */
export const CONTENT_MAX_WIDTH = 640;

export const ROW_MIN = 72;
export const ROW_MIN_PHOTO = 96;
export const OPTION_MIN = 56;
export const ROW_PADDING = { vertical: 10, start: 12, end: 16 } as const;
export const ROW_GAP = 12;

export const THUMB = 56;
export const THUMB_PHOTO = 76;
export const THUMB_DETAIL = 88;
export const THUMB_SMALL = 48;

/** Tab bar content height; the bar adds `max(insets.bottom, 8)` below it. */
export const TAB_BAR_CONTENT = 56;
/** Bottom bars add `insets.bottom` to `bottom` (nothing while the keyboard is up). */
export const BOTTOM_BAR_PADDING = { top: 12, sides: 16, bottom: 12 } as const;

/** At or above this font scale, or below this width, rows and bars stack. */
export const STACK_FONT_SCALE = 1.35;
export const NARROW_WIDTH = 360;
