import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import {
  Animated,
  BackHandler,
  Keyboard,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  View,
  useWindowDimensions,
  type TextInput,
} from 'react-native';
import {
  Stack,
  useLocalSearchParams,
  useNavigation,
  useRouter,
  type NativeStackNavigationProp,
} from 'expo-router';
import {
  useHeaderHeight,
  usePreventRemove,
  type ParamListBase,
} from 'expo-router/react-navigation';

import { parseQuantityInput } from '@/core/quantity';
import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { Item } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useRecentPlaces } from '@/hooks/useRecentPlaces';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { recognizeItem } from '@/services/ai/recognition';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { rememberPlace } from '@/services/places/recentPlaces';
import { logError, logEvent } from '@/services/telemetry';
import { clearDraft, discardStaleDraft, keepDraft, restorableDraft } from '@/ui/add/addDraft';
import {
  containerTitle,
  entryId,
  formHasContent,
  hasDetails,
  initialAddState,
  joinPlaceOptions,
  photoFiles,
  photoFromStored,
  resolvePlace,
  saveA11yLabel,
  savedMessage,
  whereEntries,
  type AddPhoto,
  type WhereEntry,
} from '@/ui/add/addSheet';
import { WhereList } from '@/ui/add/WhereList';
import { recordCategory } from '@/ui/categoryMemory';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { IconButton } from '@/ui/components/IconButton';
import {
  EMPTY_ITEM_FORM,
  ItemDetailsFields,
  applySuggestion,
  validateItemForm,
  type ItemFormValues,
} from '@/ui/components/ItemForm';
import { PlacePicker, type PickedPlace, type PlaceOption } from '@/ui/components/PlacePicker';
import { QuantityStepper } from '@/ui/components/QuantityStepper';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import {
  SuggestionBanner,
  staleSuggestionName,
  type SuggestionState,
} from '@/ui/components/SuggestionBanner';
import { TextField } from '@/ui/components/TextField';
import { Thumb } from '@/ui/components/Thumb';
import { confirm, showActionSheet } from '@/ui/confirm';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { duration, easing, useReducedMotion } from '@/ui/motion';
import type { PhotoResult } from '@/ui/navigation';
import { openForResult } from '@/ui/routeResult';
import { GUTTER, MIN_TOUCH_TARGET, space } from '@/ui/theme';

/** Longest the sheet's slide-up is waited for before the name field is focused anyway. */
const ARRIVAL_FALLBACK_MS = 700;

type Step = 'form' | 'place';

/**
 * The sheet's top-left, as on every sheet: "Cancel" on iOS, a close icon on
 * Android. Unlike a swipe-down or Back, which keep the draft, it asks before
 * throwing away what was typed.
 */
function AddCancel({ onPress }: { onPress: () => void }) {
  if (Platform.OS === 'android') {
    return (
      <IconButton
        icon="close"
        accessibilityLabel={strings.common.close}
        onPress={onPress}
        testID="add-cancel"
      />
    );
  }
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={strings.common.cancel}
      hitSlop={space.sm}
      testID="add-cancel"
      style={({ pressed }) => [styles.cancel, { opacity: pressed ? 0.6 : 1 }]}
    >
      <AppText variant="body">{strings.common.cancel}</AppText>
    </Pressable>
  );
}

/** Why the last save did not happen, in plain words (B8: it used to be the raw message). */
function SaveProblem({ cause }: { cause: unknown }) {
  // A 404 here means the container went, not the item.
  const described = describeError(cause, 'save', 'container');
  return (
    <Banner
      tone="warning"
      // A failed local write has no "could not be read" title; its body says it all.
      title={described.kind === 'local' ? undefined : described.title}
      message={described.body}
      live="assertive"
      testID="add-save-problem"
    />
  );
}

/**
 * Add an item (spec §5.9): a name is enough. The place defaults to the drop
 * zone, the container it was opened from and the last few places are one tap
 * each, and "Somewhere else…" swaps the sheet to the full place picker. The
 * keyboard's return key saves, so "add AA batteries somewhere" is Add, type,
 * return (§6.4). Before this, adding needed a container first and Save sat
 * under the keyboard (entities §16.A).
 *
 * A photo is optional. When there is one, recognition runs in the background
 * and only fills blanks; it never blocks saving and never overwrites typing
 * (issues #7, #13; entities §14.7).
 *
 * Nothing typed is lost to a stray swipe: the sheet keeps a draft (`addDraft`)
 * that the next plain open of Add restores. The draft owns the photo until the
 * item is saved, so a photo nobody kept is deleted, never left behind.
 */
export default function AddItemScreen() {
  const params = useLocalSearchParams<{
    containerId?: string;
    name?: string;
    photoUri?: string;
    photoThumbUri?: string;
    photoWidth?: string;
    photoHeight?: string;
    photoBytes?: string;
  }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const navigation = useNavigation<NativeStackNavigationProp<ParamListBase>>();
  const toast = useToast();
  const headerHeight = useHeaderHeight();
  const { height: windowHeight } = useWindowDimensions();
  // The form's height, for where its top sits on screen (see `keyboardOffset`).
  const [bodyHeight, setBodyHeight] = useState(0);
  const reduceMotion = useReducedMotion();
  // Which sheet wrote the draft: only this one may clear it.
  const owner = useId();

  const [initial] = useState(() =>
    initialAddState(params, restorableDraft(Date.now()), EMPTY_ITEM_FORM),
  );
  const [values, setValues] = useState<ItemFormValues>(initial.values);
  const [placeId, setPlaceId] = useState(initial.placeId);
  const [picked, setPicked] = useState<PlaceOption | null>(initial.picked);
  const [photo, setPhoto] = useState<AddPhoto | null>(initial.photo);
  const [suggestion, setSuggestion] = useState<SuggestionState>(initial.suggestion);
  const [showMore, setShowMore] = useState(initial.showMore);
  // The details as they were when "More details" was closed over them; a
  // suggestion that changes them opens it again (AI changes are never hidden).
  const [collapsedAt, setCollapsedAt] = useState<string | null>(null);
  const [restored, setRestored] = useState(initial.restored);
  const [step, setStep] = useState<Step>('form');
  const [saving, setSaving] = useState<'save' | 'another' | null>(null);
  const [nameError, setNameError] = useState<string | null>(null);
  const [problem, setProblem] = useState<{ cause: unknown } | null>(null);
  // "Saved. Add the next one." under the name, until the next name is typed.
  const [savedNext, setSavedNext] = useState(false);
  const [fade] = useState(() => new Animated.Value(1));

  const savingRef = useRef(false);
  // The camera is open for this sheet: a second tap must not stack another.
  const cameraOpenRef = useRef(false);
  // The photo recognition is running for; an answer about another one is dropped.
  const recognitionRef = useRef<string | null>(null);
  const scrollRef = useRef<ScrollView>(null);
  const nameRef = useRef<TextInput>(null);
  const categoryRef = useRef<TextInput>(null);
  const tagsRef = useRef<TextInput>(null);
  const notesRef = useRef<TextInput>(null);

  // Every container with its space, for the recent places, the one the sheet
  // was opened for and the toast. Containers only: no photos are fetched.
  const recentIds = useRecentPlaces();
  const places = useInventoryQuery(async () => {
    const [containers, spaces] = await Promise.all([
      repos.containers.listAllWithSpace(),
      repos.spaces.listWithCounts(),
    ]);
    return joinPlaceOptions(containers, spaces);
  }, 'add-places');
  const options = useMemo(
    () => (places.data ? new Map(places.data.map((option) => [option.id, option])) : null),
    [places.data],
  );

  const paramId =
    params.containerId && params.containerId !== DROP_ZONE_CONTAINER_ID ? params.containerId : null;
  const paramOption = paramId ? (options?.get(paramId) ?? null) : null;
  const place = resolvePlace(placeId, options, picked);
  const entries = whereEntries({
    param: paramOption,
    recentIds,
    options: options ?? new Map(),
    selectedId: place.id,
    picked,
  });

  const typedName = values.name.trim();
  const hasContent = formHasContent(values, photo, EMPTY_ITEM_FORM);
  const staleName = staleSuggestionName(suggestion, typedName);
  const detailsKey = [values.category, values.tags, values.notes].join('\u0000');
  const detailsShown = showMore || (hasDetails(values) && detailsKey !== collapsedAt);

  // A plain open that found no fresh draft throws away a stale one, photo and all.
  useEffect(() => {
    if (!initial.restored) discardStaleDraft(Date.now());
  }, [initial.restored]);

  // The draft follows every change, so a swipe-down or Back keeps it.
  useEffect(() => {
    keepDraft(
      owner,
      hasContent
        ? { values, placeId, picked, photo, suggestion, showMore, savedAt: Date.now() }
        : null,
    );
  }, [hasContent, owner, photo, picked, placeId, showMore, suggestion, values]);

  /**
   * Sets only terminal states; `running` and `refreshing` are set by whoever
   * starts it.
   *
   * @param nameHint The name the user typed; asks the backend to describe
   *   *that* item instead of repeating its own identification.
   * @param overwrite Replace the supporting fields rather than filling the
   *   blanks. Only for an explicit "update the other details": those fields
   *   were derived from an identification the user has since rejected. A hint
   *   alone never implies this — a retry can be name-anchored without being
   *   allowed to discard what the user typed.
   */
  const runRecognition = useCallback(async (uri: string, nameHint?: string, overwrite = false) => {
    recognitionRef.current = uri;
    const result = await recognizeItem({ imageUri: uri, nameHint });
    if (recognitionRef.current !== uri) return;

    if (result.status === 'failed') {
      setSuggestion({ status: 'failed', reason: result.reason });
      return;
    }

    setValues((current) => applySuggestion(current, result.suggestion, { overwrite }));

    // Record which name the details now describe, so a further edit to the
    // title is recognised as making them stale again.
    setSuggestion(
      overwrite && nameHint
        ? // The hint, not the echoed name: this is the title now in the field,
          // so a backend that ignored the hint cannot leave the banner asking
          // to refresh a name it just refreshed.
          { status: 'refreshed', forName: nameHint }
        : {
            status: 'applied',
            confidence: result.suggestion.confidence,
            forName: result.suggestion.name ?? '',
          },
    );
  }, []);

  useEffect(() => {
    // Kicking off an async request on arrival is what effects are for. The rule
    // flags this because `runRecognition` transitively calls setState, but it
    // only does so after awaiting the network call — never synchronously in
    // this effect body, so no cascading render occurs. A restored draft whose
    // recognition was cut off starts again, anchored to the typed name.
    const arrived = initial.recognize ? initial.photo : null;
    if (!arrived) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void runRecognition(arrived.uri, initial.values.name.trim() || undefined);
  }, [initial, runRecognition]);

  // The cursor waits in "What is it?" once the sheet is up (focusing during the
  // slide makes the keyboard fight it). Not with a photo: the suggestion may
  // name it.
  const focusOnArrival = initial.photo === null;
  useEffect(() => {
    if (!focusOnArrival) return;
    let done = false;
    const focus = () => {
      if (done) return;
      done = true;
      // Not if the camera or the place picker's form is already on top: the
      // keyboard would come up behind it.
      if (navigation.isFocused()) nameRef.current?.focus();
    };
    const unsubscribe = navigation.addListener('transitionEnd', (event) => {
      if (!event.data.closing) focus();
    });
    const timer = setTimeout(focus, ARRIVAL_FALLBACK_MS);
    return () => {
      done = true;
      unsubscribe();
      clearTimeout(timer);
    };
  }, [focusOnArrival, navigation]);

  /** Between the form and the place picker: a short cross-fade, none with reduced motion. */
  function showStep(next: Step) {
    if (next === 'place') Keyboard.dismiss();
    if (!reduceMotion) fade.setValue(0);
    setStep(next);
    if (!reduceMotion) {
      Animated.timing(fade, {
        toValue: 1,
        duration: duration.stepSwap,
        easing: easing.out,
        useNativeDriver: true,
      }).start();
    }
  }

  // Back, a swipe-down or Android back in the place step return to the form
  // without changing the place.
  usePreventRemove(step === 'place', () => showStep('form'));

  // While saving, the sheet stays put (iOS: `gestureEnabled` below). A sheet
  // closed mid-save would leave its draft for the next Add to restore while
  // the item already owns the photo, and the save's own Back would then pop
  // whatever was underneath.
  useEffect(() => {
    if (saving === null) return;
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => true);
    return () => subscription.remove();
  }, [saving]);

  function edit(next: ItemFormValues) {
    setValues(next);
    if (nameError && next.name.trim()) setNameError(null);
    if (savedNext && next.name.trim()) setSavedNext(false);
  }

  function choose(entry: WhereEntry) {
    haptics.choice();
    setPlaceId(entryId(entry));
  }

  function pickPlace(chosen: PickedPlace) {
    if (chosen.kind === 'dropZone') {
      setPlaceId(DROP_ZONE_CONTAINER_ID);
    } else {
      setPlaceId(chosen.option.id);
      setPicked(chosen.option);
    }
    showStep('form');
  }

  function toggleDetails() {
    if (detailsShown) {
      setShowMore(false);
      setCollapsedAt(detailsKey);
    } else {
      setShowMore(true);
    }
  }

  /** Deletes the photo's files (both) and forgets it. */
  function dropPhoto() {
    recognitionRef.current = null;
    deleteStoredPhotos(photoFiles(photo));
    setPhoto(null);
    setSuggestion({ status: 'idle' });
  }

  /** Single-mode camera; the photo comes back through `routeResult` (S6's `request` contract). */
  async function takePhoto() {
    if (savingRef.current || cameraOpenRef.current) return;
    cameraOpenRef.current = true;
    Keyboard.dismiss();
    let taken: PhotoResult | undefined;
    try {
      taken = await openForResult<PhotoResult>((request) =>
        router.push({
          pathname: '/capture',
          params: { containerId: place.id, mode: 'single', request },
        }),
      );
    } finally {
      cameraOpenRef.current = false;
    }
    if (!taken) return;
    const next = photoFromStored(taken);
    setPhoto(next);
    setSuggestion({ status: 'running' });
    void runRecognition(next.uri, typedName || undefined);
  }

  function photoOptions() {
    if (savingRef.current) return;
    showActionSheet({
      options: [
        {
          label: strings.add.retake,
          onPress: () => {
            dropPhoto();
            void takePhoto();
          },
        },
        { label: strings.add.removePhoto, destructive: true, onPress: dropPhoto },
      ],
    });
  }

  /** The draft notice's "Clear": its photo goes too. */
  function clearRestored() {
    if (savingRef.current) return;
    dropPhoto();
    setValues(EMPTY_ITEM_FORM);
    setPlaceId(DROP_ZONE_CONTAINER_ID);
    setPicked(null);
    setShowMore(false);
    setCollapsedAt(null);
    setRestored(false);
    setNameError(null);
    setProblem(null);
    nameRef.current?.focus();
  }

  async function cancel() {
    if (savingRef.current) return;
    if (hasContent) {
      const discard = await confirm({
        title: strings.add.discardTitle,
        body: strings.add.discardBody,
        confirmLabel: strings.forms.discard,
        cancelLabel: strings.forms.keepEditing,
      });
      if (!discard) return;
      // Cancelling after a capture used to leave the photo on the phone (capture §13.8).
      recognitionRef.current = null;
      deleteStoredPhotos(photoFiles(photo));
    }
    clearDraft(owner);
    router.back();
  }

  function snapSeveral() {
    if (savingRef.current) return;
    Keyboard.dismiss();
    // What was typed stays in the draft for the next Add.
    router.replace({ pathname: '/capture', params: { containerId: place.id, mode: 'fast' } });
  }

  /** After "Save and add another" without a photo: same place, empty form, cursor back in the name. */
  function startNext() {
    setValues(EMPTY_ITEM_FORM);
    setSuggestion({ status: 'idle' });
    setShowMore(false);
    setCollapsedAt(null);
    setRestored(false);
    scrollRef.current?.scrollTo({ y: 0, animated: !reduceMotion });
    nameRef.current?.focus();
  }

  /** Undo from the toast: the item goes again, and so does its photo. */
  async function undoAdd(itemId: string, addedPhoto: AddPhoto | null) {
    try {
      const result = await repos.items.delete(itemId);
      // Paired, the household reports its own copies; the files this phone
      // took are removed here as well.
      deleteStoredPhotos([...result.orphanedPhotoUris, ...photoFiles(addedPhoto)]);
      logEvent('item_deleted');
      invalidate();
      haptics.undo();
      toast.show({ message: strings.add.removedAgain });
    } catch (cause) {
      const kind = describeError(cause, 'delete', 'item').kind;
      logError('item_delete_failed', { errorClass: kind });
      haptics.error();
      toast.show({ message: strings.add.undoFailed(kind === 'offline'), tone: 'error' });
    }
  }

  /**
   * @param andAnother Stay for the next one. Adding things off a shelf is a
   *   run, not a single errand (`5dc203e`): with a photo the camera opens
   *   again for the same place; typed, the form empties and keeps the place.
   */
  async function save(andAnother: boolean) {
    if (savingRef.current) return;
    const { errors, parsed } = validateItemForm(values);
    if (!parsed) {
      if (errors.name) {
        setNameError(strings.add.nameRequired);
        nameRef.current?.focus();
      }
      return;
    }

    const target = place;
    const addedPhoto = photo;
    savingRef.current = true;
    setSaving(andAnother ? 'another' : 'save');
    setProblem(null);
    setSavedNext(false);
    let item: Item;
    try {
      // Item, photo and tags in one write (`items.ts` create is atomic).
      item = await repos.items.create({
        containerId: target.id,
        ...parsed,
        photo: addedPhoto,
      });
    } catch (cause) {
      const described = describeError(cause, 'save', 'container');
      logError('item_create_failed', { errorClass: described.kind });
      haptics.error();
      savingRef.current = false;
      setSaving(null);
      // Normally the banner; a sheet closed under the save (the removed-phone
      // layer) still says it did not happen, and the draft keeps the typing.
      if (navigation.isFocused()) setProblem({ cause });
      else toast.show({ message: described.body, tone: 'error' });
      return;
    }

    // Only the write is guarded above: once it is done, nothing below may
    // report "not saved".
    logEvent('item_created', {
      hasPhoto: addedPhoto !== null,
      suggestionAccepted: suggestion.status === 'applied' || suggestion.status === 'refreshed',
      hinted: suggestion.status === 'refreshed',
    });
    // The item owns the photo now.
    clearDraft(owner);
    invalidate();
    haptics.success();
    void rememberPlace(target.id);
    recordCategory(parsed.category);

    const here = navigation.isFocused();
    if (andAnother && !addedPhoto && here) {
      // Typed: stay for the next one. Only this path re-arms Save; the others
      // leave the sheet, and a second tap or return while it slides away would
      // otherwise add the item twice.
      savingRef.current = false;
      setSaving(null);
      startNext();
      // Said in the sheet, not as a toast: the name field has the keyboard up
      // again, and a toast sits at the bottom of the screen, behind it (the
      // R5 fallback for feedback inside a modal).
      setSavedNext(true);
      return;
    }
    if (andAnother && addedPhoto && here) {
      // `replace`: the saved form must not sit under the camera.
      router.replace({ pathname: '/capture', params: { containerId: target.id } });
      return;
    }

    // Back to wherever Add was opened from; the toast says where it went.
    if (here) router.back();
    let undone = false;
    toast.show({
      message: savedMessage(target),
      action: {
        label: strings.common.undo,
        accessibilityLabel: strings.add.undoA11y(parsed.name),
        onPress: () => {
          // Once, even if Undo is tapped again while the toast fades.
          if (undone) return;
          undone = true;
          void undoAdd(item.id, addedPhoto);
        },
      },
    });
  }

  const title =
    step === 'place'
      ? strings.add.placeTitle
      : paramOption
        ? strings.add.titleTo(containerTitle(paramOption))
        : strings.add.title;

  const header = (
    <Stack.Screen
      options={{
        title,
        // A swipe-down keeps the draft, except mid-save (see the back handler).
        gestureEnabled: saving === null,
        headerLeft: () =>
          step === 'place' ? (
            <Button
              label={strings.add.back}
              icon="back"
              variant="quiet"
              size="sm"
              onPress={() => showStep('form')}
              testID="add-back"
            />
          ) : (
            <AddCancel onPress={() => void cancel()} />
          ),
      }}
    />
  );

  if (step === 'place') {
    return (
      <ScreenFrame kind="modal">
        {header}
        <Animated.View style={[styles.fill, { opacity: fade }]}>
          <PlacePicker
            mode="choose"
            showDropZone
            selectedContainerId={place.id}
            onPick={pickPlace}
          />
        </Animated.View>
      </ScreenFrame>
    );
  }

  const quantity = parseQuantityInput(values.quantity) ?? 1;
  // `KeyboardAvoidingView` wants the distance from the top of the screen to
  // the form. An iPhone page sheet starts below the status bar, which the
  // header height leaves out, so that offset alone would leave Save under the
  // keyboard (entities §16.A). The sheet reaches the bottom of the screen, so
  // the form's top is the window less its height. Elsewhere (Android's
  // full-screen sheet, iPad) the header height is the distance (spec §4.25).
  const keyboardOffset =
    Platform.OS === 'ios' && !Platform.isPad && bodyHeight > 0
      ? windowHeight - bodyHeight
      : headerHeight;

  return (
    <ScreenFrame kind="modal">
      {header}
      <Animated.View
        onLayout={(event) => setBodyHeight(event.nativeEvent.layout.height)}
        style={[styles.fill, { opacity: fade }]}
      >
        <KeyboardAvoidingView
          behavior="padding"
          keyboardVerticalOffset={keyboardOffset}
          style={styles.fill}
        >
          {/* Above the fields, so it is seen whatever was scrolled to. */}
          {problem ? (
            <View style={styles.notice}>
              <SaveProblem cause={problem.cause} />
            </View>
          ) : null}
          <ScrollView
            ref={scrollRef}
            keyboardShouldPersistTaps="handled"
            contentContainerStyle={styles.content}
            style={styles.fill}
          >
            {restored ? (
              <Banner
                tone="info"
                message={strings.add.draft}
                action={{
                  label: strings.add.clearDraft,
                  onPress: clearRestored,
                  testID: 'add-draft-clear',
                }}
                testID="add-draft"
              />
            ) : null}

            <TextField
              label={strings.add.nameLabel}
              accessibilityLabel={strings.add.nameA11y}
              placeholder={strings.add.namePlaceholder}
              value={values.name}
              onChangeText={(name) => edit({ ...values, name })}
              error={nameError}
              autoCapitalize="sentences"
              // Return saves; the keyboard stays up while it does, and if it did not.
              returnKeyType="done"
              submitBehavior="submit"
              onSubmitEditing={() => void save(false)}
              inputRef={nameRef}
              testID="item-name"
              trailing={
                photo ? (
                  <Thumb
                    uri={photo.thumbUri ?? photo.uri}
                    size={48}
                    onPress={photoOptions}
                    accessibilityLabel={strings.add.photoOptions}
                    testID="item-photo-options"
                  />
                ) : (
                  <IconButton
                    icon="camera"
                    accessibilityLabel={strings.add.addPhoto}
                    onPress={() => void takePhoto()}
                    testID="item-photo-take"
                  />
                )
              }
            />

            {/* Under the field, so the field itself does not move while typing. */}
            {savedNext ? (
              <Banner
                tone="info"
                icon="check"
                message={strings.add.savedNext}
                testID="add-saved-next"
              />
            ) : null}

            {photo ? (
              <SuggestionBanner
                state={staleName ? { status: 'stale', forName: staleName } : suggestion}
                onRetry={() => {
                  setSuggestion({ status: 'running' });
                  // A name typed before the retry anchors it: there is no
                  // reason to ask the photo alone when the user has already
                  // said what the thing is.
                  void runRecognition(photo.uri, typedName || undefined);
                }}
                onRefresh={
                  staleName
                    ? () => {
                        setSuggestion({ status: 'refreshing' });
                        void runRecognition(photo.uri, staleName, true);
                      }
                    : undefined
                }
              />
            ) : null}

            <View style={styles.group}>
              <AppText variant="label">{strings.add.where}</AppText>
              {/* Never a silent short list (§5.0): without the read, the
                  container it was opened for and the recent places are missing. */}
              {places.cause !== null && places.data === null ? (
                <Banner
                  tone="info"
                  message={strings.add.placesFailed}
                  action={{
                    label: strings.common.tryAgain,
                    onPress: places.reload,
                    testID: 'add-places-retry',
                  }}
                />
              ) : null}
              <WhereList
                entries={entries}
                selectedId={place.id}
                onSelect={choose}
                onMore={() => {
                  if (!savingRef.current) showStep('place');
                }}
              />
            </View>

            <View style={styles.howMany}>
              <AppText variant="label" style={styles.howManyLabel}>
                {strings.add.howMany}
              </AppText>
              <QuantityStepper
                size="compact"
                value={quantity}
                // From the latest values: a hold-repeat keeps calling the
                // handler it started with, and a suggestion landing meanwhile
                // must not be undone by it.
                onChange={(next) =>
                  setValues((current) => ({ ...current, quantity: String(next) }))
                }
                itemName={typedName || undefined}
                // Save sits outside the scroll view, so tapping it does not
                // leave the number: a typed count is taken as it is typed.
                commitWhileTyping
              />
            </View>

            <View style={styles.group}>
              <Button
                label={strings.forms.moreDetails}
                accessibilityLabel={strings.forms.moreDetailsA11y(detailsShown)}
                icon={detailsShown ? 'chevronDown' : 'chevronRight'}
                variant="quiet"
                onPress={toggleDetails}
                testID="item-more-details"
              />
              {detailsShown ? (
                <ItemDetailsFields
                  values={values}
                  onChange={edit}
                  refs={{ category: categoryRef, tags: tagsRef, notes: notesRef }}
                />
              ) : null}
            </View>

            <Button
              label={strings.add.snapSeveral}
              icon="layers"
              variant="quiet"
              onPress={snapSeveral}
              testID="item-snap-several"
            />
          </ScrollView>
          <BottomBar>
            <Button
              label={strings.add.saveAndAnother}
              variant="secondary"
              fullWidth
              loading={saving === 'another'}
              disabled={saving === 'save'}
              onPress={() => void save(true)}
              testID="item-save-and-add"
            />
            <Button
              label={strings.add.save}
              accessibilityLabel={saveA11yLabel(place)}
              fullWidth
              loading={saving === 'save'}
              disabled={saving === 'another'}
              onPress={() => void save(false)}
              testID="item-save"
            />
          </BottomBar>
        </KeyboardAvoidingView>
      </Animated.View>
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  notice: {
    paddingHorizontal: GUTTER,
    paddingTop: space.md,
  },
  content: {
    padding: GUTTER,
    paddingBottom: space.xl,
    gap: space.xl,
  },
  group: {
    gap: space.sm,
  },
  howMany: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.sm,
  },
  howManyLabel: {
    flexShrink: 1,
  },
  cancel: {
    minHeight: MIN_TOUCH_TARGET,
    justifyContent: 'center',
  },
});
