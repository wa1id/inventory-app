import { AccessibilityInfo } from 'react-native';

import { strings } from '@/i18n/strings';
import { Icon } from '@/ui/components/Icon';
import { TextField } from '@/ui/components/TextField';
import { formatCode, normaliseCode } from '@/ui/code';
import { useTheme } from '@/ui/theme';

export interface CodeInputProps {
  label: string;
  /** Normalised: upper case, no hyphens, look-alikes folded. */
  value: string;
  onChangeValue: (normalised: string) => void;
  length?: number;
  hint?: string;
  error?: string | null;
  testID?: string;
}

/**
 * A household or recovery code field.
 *
 * Shown in groups of five as she types, in the hyperlegible code style; small
 * letters, missing hyphens, pasted spaces and line breaks, and the look-alikes
 * I, L and O are all fine, because the value is normalised on every change.
 * Whether the code is valid is the screen's call, on submit.
 *
 * A whole code is wider than any phone, so the field wraps it at its hyphens
 * rather than scrolling it out of sight: she can check every character
 * against the paper. Return closes the keyboard; it never adds a line.
 */
export function CodeInput({
  label,
  value,
  onChangeValue,
  length = 26,
  hint,
  error,
  testID,
}: CodeInputProps) {
  const { colors } = useTheme();
  const counter = strings.forms.codeCounter(value.length, length);

  return (
    <TextField
      label={label}
      // On the label row, and only once there is something to count, so it
      // is not read as the end of the hint.
      counter={value ? counter : undefined}
      value={formatCode(value)}
      onChangeText={(text) => onChangeValue(normaliseCode(text))}
      // The counter is not a live region (it would talk over typing); it is
      // read once, on leaving the field.
      onBlur={() => AccessibilityInfo.announceForAccessibility(counter)}
      hint={hint}
      error={error}
      textVariant="code"
      multiline
      grow
      scrollEnabled={false}
      submitBehavior="blurAndSubmit"
      returnKeyType="done"
      trailing={<Icon name="lock" size={20} color={colors.graphite} />}
      autoCapitalize="characters"
      autoCorrect={false}
      spellCheck={false}
      importantForAutofill="no"
      textContentType="none"
      testID={testID}
    />
  );
}
