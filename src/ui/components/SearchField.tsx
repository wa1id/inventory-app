import { useRef, useState, type RefObject } from 'react';
import { ActivityIndicator, Platform, StyleSheet, TextInput, View } from 'react-native';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { strings } from '@/i18n/strings';
import { useTextStyle } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { IconButton } from '@/ui/components/IconButton';
import { haptics } from '@/ui/haptics';
import { delay } from '@/ui/motion';
import { radius, useTheme } from '@/ui/theme';
import { maxScale } from '@/ui/typography';

export interface SearchFieldProps {
  value: string;
  onChangeText: (text: string) => void;
  onSubmit?: () => void;
  placeholder?: string;
  accessibilityLabel?: string;
  /** A request is in flight: the lens becomes a spinner (after 180 ms). */
  busy?: boolean;
  autoFocus?: boolean;
  inputRef?: RefObject<TextInput | null>;
  /** 52 tall on Home, 48 in pickers. */
  size?: 'large' | 'regular';
  /** Label codes are typed in capitals in the open-by-code picker. */
  autoCapitalize?: 'none' | 'characters';
  testID?: string;
  onFocus?: () => void;
  onBlur?: () => void;
}

/**
 * The search box: what she types is matched against names, places and the
 * codes written on labels. No autocorrect, so "usbc" stays "usbc" and a code
 * is not "corrected" into a word.
 */
export function SearchField({
  value,
  onChangeText,
  onSubmit,
  placeholder = strings.common.findAnything,
  accessibilityLabel = strings.a11y.searchHousehold,
  busy = false,
  autoFocus = false,
  inputRef,
  size = 'large',
  autoCapitalize = 'none',
  testID,
  onFocus,
  onBlur,
}: SearchFieldProps) {
  const { colors } = useTheme();
  const large = size === 'large';
  const textStyle = useTextStyle(large ? 'search' : 'body');
  const [focused, setFocused] = useState(false);
  const localRef = useRef<TextInput>(null);
  const ref = inputRef ?? localRef;
  const showSpinner = useDelayedFlag(busy, delay.skeleton);

  function clear() {
    onChangeText('');
    ref.current?.focus();
    haptics.choice();
  }

  return (
    <View
      style={[
        styles.field,
        {
          minHeight: large ? 52 : 48,
          backgroundColor: colors.sheet,
          borderColor: focused ? colors.ink : colors.control,
          borderWidth: focused ? 2 : 1,
          // Keep the text still when the border thickens. The clear button
          // brings its own room at the end; without it the text needs some.
          paddingStart: focused ? 13 : 14,
          paddingEnd: value ? (focused ? 1 : 2) : focused ? 13 : 14,
        },
      ]}
    >
      {showSpinner ? (
        <ActivityIndicator size="small" color={colors.graphite} style={styles.leading} />
      ) : (
        <Icon name="search" size={20} color={colors.graphite} />
      )}
      <TextInput
        ref={ref}
        value={value}
        onChangeText={onChangeText}
        onSubmitEditing={onSubmit}
        onFocus={() => {
          setFocused(true);
          onFocus?.();
        }}
        onBlur={() => {
          setFocused(false);
          onBlur?.();
        }}
        placeholder={placeholder}
        placeholderTextColor={colors.graphite}
        autoFocus={autoFocus}
        autoCorrect={false}
        autoCapitalize={autoCapitalize}
        spellCheck={false}
        returnKeyType="search"
        submitBehavior="blurAndSubmit"
        clearButtonMode="never"
        importantForAutofill="no"
        textContentType="none"
        accessibilityRole={Platform.OS === 'ios' ? 'search' : undefined}
        accessibilityLabel={accessibilityLabel}
        maxFontSizeMultiplier={maxScale(large ? 'search' : 'body')}
        testID={testID}
        style={[textStyle, styles.input, { color: colors.ink }]}
      />
      {value ? (
        // Takes the chip's height, not its 48 pt target's, so the field does
        // not grow when the first letter is typed; the target stays 48 pt.
        <View style={styles.clear}>
          <IconButton
            icon="close"
            variant="chip"
            accessibilityLabel={strings.common.clearSearch}
            onPress={clear}
            testID="search-clear"
          />
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  field: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  leading: {
    width: 20,
    height: 20,
  },
  input: {
    flex: 1,
    alignSelf: 'stretch',
    paddingVertical: 0,
  },
  clear: {
    marginVertical: -8,
  },
});
