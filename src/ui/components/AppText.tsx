import { Fragment, type ReactNode } from 'react';
import { StyleSheet, Text, type StyleProp, type TextProps, type TextStyle } from 'react-native';

import { useBoldText, useFontsReady } from '@/ui/fontContext';
import { camera, useTheme, type ThemeColors } from '@/ui/theme';
import {
  HEADER_VARIANTS,
  maxScale,
  textStyle,
  type FontWeight,
  type TextVariant,
} from '@/ui/typography';

export type TextTone = 'ink' | 'graphite' | 'signal' | 'onInk' | 'tapeInk' | 'toastInk' | 'camera';

export function toneColor(colors: ThemeColors, tone: TextTone): string {
  return tone === 'camera' ? camera.ink : colors[tone];
}

/**
 * Font, size, tracking and weight for a variant, following font loading and
 * iOS Bold Text. For `TextInput`s and anything else that is not an `AppText`.
 */
export function useTextStyle(variant: TextVariant, weight?: FontWeight): TextStyle {
  const fontsReady = useFontsReady();
  const boldText = useBoldText();
  return textStyle(variant, fontsReady, boldText, weight);
}

export interface AppTextProps extends Pick<
  TextProps,
  | 'numberOfLines'
  | 'ellipsizeMode'
  | 'selectable'
  | 'accessibilityRole'
  | 'accessibilityLabel'
  | 'accessibilityHint'
  | 'accessibilityLiveRegion'
  | 'accessibilityElementsHidden'
  | 'importantForAccessibility'
  | 'adjustsFontSizeToFit'
  | 'minimumFontScale'
  | 'nativeID'
  | 'onLayout'
  | 'testID'
  | 'lineBreakStrategyIOS'
  | 'textBreakStrategy'
> {
  variant: TextVariant;
  tone?: TextTone;
  /** Overrides the variant's weight (before the Bold Text bump). */
  weight?: FontWeight;
  center?: boolean;
  /** Layout only (margins, flex, a one-off colour); type comes from `variant`. */
  style?: StyleProp<TextStyle>;
  children?: ReactNode;
}

/**
 * All text in the app.
 *
 * Text always scales with the system size, up to the variant's cap, and wraps
 * rather than clipping (issue #8). Titles announce as headers by default; pass
 * `accessibilityRole="text"` to opt out (the where-card path is a title-sized
 * answer, not a heading).
 */
/**
 * Titles and paragraphs break so their last line is not one lonely word
 * ("Find where anything is / kept"); short labels keep the default.
 */
const BALANCED_VARIANTS: readonly TextVariant[] = ['display', 'title', 'heading', 'body'];

export function AppText({
  variant,
  tone = 'ink',
  weight,
  center = false,
  style,
  accessibilityRole,
  children,
  ...textProps
}: AppTextProps) {
  const { colors } = useTheme();
  const base = useTextStyle(variant, weight);
  const balanced = BALANCED_VARIANTS.includes(variant);

  return (
    <Text
      lineBreakStrategyIOS={balanced ? 'standard' : undefined}
      textBreakStrategy={balanced ? 'balanced' : undefined}
      {...textProps}
      accessibilityRole={
        accessibilityRole ?? (HEADER_VARIANTS.includes(variant) ? 'header' : undefined)
      }
      maxFontSizeMultiplier={maxScale(variant)}
      style={[base, { color: toneColor(colors, tone) }, center ? styles.center : null, style]}
    >
      {children}
    </Text>
  );
}

/**
 * `text` split around search terms of two or more characters, matching the
 * desk's `highlight()` (`home-server/web/app.js:162`): odd indexes are matches.
 */
export function splitHighlight(text: string, terms: readonly string[]): string[] {
  const usable = terms.filter((term) => term.length > 1);
  if (usable.length === 0) return [text];
  const pattern = new RegExp(
    `(${usable.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`,
    'gi',
  );
  return text.split(pattern);
}

export interface HighlightedProps extends Omit<AppTextProps, 'children'> {
  text: string;
  terms: readonly string[];
}

/**
 * Text with the search terms marked, so a result shows why it matched.
 *
 * Matches are nested `Text` on the `mark` colour with ink on top (13:1 light,
 * 6.4:1 dark). The spoken text is unchanged.
 */
export function Highlighted({ text, terms, ...textProps }: HighlightedProps) {
  const { colors } = useTheme();
  const parts = splitHighlight(text, terms);

  return (
    <AppText {...textProps}>
      {parts.map((part, index) =>
        index % 2 === 1 ? (
          <Text key={index} style={{ backgroundColor: colors.mark, color: colors.ink }}>
            {part}
          </Text>
        ) : (
          <Fragment key={index}>{part}</Fragment>
        ),
      )}
    </AppText>
  );
}

const styles = StyleSheet.create({
  center: {
    textAlign: 'center',
  },
});
