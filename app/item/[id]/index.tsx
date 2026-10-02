import { useEffect, useRef, useState, type ReactElement } from 'react';
import { AccessibilityInfo, Platform, ScrollView, StyleSheet, View } from 'react-native';
import {
  Stack,
  useLocalSearchParams,
  useNavigation,
  useRouter,
  type NativeStackNavigationProp,
} from 'expo-router';
import type { ParamListBase } from 'expo-router/react-navigation';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { ItemWithContext } from '@/db/types';
import { useCollapsingTitle } from '@/hooks/useCollapsingTitle';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { useNow } from '@/hooks/useNow';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { useToast } from '@/providers/ToastProvider';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logError, logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { Button } from '@/ui/components/Button';
import { ErrorState } from '@/ui/components/ErrorState';
import { IconButton } from '@/ui/components/IconButton';
import { Chip } from '@/ui/components/pickers/Chip';
import { SavedQuantityStepper } from '@/ui/components/SavedQuantityStepper';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { FactRow } from '@/ui/components/SettingsRow';
import { Sheet } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { Thumb } from '@/ui/components/Thumb';
import { confirm } from '@/ui/confirm';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { itemStamp } from '@/ui/item/itemDetails';
import { nextInRun, runPosition } from '@/ui/item/moveFlow';
import { NameItInline } from '@/ui/item/NameItInline';
import { WhereCard } from '@/ui/item/WhereCard';
import { focusSearch, goToTab, type MoveResult } from '@/ui/navigation';
import { openForResult } from '@/ui/routeResult';
import { GUTTER, space, useTheme } from '@/ui/theme';

/** Longest a pushed screen's slide-in is waited for before focusing anyway. */
const TRANSITION_FALLBACK_MS = 700;

function HeaderSearch() {
  return (
    <IconButton
      icon="search"
      accessibilityLabel={strings.a11y.searchHousehold}
      accessibilityHint={strings.a11y.searchHint}
      onPress={focusSearch}
    />
  );
}

/** "2 of 5 waiting" in the header of a filing run, until the item's name scrolls under it. */
function RunProgress({ label }: { label: string }) {
  return (
    <AppText variant="caption" tone="graphite" numberOfLines={1}>
      {label}
    </AppText>
  );
}

/** Moves VoiceOver or TalkBack focus to a control; the web has no such call. */
function focusForScreenReader(target: View | null) {
  if (target && Platform.OS !== 'web') AccessibilityInfo.sendAccessibilityEvent(target, 'focus');
}

/** A failed refresh with the item still on screen; the connection banner covers offline. */
function needsRefreshBanner(refreshFailed: boolean, cause: unknown): boolean {
  if (!refreshFailed) return false;
  const { kind } = describeError(cause);
  return kind !== 'offline' && kind !== 'revoked';
}

/**
 * One item: where it is first, then the small edits (spec §5.10).
 *
 * The "Kept in" path is the largest text on the screen; the photo is a
 * thumbnail beside the name that opens full screen, rather than a 260 pt
 * picture pushing the answer down. Quantity saves itself. Move is on every
 * item, not only on drop-zone ones (entities §16.C), and ends in a toast with
 * Undo while this screen stays put.
 *
 * `filing=1` is a filing run from the Drop zone (the desk's "runs, not
 * errands"): the header counts what is waiting, an unnamed item's name field
 * is focused, and after "File it…" the screen replaces itself with the next
 * waiting item, or goes back once everything is filed.
 */
export default function ItemScreen() {
  const params = useLocalSearchParams<{ id: string; filing?: string }>();
  const { id } = params;
  const filing = params.filing === '1';
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const household = useHousehold();
  const router = useRouter();
  const navigation = useNavigation<NativeStackNavigationProp<ParamListBase>>();
  const toast = useToast();
  const { colors } = useTheme();
  const { stacked } = useLayoutScale();
  const insets = useSafeAreaInsets();
  const now = useNow(60_000);

  const itemQuery = useInventoryQuery(() => repos.items.getById(id), `item:${id}`);
  // Only a filing run reads the drop zone: for "2 of 5" and the next item.
  const dropZone = useInventoryQuery(
    () => (filing ? repos.items.listUnsorted() : Promise.resolve(null)),
    filing ? 'drop-zone' : 'drop-zone:unused',
  );
  const stored = itemQuery.data;
  const waitingIds = (dropZone.data ?? []).map((waiting) => waiting.id);

  // A name saved here shows at once, before the re-read brings it back.
  const [namedHere, setNamedHere] = useState<{ id: string; name: string } | null>(null);
  const name = stored?.name || (namedHere?.id === id ? namedHere.name : '');
  const item: ItemWithContext | null = stored ? { ...stored, name } : null;
  const inDropZone = item?.containerId === DROP_ZONE_CONTAINER_ID;

  const { onScroll, onTitleLayout, collapsed } = useCollapsingTitle(
    name || strings.entities.unnamedItem,
  );

  const [deleting, setDeleting] = useState(false);
  const busyRef = useRef(false);
  const titleRef = useRef<View>(null);
  const fileRef = useRef<View>(null);
  const editRef = useRef<View>(null);
  const focusAfterNameRef = useRef(false);
  const focusedTitleRef = useRef(false);

  // In a filing run the name field and screen-reader focus wait for the
  // slide-in to finish: focusing mid-animation makes the keyboard fight it.
  const [arrived, setArrived] = useState(false);
  useEffect(() => {
    if (!filing) return;
    const unsubscribe = navigation.addListener('transitionEnd', (event) => {
      if (!event.data.closing) setArrived(true);
    });
    const timer = setTimeout(() => setArrived(true), TRANSITION_FALLBACK_MS);
    return () => {
      unsubscribe();
      clearTimeout(timer);
    };
  }, [filing, navigation]);

  // With a screen reader on, the next item of a run announces itself.
  const loaded = item !== null;
  useEffect(() => {
    if (!filing || !arrived || !loaded || focusedTitleRef.current) return;
    focusedTitleRef.current = true;
    AccessibilityInfo.isScreenReaderEnabled()
      .then((enabled) => {
        if (enabled) focusForScreenReader(titleRef.current);
      })
      .catch(() => undefined);
  }, [arrived, filing, loaded]);

  // Once named, focus moves on to what comes next: filing it, or its details.
  const named = name !== '';
  useEffect(() => {
    if (!named || !focusAfterNameRef.current) return;
    focusAfterNameRef.current = false;
    focusForScreenReader(inDropZone ? fileRef.current : editRef.current);
  }, [inDropZone, named]);

  function back() {
    if (router.canGoBack()) router.back();
    else goToTab('/');
  }

  async function moveOrFile() {
    if (!item || busyRef.current) return;
    busyRef.current = true;
    // Filing this item is a step of the run; moving one that is already
    // filed (by another phone, say) is not, and does not advance it.
    const runStep = filing && inDropZone;
    // The drop zone as it was before this move keeps the run in its order.
    const before = waitingIds;
    try {
      const result = await openForResult<MoveResult>((request) =>
        router.push({
          pathname: '/item/[id]/move',
          params: runStep ? { id, request, filing: '1' } : { id, request },
        }),
      );
      // Outside a run nothing more happens: this screen re-reads on focus,
      // and the move sheet has said where the item went.
      if (!result || !runStep) return;
      let waiting: string[];
      try {
        waiting = (await repos.items.listUnsorted()).map((entry) => entry.id);
      } catch {
        waiting = before.filter((entry) => entry !== id);
      }
      // Left for another screen (search, say) while the list was read: the
      // run is over, and replacing or going back now would act on that screen.
      if (!navigation.isFocused()) return;
      const next = nextInRun(before, id, waiting);
      if (next) router.replace({ pathname: '/item/[id]', params: { id: next, filing: '1' } });
      else if (router.canGoBack()) router.back();
      else goToTab('/drop-zone');
    } finally {
      busyRef.current = false;
    }
  }

  async function deleteItem() {
    if (!item || busyRef.current) return;
    busyRef.current = true;
    try {
      const sure = await confirm({
        title: name ? strings.item.deleteTitle(name) : strings.item.deleteTitleUnnamed,
        body: household.session ? strings.item.deleteBodyPaired : strings.item.deleteBodyLocal,
        confirmLabel: strings.common.delete,
      });
      if (!sure) return;
      setDeleting(true);
      const result = await repos.items.delete(id);
      deleteStoredPhotos(result.orphanedPhotoUris);
      logEvent('item_deleted');
      // Back to wherever the item was opened from; leaving first means this
      // screen is not re-read into "This item is gone" on the way out.
      back();
      invalidate();
      toast.show({
        message: name ? strings.item.deleted(name) : strings.item.deletedUnnamed,
      });
    } catch (cause) {
      setDeleting(false);
      const kind = describeError(cause, 'delete', 'item').kind;
      logError('item_delete_failed', { errorClass: kind });
      haptics.error();
      toast.show({ message: strings.item.deleteFailed(kind === 'offline'), tone: 'error' });
    } finally {
      busyRef.current = false;
    }
  }

  const position = filing ? runPosition(waitingIds, id) : null;
  const progress = position ? strings.item.progress(position.index, position.total) : null;

  const header = (
    <Stack.Screen
      options={{
        headerRight: HeaderSearch,
        headerTitle: progress && !collapsed ? () => <RunProgress label={progress} /> : undefined,
      }}
    />
  );

  if (item === null) {
    let state: ReactElement;
    if (itemQuery.cause) {
      state = <ErrorState cause={itemQuery.cause} subject="item" onRetry={itemQuery.reload} />;
    } else if (itemQuery.loading) {
      state = (
        <View style={styles.skeleton}>
          <Skeleton variant="detail" />
        </View>
      );
    } else {
      // Read fine, but nothing there: deleted, probably on another phone.
      state = (
        <ErrorState
          cause={null}
          subject="item"
          secondary={{ label: strings.common.goBack, onPress: back }}
        />
      );
    }
    return (
      <ScreenFrame kind="detail">
        {header}
        {state}
      </ScreenFrame>
    );
  }

  const photoUri = item.photoUri ?? item.photoThumbUri;
  const hasFacts = Boolean(item.category) || item.tags.length > 0 || Boolean(item.notes);

  return (
    <ScreenFrame kind="detail">
      {header}
      <ScrollView
        onScroll={onScroll}
        scrollEventThrottle={16}
        keyboardShouldPersistTaps="handled"
        automaticallyAdjustKeyboardInsets
        contentContainerStyle={[styles.content, { paddingBottom: insets.bottom + space.xl }]}
      >
        {needsRefreshBanner(itemQuery.refreshFailed, itemQuery.cause) ? (
          <Banner
            tone="info"
            message={strings.errors.refreshFailed}
            action={{ label: strings.common.tryAgain, onPress: itemQuery.reload }}
          />
        ) : null}

        <View
          onLayout={onTitleLayout}
          style={[styles.identity, stacked ? styles.identityStacked : null]}
        >
          <Thumb
            uri={item.photoThumbUri ?? item.photoUri}
            size={88}
            onPress={photoUri ? () => router.push(`/item/${id}/photo`) : undefined}
            accessibilityLabel={name ? strings.item.photoA11y(name) : strings.item.photoA11yUnnamed}
            testID="item-photo"
          />
          <View style={[styles.identityText, stacked ? null : styles.besideThumb]}>
            {named ? (
              <>
                <View ref={titleRef} accessible accessibilityRole="header">
                  <AppText variant="itemTitle">{name}</AppText>
                </View>
                {item.category ? (
                  <AppText variant="meta" tone="graphite">
                    {item.category}
                  </AppText>
                ) : null}
              </>
            ) : (
              <NameItInline
                key={id}
                item={item}
                autoFocus={filing && arrived}
                headingRef={titleRef}
                onNamed={(given) => {
                  focusAfterNameRef.current = true;
                  setNamedHere({ id, name: given });
                }}
              />
            )}
          </View>
        </View>

        <WhereCard place={item} name={name} onMove={() => void moveOrFile()} actionRef={fileRef} />

        <Sheet inset>
          <View style={[styles.quantity, stacked ? styles.quantityStacked : null]}>
            <AppText variant="label" style={stacked ? null : styles.quantityLabel}>
              {strings.quantity.label}
            </AppText>
            <SavedQuantityStepper item={item} size="large" />
          </View>
        </Sheet>

        {hasFacts ? (
          <Sheet inset style={styles.facts}>
            {item.category ? (
              <FactRow label={strings.forms.categoryLabel}>{item.category}</FactRow>
            ) : null}
            {item.tags.length > 0 ? (
              <FactRow label={strings.forms.tagsLabel}>
                <View style={styles.tags}>
                  {item.tags.map((tag) => (
                    <Chip key={tag} label={tag} />
                  ))}
                </View>
              </FactRow>
            ) : null}
            {item.notes ? <FactRow label={strings.forms.notesLabel}>{item.notes}</FactRow> : null}
          </Sheet>
        ) : null}

        <Button
          ref={editRef}
          label={strings.item.editDetails}
          accessibilityLabel={name ? strings.item.editDetailsA11y(name) : undefined}
          onPress={() => router.push(`/item/${id}/edit`)}
          icon="edit"
          variant="secondary"
          fullWidth
          testID="item-edit"
        />

        <AppText variant="caption" tone="graphite">
          {itemStamp(item.createdAt, item.updatedAt, now)}
        </AppText>

        <View style={[styles.danger, { borderTopColor: colors.rule }]}>
          <Button
            label={strings.item.delete}
            accessibilityLabel={name ? strings.item.deleteA11y(name) : undefined}
            onPress={() => void deleteItem()}
            icon="trash"
            variant="destructive"
            loading={deleting}
            testID="item-delete"
          />
        </View>
      </ScrollView>
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  skeleton: {
    padding: GUTTER,
  },
  content: {
    padding: GUTTER,
    gap: space.lg,
  },
  identity: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: space.lg,
  },
  identityStacked: {
    flexDirection: 'column',
  },
  identityText: {
    flex: 1,
    alignSelf: 'stretch',
    gap: space.xs,
    justifyContent: 'center',
  },
  // Centred on the 88 pt thumbnail beside it; under it (large text) it needs no height of its own.
  besideThumb: {
    minHeight: 88,
  },
  quantity: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
  },
  quantityStacked: {
    flexDirection: 'column',
    alignItems: 'stretch',
  },
  quantityLabel: {
    flex: 1,
  },
  facts: {
    gap: space.lg,
  },
  tags: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: space.sm,
  },
  danger: {
    marginTop: space.xxxl - space.lg,
    paddingTop: space.lg,
    borderTopWidth: 1,
  },
});
