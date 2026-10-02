import { useEffect, useRef, useState, type Ref } from 'react';
import { Keyboard, StyleSheet, TextInput, View } from 'react-native';

import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { logError, logEvent } from '@/services/telemetry';
import { AppText, useTextStyle } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon } from '@/ui/components/Icon';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { attemptName } from '@/ui/item/itemDetails';
import { radius, space, useTheme } from '@/ui/theme';
import { maxScale } from '@/ui/typography';

export interface NameItInlineProps {
  item: { id: string; updatedAt: number };
  /** Focus the field: in a filing run, once the screen has finished sliding in. */
  autoFocus: boolean;
  /** The "What is it?" heading, which a filing run gives screen-reader focus. */
  headingRef?: Ref<View>;
  /** The item now has this name, saved here or just given on another phone. */
  onNamed: (name: string) => void;
}

/**
 * "What is it?" in place of the title of an item that has no name yet
 * (a Quick Snap photo), so naming it is one field and one tap on the item
 * screen rather than a trip through Edit details (spec §5.10, §6.7).
 *
 * The heading is a header, so the screen stays titled for VoiceOver; the
 * field is labelled "Name" for screen readers only. What is typed belongs to
 * this component, which the screen keys by item id, so a refetch underneath
 * never clears it.
 */
export function NameItInline({ item, autoFocus, headingRef, onNamed }: NameItInlineProps) {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const toast = useToast();
  const { colors } = useTheme();
  const inputStyle = useTextStyle('body');
  const inputRef = useRef<TextInput>(null);
  const savingRef = useRef(false);
  const [value, setValue] = useState('');
  const [focused, setFocused] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus();
  }, [autoFocus]);

  async function save() {
    const name = value.trim();
    if (!name) {
      setError(strings.forms.itemNameRequired);
      return;
    }
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    setError(null);

    const outcome = await attemptName(repos.items, item, name);
    savingRef.current = false;
    setSaving(false);

    if (outcome.kind === 'named') {
      logEvent('item_updated');
      // The field goes away with the keyboard still up on Android; focus
      // moves on to "File it…" or "Edit details" instead.
      Keyboard.dismiss();
      onNamed(name);
      invalidate();
    } else if (outcome.kind === 'namedElsewhere') {
      haptics.warning();
      Keyboard.dismiss();
      toast.show({ message: strings.item.nameIt.justNamed(outcome.name) });
      onNamed(outcome.name);
      invalidate();
    } else if (outcome.kind === 'gone') {
      // The screen re-reads, finds nothing and says the item is gone.
      invalidate();
    } else {
      const { kind } = describeError(outcome.cause, 'save', 'item');
      logError('item_name_failed', { errorClass: kind });
      haptics.error();
      setError(kind === 'offline' ? strings.item.nameIt.failedOffline : strings.item.nameIt.failed);
    }
  }

  const thick = focused || error !== null;

  return (
    <View style={styles.container}>
      <View ref={headingRef} accessible accessibilityRole="header">
        <AppText variant="heading">{strings.item.nameIt.label}</AppText>
      </View>
      <View
        style={[
          styles.box,
          {
            backgroundColor: colors.sheet,
            borderColor: error ? colors.signal : focused ? colors.ink : colors.control,
            borderWidth: thick ? 2 : 1,
            // Keep the text still when the border thickens.
            paddingHorizontal: thick ? 13 : 14,
          },
        ]}
      >
        <TextInput
          ref={inputRef}
          value={value}
          onChangeText={(next) => {
            setValue(next);
            if (error) setError(null);
          }}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          onSubmitEditing={() => void save()}
          placeholder={strings.item.nameIt.placeholder}
          placeholderTextColor={colors.graphite}
          returnKeyType="done"
          // The keyboard stays up while it saves and if it did not. The field
          // is not made read-only meanwhile: that drops the keyboard on both
          // platforms, and a second save is already refused.
          submitBehavior="submit"
          autoCapitalize="sentences"
          accessibilityLabel={
            error
              ? `${strings.item.nameIt.a11y}, ${strings.forms.errorA11y(error)}`
              : strings.item.nameIt.a11y
          }
          maxFontSizeMultiplier={maxScale('body')}
          testID="item-name"
          style={[
            inputStyle,
            styles.input,
            { color: colors.ink, paddingVertical: thick ? 12 : 13 },
          ]}
        />
      </View>
      {error ? (
        <View style={styles.error} accessibilityLiveRegion="polite">
          <Icon name="warning" size={16} color={colors.signal} />
          <AppText variant="meta" tone="signal" weight={600} style={styles.errorText}>
            {error}
          </AppText>
        </View>
      ) : null}
      <Button
        label={strings.item.nameIt.save}
        onPress={() => void save()}
        size="sm"
        loading={saving}
        testID="item-name-it"
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: space.sm,
  },
  box: {
    minHeight: 52,
    borderRadius: radius.control,
    borderCurve: 'continuous',
    justifyContent: 'center',
  },
  input: {
    alignSelf: 'stretch',
  },
  error: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 6,
  },
  errorText: {
    flexShrink: 1,
  },
});
