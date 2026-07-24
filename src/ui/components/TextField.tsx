import { useId } from 'react';
import { StyleSheet, Text, TextInput, View, type TextInputProps } from 'react-native';

import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

interface TextFieldProps extends Omit<TextInputProps, 'style'> {
  label: string;
  /** Inline validation message; also announced to screen readers. */
  error?: string | null;
  hint?: string;
  required?: boolean;
  multiline?: boolean;
}

export function TextField({
  label,
  error,
  hint,
  required = false,
  multiline = false,
  ...inputProps
}: TextFieldProps) {
  const { colors } = useTheme();
  const id = useId();

  return (
    <View style={styles.container}>
      <Text nativeID={`${id}-label`} style={[styles.label, { color: colors.textMuted }]}>
        {label}
        {required ? ' *' : ''}
      </Text>
      <TextInput
        {...inputProps}
        accessibilityLabel={`${label}${required ? ', required' : ''}`}
        accessibilityLabelledBy={`${id}-label`}
        accessibilityHint={hint}
        multiline={multiline}
        placeholderTextColor={colors.textMuted}
        style={[
          styles.input,
          {
            backgroundColor: colors.surface,
            borderColor: error ? colors.danger : colors.border,
            color: colors.text,
            minHeight: multiline ? MIN_TOUCH_TARGET * 2 : MIN_TOUCH_TARGET,
            textAlignVertical: multiline ? 'top' : 'center',
          },
        ]}
      />
      {error ? (
        <Text style={[styles.message, { color: colors.danger }]} accessibilityLiveRegion="polite">
          {error}
        </Text>
      ) : hint ? (
        <Text style={[styles.message, { color: colors.textMuted }]}>{hint}</Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: spacing.xs,
  },
  label: {
    fontSize: 13,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
  },
  input: {
    borderWidth: 1,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.md,
    fontSize: 16,
  },
  message: {
    fontSize: 13,
    lineHeight: 18,
  },
});
