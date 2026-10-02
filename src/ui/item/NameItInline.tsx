import { useEffect, useRef, useState, type Ref } from 'react';
import { AccessibilityInfo, Keyboard, Platform, StyleSheet, TextInput, View } from 'react-native';

import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
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
  /** The item as the screen last read it; each re-read brings its newer stamp. */
  item: { id: string; updatedAt: number };
  /**
   * The name the item has as last read, or '' while it has none. One that
   * arrives while the field is in use (recognition finishing, another phone)
   * is offered under the field, never put into it.
   */
  incomingName: string;
  /** Focus the field: in a filing run, once the screen has finished sliding in. */
  autoFocus: boolean;
  /** The "What is it?" heading, which a filing run gives screen-reader focus. */
  headingRef?: Ref<View>;
  /**
   * Whether the field is in use: focused, or holding typed text. While it is,
   * the screen keeps it, even once the item has a name.
   */
  onEngagedChange: (engaged: boolean) => void;
  /** The item now has this name: the one saved here, or the offered one, chosen. */
  onNamed: (name: string) => void;
}

/** Says it on iOS too, where VoiceOver does not read a polite live region. */
function announce(message: string) {
  if (Platform.OS === 'ios') AccessibilityInfo.announceForAccessibility(message);
}

/**
 * "What is it?" in place of the title of an item that has no name yet
 * (a Quick Snap photo), so naming it is one field and one tap on the item
 * screen rather than a trip through Edit details.
 *
 * The heading is a header, so the screen stays titled for VoiceOver; the
 * field is labelled "Name" for screen readers only. What is typed belongs to
 * this component, which the screen keys by item id and keeps while it is in
 * use, so neither a refetch nor a name arriving meanwhile takes it away.
 * Recognition often finishes while the owner is typing: its name is offered
 * ("Use “AA batteries”"), and "Save name" still saves what she typed.
 */
export function NameItInline({
  item,
  incomingName,
  autoFocus,
  headingRef,
  onEngagedChange,
  onNamed,
}: NameItInlineProps) {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const { colors } = useTheme();
  const inputStyle = useTextStyle('body');
  const inputRef = useRef<TextInput>(null);
  const savingRef = useRef(false);
  // Named: the field is on its way out, and a late blur must not keep it.
  const namedRef = useRef(false);
  const [value, setValue] = useState('');
  const [focused, setFocused] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // The name a save ran into, with its stamp, which the next save goes over.
  const [meanwhile, setMeanwhile] = useState<{ name: string; updatedAt: number } | null>(null);

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus();
  }, [autoFocus]);

  // The newest name it has: the one a save ran into, until the screen's re-read catches up.
  const theirs = meanwhile && meanwhile.updatedAt > item.updatedAt ? meanwhile.name : incomingName;
  const offered = theirs !== '' && theirs !== value.trim() ? theirs : null;
  let notice: string | null = null;
  if (offered) {
    notice = meanwhile
      ? strings.item.nameIt.namedMeanwhile(offered)
      : strings.item.nameIt.justNamed(offered);
  }

  useEffect(() => {
    if (notice) announce(notice);
  }, [notice]);

  /** Tells the screen whether the field is in use; no longer once it is named. */
  function engage(isFocused: boolean, text: string) {
    if (!namedRef.current) onEngagedChange(isFocused || text.trim() !== '');
  }

  function finish(name: string) {
    namedRef.current = true;
    // The field goes away with the keyboard still up on Android; focus
    // moves on to "File it…" or "Edit details" instead.
    Keyboard.dismiss();
    onNamed(name);
  }

  // Announced as it is set: an effect on `error` would stay silent when the
  // same message is set again.
  function showError(message: string) {
    setError(message);
    announce(message);
  }

  async function save() {
    const name = value.trim();
    if (!name) {
      showError(strings.forms.itemNameRequired);
      return;
    }
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    setError(null);

    // After a save ran into another name, saving again is the choice to keep
    // this one, so it goes over that name's stamp.
    const lock = Math.max(meanwhile?.updatedAt ?? 0, item.updatedAt);
    const outcome = await attemptName(repos.items, { id: item.id, updatedAt: lock }, name);
    savingRef.current = false;
    setSaving(false);

    if (outcome.kind === 'named') {
      logEvent('item_updated');
      finish(name);
      invalidate();
    } else if (outcome.kind === 'namedMeanwhile') {
      // The typed name and the keyboard stay; the notice offers theirs.
      haptics.warning();
      setMeanwhile({ name: outcome.name, updatedAt: outcome.updatedAt });
      invalidate();
    } else if (outcome.kind === 'gone') {
      // The screen re-reads, finds nothing and says the item is gone.
      invalidate();
    } else {
      const { kind } = describeError(outcome.cause, 'save', 'item');
      logError('item_name_failed', { errorClass: kind });
      haptics.error();
      showError(
        kind === 'offline' ? strings.item.nameIt.failedOffline : strings.item.nameIt.failed,
      );
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
            engage(focused, next);
          }}
          onFocus={() => {
            setFocused(true);
            engage(true, value);
          }}
          onBlur={() => {
            setFocused(false);
            engage(false, value);
          }}
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
      {notice ? (
        <View accessibilityLiveRegion="polite">
          <AppText variant="meta" tone="graphite">
            {notice}
          </AppText>
        </View>
      ) : null}
      <View style={styles.actions}>
        {/* Secondary: "File it…" below is the screen's one primary. */}
        <Button
          label={strings.item.nameIt.save}
          onPress={() => void save()}
          size="sm"
          variant="secondary"
          loading={saving}
          testID="item-name-it"
        />
        {offered ? (
          <Button
            label={strings.item.nameIt.useName(offered)}
            // Already its stored name: nothing to write.
            onPress={() => finish(offered)}
            size="sm"
            variant="secondary"
            disabled={saving}
            testID="item-name-use"
          />
        ) : null}
      </View>
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
  actions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: space.sm,
  },
});
