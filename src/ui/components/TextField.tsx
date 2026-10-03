import { useEffect, useId, useState, type ReactNode, type RefObject } from 'react';
import {
  AccessibilityInfo,
  Platform,
  StyleSheet,
  Text,
  TextInput,
  View,
  type TextInputProps,
} from 'react-native';

import { strings } from '@/i18n/strings';
import { AppText, useTextStyle } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { radius, space, useTheme } from '@/ui/theme';
import { maxScale, type TextVariant } from '@/ui/typography';

export interface TextFieldProps extends Omit<TextInputProps, 'style'> {
  label: string;
  /** Inline validation message; also announced to screen readers. */
  error?: string | null;
  hint?: string;
  /** Announced, not drawn: there is no asterisk to decode. */
  required?: boolean;
  /** Appends "(optional)" to the label. */
  optional?: boolean;
  multiline?: boolean;
  /**
   * With `multiline`: one line tall to start, growing with the text (a code
   * that wraps at its hyphens), instead of a 120 pt box for notes.
   */
  grow?: boolean;
  /** At the end of the label row, in caption type (a code's "12 of 26 characters"). */
  counter?: string;
  /** A control inside the field, at its end (the Add sheet's camera button). */
  trailing?: ReactNode;
  inputRef?: RefObject<TextInput | null>;
  /** The field the return key moves to; the keyboard stays up on the way. */
  nextRef?: RefObject<TextInput | null>;
  /** The input's type style; `code` for household and recovery codes. */
  textVariant?: TextVariant;
  /**
   * What a screen reader calls the field, when the visible label is a
   * question ("What is it?" is announced as "Name"). Defaults to `label`;
   * ", required" and the error are still added.
   */
  accessibilityLabel?: string;
}

/**
 * A labelled text input. The label sits above in sentence case (no more
 * uppercase labels); an error replaces the hint and thickens the border, and
 * whatever was typed stays in the field (issue #13).
 */
export function TextField({
  label,
  error,
  hint,
  required = false,
  optional = false,
  multiline = false,
  grow = false,
  counter,
  trailing,
  inputRef,
  nextRef,
  textVariant = 'body',
  accessibilityLabel,
  onFocus,
  onBlur,
  onSubmitEditing,
  ...inputProps
}: TextFieldProps) {
  const { colors } = useTheme();
  const id = useId();
  const textStyle = useTextStyle(textVariant);
  const [focused, setFocused] = useState(false);
  const thick = focused || Boolean(error);
  const box = multiline && !grow;
  const spokenLabel = [
    accessibilityLabel ?? label,
    required ? strings.forms.required : null,
    error ? strings.forms.errorA11y(error) : null,
  ]
    .filter(Boolean)
    .join(', ');

  // VoiceOver does not read live regions (Android keeps the polite one below).
  // Queued: two fields can fail at once, and the screen may have just moved
  // focus to the field, which VoiceOver is reading.
  useEffect(() => {
    if (Platform.OS === 'ios' && error) {
      AccessibilityInfo.announceForAccessibilityWithOptions(strings.forms.errorA11y(error), {
        queue: true,
      });
    }
  }, [error]);

  return (
    <View style={styles.container}>
      <View style={styles.labelRow}>
        <AppText variant="label" nativeID={`${id}-label`} style={styles.label}>
          {label}
          {optional ? (
            <Text style={{ color: colors.graphite }}>{` ${strings.forms.optional}`}</Text>
          ) : null}
        </AppText>
        {counter ? (
          <AppText variant="caption" tone="graphite" style={styles.counter}>
            {counter}
          </AppText>
        ) : null}
      </View>
      <View
        style={[
          styles.box,
          {
            minHeight: box ? 120 : 52,
            backgroundColor: colors.sheet,
            borderColor: error ? colors.signal : focused ? colors.ink : colors.control,
            borderWidth: thick ? 2 : 1,
            // Keep the text still when the border thickens.
            paddingHorizontal: thick ? 13 : 14,
          },
        ]}
      >
        <TextInput
          returnKeyType={nextRef ? 'next' : undefined}
          submitBehavior={nextRef ? 'submit' : undefined}
          {...inputProps}
          ref={inputRef}
          onFocus={(event) => {
            setFocused(true);
            onFocus?.(event);
          }}
          onBlur={(event) => {
            setFocused(false);
            onBlur?.(event);
          }}
          onSubmitEditing={(event) => {
            onSubmitEditing?.(event);
            nextRef?.current?.focus();
          }}
          accessibilityLabel={spokenLabel}
          accessibilityLabelledBy={`${id}-label`}
          accessibilityHint={hint}
          multiline={multiline}
          placeholderTextColor={colors.graphite}
          maxFontSizeMultiplier={maxScale(textVariant)}
          style={[
            textStyle,
            styles.input,
            {
              color: colors.ink,
              textAlignVertical: box ? 'top' : 'center',
              paddingVertical: thick ? 12 : 13,
            },
          ]}
        />
        {trailing}
      </View>
      {error ? (
        <View style={styles.message} accessibilityLiveRegion="polite">
          <Icon name="warning" size={16} color={colors.signal} />
          <AppText variant="meta" tone="signal" weight={600} style={styles.messageText}>
            {error}
          </AppText>
        </View>
      ) : hint ? (
        <AppText variant="caption" tone="graphite">
          {hint}
        </AppText>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: 6,
  },
  labelRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'baseline',
    justifyContent: 'space-between',
    columnGap: space.sm,
  },
  label: {
    flexShrink: 1,
  },
  counter: {
    fontVariant: ['tabular-nums'],
  },
  box: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  input: {
    flex: 1,
    alignSelf: 'stretch',
  },
  message: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 6,
  },
  messageText: {
    flexShrink: 1,
  },
});
