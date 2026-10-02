import { useRef, useState, type ReactElement } from 'react';
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  View,
  type TextInput,
} from 'react-native';
import { Stack, useLocalSearchParams, useNavigation, useRouter } from 'expo-router';
import { useHeaderHeight } from 'expo-router/react-navigation';

import { useDirtyGuard } from '@/hooks/useDirtyGuard';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { logError, logEvent } from '@/services/telemetry';
import { recordCategory } from '@/ui/categoryMemory';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { ErrorState } from '@/ui/components/ErrorState';
import { IconButton } from '@/ui/components/IconButton';
import {
  EMPTY_ITEM_FORM,
  ItemDetailsFields,
  validateItemForm,
  type ItemFormValues,
} from '@/ui/components/ItemForm';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { Skeleton } from '@/ui/components/Skeleton';
import { TextField } from '@/ui/components/TextField';
import { Thumb } from '@/ui/components/Thumb';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import {
  attemptDetails,
  detailsDirty,
  detailsSeed,
  keepsUnnamed,
  type DetailsBase,
} from '@/ui/item/itemDetails';
import { GUTTER, MIN_TOUCH_TARGET, space } from '@/ui/theme';

/** The "Name" label's line and the gap under it, above the input itself. */
const LABEL_LINE = 20;
const LABEL_GAP = 6;

/**
 * The sheet's top-left, as everywhere: "Cancel" on iOS, a close icon on
 * Android. It goes back like a swipe-down, so the dirty-form guard asks first.
 * Inert while saving, like the swipe-down and Android back then.
 */
function EditCancel({ disabled }: { disabled: boolean }) {
  const router = useRouter();
  if (Platform.OS === 'android') {
    return (
      <IconButton
        icon="close"
        accessibilityLabel={strings.common.close}
        onPress={() => router.back()}
        disabled={disabled}
        testID="edit-cancel"
      />
    );
  }
  return (
    <Pressable
      onPress={() => router.back()}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={strings.common.cancel}
      accessibilityState={{ disabled }}
      hitSlop={space.sm}
      testID="edit-cancel"
      style={({ pressed }) => [styles.cancel, { opacity: disabled ? 0.45 : pressed ? 0.6 : 1 }]}
    >
      <AppText variant="body">{strings.common.cancel}</AppText>
    </Pressable>
  );
}

/** Why the last save did not happen. */
type Problem = { kind: 'conflict' } | { kind: 'failed'; cause: unknown };

function ProblemBanner({ problem }: { problem: Problem }) {
  if (problem.kind === 'conflict') {
    return <Banner tone="warning" message={strings.editItem.conflict} live="assertive" />;
  }
  const described = describeError(problem.cause, 'save', 'item');
  return described.kind === 'offline' ? (
    <Banner tone="warning" title={described.title} message={described.body} live="assertive" />
  ) : (
    <Banner tone="warning" message={strings.editItem.notSaved} live="assertive" />
  );
}

/**
 * Edit details: name, category, tags and notes, all on screen at
 * once (existing tags and notes used to hide behind "More details").
 *
 * Quantity is not here: it saves itself on the item screen, and a seeded copy
 * in this form fought the stepper and conflicted with it. The
 * place is not here either; that is Move. The form is seeded once per item,
 * and saves with the lock it was seeded with, so a change made on another
 * phone meanwhile is reported rather than silently overwritten.
 */
export default function EditItemScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const navigation = useNavigation();
  const toast = useToast();
  const headerHeight = useHeaderHeight();
  const { fontScale, stacked } = useLayoutScale();

  const itemQuery = useInventoryQuery(() => repos.items.getById(id), `item:${id}`);
  const stored = itemQuery.data;

  const [values, setValues] = useState<ItemFormValues>(EMPTY_ITEM_FORM);
  // Seeded once per id, during render, so a background re-read never
  // overwrites typing. `base` is the version the save goes
  // over: the one the form was seeded from, or theirs after a conflict.
  const [seed, setSeed] = useState<{
    id: string;
    values: ItemFormValues;
    base: DetailsBase;
  } | null>(null);
  if (stored && seed?.id !== stored.id) {
    const seeded = detailsSeed(stored);
    setSeed({
      id: stored.id,
      values: seeded,
      base: { updatedAt: stored.updatedAt, values: seeded },
    });
    setValues(seeded);
  }

  const [nameError, setNameError] = useState<string | null>(null);
  const [problem, setProblem] = useState<Problem | null>(null);
  const [gone, setGone] = useState(false);
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);

  const nameRef = useRef<TextInput>(null);
  const categoryRef = useRef<TextInput>(null);
  const tagsRef = useRef<TextInput>(null);
  const notesRef = useRef<TextInput>(null);

  const dirty = seed !== null && detailsDirty(values, seed.values);
  useDirtyGuard(dirty && !gone, { saving });

  // An item still without a name (a Quick Snap photo) may stay that way.
  const nameOptional = seed?.values.name === '';

  async function save() {
    if (!stored || !seed || savingRef.current) return;
    const unnamed = keepsUnnamed(seed.values.name, values.name);
    // `validateItemForm` needs some name; an item that stays unnamed is
    // checked with a stand-in, and the name is left out of the write (an
    // explicitly blank name is refused by the repository).
    const { errors, parsed } = validateItemForm({
      ...values,
      name: unnamed ? strings.entities.unnamedItem : values.name,
      quantity: String(stored.quantity),
    });
    if (!parsed) {
      setNameError(errors.name ? strings.forms.itemNameRequired : null);
      nameRef.current?.focus();
      return;
    }

    savingRef.current = true;
    setSaving(true);
    setProblem(null);
    setNameError(null);
    const outcome = await attemptDetails(
      repos.items,
      id,
      {
        ...(unnamed ? {} : { name: parsed.name }),
        category: parsed.category,
        tags: parsed.tags,
        notes: parsed.notes,
      },
      seed.base,
    );

    if (outcome.kind === 'saved') {
      // Still "saving" while the sheet closes, so the dirty-form guard lets it
      // go and a second tap cannot save again.
      logEvent('item_updated');
      recordCategory(parsed.category);
      // Only from the front: closed some other way mid-save (the removed-phone
      // layer closes every sheet), back would pop the item screen underneath.
      if (navigation.isFocused()) router.back();
      invalidate();
      toast.show({ message: strings.editItem.saved });
      return;
    }

    savingRef.current = false;
    setSaving(false);
    if (outcome.kind === 'gone') {
      // Deleted on another phone meanwhile: nothing to save into.
      haptics.error();
      setGone(true);
    } else if (outcome.kind === 'conflict') {
      // Someone else changed these details first: keep what was typed, save
      // over their version next time, and say so.
      const theirs = outcome.base;
      setSeed((current) => (current ? { ...current, base: theirs } : current));
      haptics.warning();
      setProblem({ kind: 'conflict' });
    } else {
      logError('item_update_failed', { errorClass: describeError(outcome.cause, 'save').kind });
      haptics.error();
      setProblem({ kind: 'failed', cause: outcome.cause });
    }
  }

  const header = <Stack.Screen options={{ headerLeft: () => <EditCancel disabled={saving} /> }} />;

  if (gone || stored === null) {
    let state: ReactElement;
    if (!gone && itemQuery.cause) {
      state = <ErrorState cause={itemQuery.cause} subject="item" onRetry={itemQuery.reload} />;
    } else if (!gone && itemQuery.loading) {
      state = (
        <View style={styles.skeleton}>
          <Skeleton variant="detail" />
        </View>
      );
    } else {
      state = (
        <ErrorState
          cause={null}
          subject="item"
          secondary={{ label: strings.common.close, onPress: () => router.back() }}
        />
      );
    }
    return (
      <ScreenFrame kind="modal">
        {header}
        {state}
      </ScreenFrame>
    );
  }

  const photo = stored.photoThumbUri ?? stored.photoUri;

  return (
    <ScreenFrame kind="modal">
      {header}
      <KeyboardAvoidingView
        behavior="padding"
        keyboardVerticalOffset={headerHeight}
        style={styles.fill}
      >
        {/* Above the fields, so it is seen whatever was scrolled to. */}
        {problem ? (
          <View style={styles.notice}>
            <ProblemBanner problem={problem} />
          </View>
        ) : null}
        <ScrollView
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={styles.content}
          style={styles.fill}
        >
          {/* The photo beside the name it goes with, so it does not read as an empty slot. */}
          <View style={stacked ? styles.nameStacked : styles.nameRow}>
            {photo ? (
              // Level with the input rather than its label.
              <View
                style={
                  stacked ? null : { marginTop: Math.round(LABEL_LINE * fontScale) + LABEL_GAP }
                }
              >
                {/* Read only: photos of existing items cannot be replaced yet. */}
                <Thumb uri={photo} size={56} />
              </View>
            ) : null}
            <View style={stacked ? null : styles.fill}>
              <TextField
                label={strings.editItem.nameLabel}
                value={values.name}
                onChangeText={(name) => {
                  setValues({ ...values, name });
                  if (nameError) setNameError(null);
                }}
                placeholder={strings.item.nameIt.placeholder}
                required={!nameOptional}
                error={nameError}
                autoCapitalize="sentences"
                inputRef={nameRef}
                nextRef={categoryRef}
                testID="item-name"
              />
            </View>
          </View>
          <ItemDetailsFields
            values={values}
            onChange={setValues}
            refs={{ category: categoryRef, tags: tagsRef, notes: notesRef }}
          />
        </ScrollView>
        <BottomBar>
          <Button
            label={strings.editItem.save}
            onPress={() => void save()}
            loading={saving}
            fullWidth
            testID="item-save-changes"
          />
        </BottomBar>
      </KeyboardAvoidingView>
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  skeleton: {
    padding: GUTTER,
  },
  notice: {
    paddingHorizontal: GUTTER,
    paddingTop: space.md,
  },
  content: {
    padding: GUTTER,
    paddingBottom: space.xl,
    gap: space.lg,
  },
  nameRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: space.md,
  },
  nameStacked: {
    gap: space.lg,
  },
  cancel: {
    minHeight: MIN_TOUCH_TARGET,
    justifyContent: 'center',
  },
});
