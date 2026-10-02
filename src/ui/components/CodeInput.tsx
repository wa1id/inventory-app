import { AccessibilityInfo, StyleSheet, View } from 'react-native';

import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { TextField } from '@/ui/components/TextField';
import { formatCode, normaliseCode } from '@/ui/code';

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
  const counter = strings.forms.codeCounter(value.length, length);

  return (
    <View style={styles.container}>
      <TextField
        label={label}
        value={formatCode(value)}
        onChangeText={(text) => onChangeValue(normaliseCode(text))}
        // The counter is not a live region (it would talk over typing); it is
        // read once, on leaving the field.
        onBlur={() => AccessibilityInfo.announceForAccessibility(counter)}
        hint={hint}
        error={error}
        textVariant="code"
        autoCapitalize="characters"
        autoCorrect={false}
        spellCheck={false}
        importantForAutofill="no"
        textContentType="none"
        testID={testID}
      />
      <AppText variant="caption" tone="graphite" style={styles.counter}>
        {counter}
      </AppText>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: 6,
  },
  counter: {
    fontVariant: ['tabular-nums'],
  },
});
