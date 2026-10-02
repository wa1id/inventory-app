import { useEffect, useRef, useState, type ReactElement } from 'react';
import { FlatList, StyleSheet, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { ItemWithContext } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { useToast } from '@/providers/ToastProvider';
import { sessionItems, summarizeSession } from '@/services/capture/fastReview';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logError, logEvent } from '@/services/telemetry';
import {
  containerLabel,
  expectedStillShown,
  hideRow,
  reviewDoneToast,
  reviewStatus,
  reviewStatusText,
  reviewTitle,
  sessionSignature,
  visibleRows,
  withLanded,
  type HiddenRows,
} from '@/ui/capture/captureFlow';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { ItemRow } from '@/ui/components/ItemRow';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { SheetSeparator, sheetCell } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { confirm } from '@/ui/confirm';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { animateNextLayout } from '@/ui/motion';
import { goToTab, openContainer } from '@/ui/navigation';
import { needsRefreshBanner } from '@/ui/spaces/spaceSetup';
import { usePullToRefresh } from '@/ui/spaces/usePullToRefresh';
import { GUTTER, space, useTheme } from '@/ui/theme';

/**
 * How long a set may sit unchanged before "Saving N more…" stops promising.
 * `expected` is frozen when the camera closes, so a shot whose pipeline failed
 * afterwards would otherwise keep it saying "Saving…" for ever (capture §13.4).
 */
const STALL_MS = 30_000;

/** The rule between two rows of the sheet, inside the screen gutter. */
function Separator() {
  return (
    <View style={styles.gutter}>
      <SheetSeparator />
    </View>
  );
}

/**
 * The end of a Quick Snap set (spec §5.16): what it saved, what still needs a
 * name, and the way back to where the set started.
 *
 * Everything is already saved by the time this shows, so there is nothing to
 * "keep": Done simply goes back and says where the items are. Naming happens
 * on the item screen (a filing run from the drop zone).
 *
 * The screen holds no session state of its own. Items were already written by
 * the capture pipeline; this is a filtered read that re-runs on every write,
 * which is also what makes late recognition results appear live.
 */
export default function FastReviewScreen() {
  const { containerId, since, expected } = useLocalSearchParams<{
    containerId: string;
    since: string;
    expected: string;
  }>();
  const router = useRouter();
  const toast = useToast();
  const { colors } = useTheme();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const { session } = useHousehold();

  const sinceMs = Number(since);
  const expectedCount = Number(expected) || 0;

  const items = useInventoryQuery(
    async () => sessionItems(await repos.items.listByContainer(containerId), sinceMs),
    `fast-review:${containerId}:${since}`,
  );
  const refreshControl = usePullToRefresh(items.loading, items.reload);

  // Rows deleted here leave at once rather than when the refetch lands.
  const [hidden, setHidden] = useState<HiddenRows | null>(null);
  const deletingRef = useRef(false);
  // Done, Keep shooting and Try again each leave once: a second tap would go
  // back past the origin, or replace the camera it just opened.
  const leavingRef = useRef(false);

  const loaded = items.data ?? [];
  // The list as last drawn, for a delete that finishes after its confirm: a
  // pipeline write may have re-read the set while the question was open.
  const shownRef = useRef(loaded);
  useEffect(() => {
    shownRef.current = loaded;
  });

  // Every row the set has shown, kept as each read arrives (derived state, as
  // in `useInventoryQuery`). A row that leaves afterwards (deleted, or filed
  // from its item screen) landed, so it is not "Saving 1 more…".
  const [landed, setLanded] = useState<{
    source: ItemWithContext[] | null;
    ids: ReadonlySet<string>;
  }>(() => ({ source: null, ids: new Set() }));
  if (items.data !== null && landed.source !== items.data) {
    setLanded({ source: items.data, ids: withLanded(landed.ids, items.data) });
  }

  const list = visibleRows(loaded, hidden);
  const summary = summarizeSession(
    list,
    expectedStillShown(expectedCount, landed.ids.size, list.length),
  );
  const label = containerLabel(loaded);

  // "Saving N more…" holds only while the set is still changing. The timer
  // restarts whenever a row lands, is named or goes; set from its callback,
  // never from the effect body.
  const signature = sessionSignature(loaded);
  const waiting = summary.pending > 0;
  const [quietSignature, setQuietSignature] = useState<string | null>(null);
  useEffect(() => {
    if (!waiting) return;
    const timer = setTimeout(() => setQuietSignature(signature), STALL_MS);
    return () => clearTimeout(timer);
  }, [signature, waiting]);
  const status = reviewStatus(summary, waiting && quietSignature === signature);
  const stillSaving = status === 'pending';

  function openItem(id: string) {
    // Drop-zone items are named and filed in one run on the item screen.
    router.push(containerId === DROP_ZONE_CONTAINER_ID ? `/item/${id}?filing=1` : `/item/${id}`);
  }

  async function remove(id: string) {
    // Held from the question on: a second trash tap must not open a second
    // confirm whose "Delete" would then be dropped silently.
    if (deletingRef.current) return;
    deletingRef.current = true;
    try {
      const confirmed = await confirm({
        title: strings.review.deleteTitle,
        body: session ? strings.review.deleteBodyPaired : strings.review.deleteBodyLocal,
        confirmLabel: strings.common.delete,
      });
      if (!confirmed) return;
      const result = await repos.items.delete(id);
      deleteStoredPhotos(result.orphanedPhotoUris);
      logEvent('item_deleted');
      animateNextLayout();
      setHidden((previous) => hideRow(previous, shownRef.current, id));
      invalidate();
    } catch (cause) {
      const kind = describeError(cause, 'delete', 'item').kind;
      logError('item_delete_failed', { errorClass: kind });
      haptics.error();
      toast.show({ message: strings.review.deleteFailed(kind === 'offline'), tone: 'error' });
    } finally {
      deletingRef.current = false;
    }
  }

  // Back to where the set started: capture was replaced by this screen, so
  // the screen underneath is the origin (Home, the Drop zone, a container).
  function done() {
    if (leavingRef.current) return;
    leavingRef.current = true;
    logEvent('fast_review_done', { kept: summary.saved, unnamed: summary.unnamed });
    const report = reviewDoneToast(summary.saved, containerId, label);
    if (router.canGoBack()) router.back();
    else openContainer(containerId);
    if (!report) return;
    toast.show({
      message: report.message,
      action: report.viewDropZone
        ? {
            label: strings.common.view,
            accessibilityLabel: strings.review.viewDropZoneA11y,
            onPress: () => goToTab('/drop-zone'),
          }
        : undefined,
    });
  }

  function keepShooting() {
    if (leavingRef.current) return;
    leavingRef.current = true;
    const params = new URLSearchParams({ containerId, mode: 'fast', since });
    router.replace(`/capture?${params.toString()}`);
  }

  function tryAgain() {
    if (leavingRef.current) return;
    leavingRef.current = true;
    const params = new URLSearchParams({ containerId, mode: 'fast' });
    router.replace(`/capture?${params.toString()}`);
  }

  // Nothing is claimed before the first read: no "0 items saved" while loading.
  const showHead = items.data !== null && (list.length > 0 || stillSaving);
  const title = reviewTitle(summary.saved, containerId, label);
  const header = (
    <>
      {showHead ? (
        <View style={styles.head}>
          {title === null ? null : <AppText variant="title">{title}</AppText>}
          <AppText
            variant="meta"
            tone={status === 'maybeLost' ? 'signal' : 'graphite'}
            accessibilityLiveRegion="polite"
          >
            {reviewStatusText(status, summary)}
          </AppText>
        </View>
      ) : null}
      {/* Offline has the connection banner; anything else is said here, over the old list. */}
      {needsRefreshBanner(items.refreshFailed, items.cause) ? (
        <View style={[styles.gutter, styles.banner]}>
          <Banner
            tone="info"
            message={strings.errors.refreshFailed}
            action={{ label: strings.common.tryAgain, onPress: items.reload }}
          />
        </View>
      ) : null}
    </>
  );

  // A failed first read is never shown as "nothing was saved".
  // Rows still on their way take their shape, as on a first read.
  const placeholder = (
    <View style={[styles.gutter, styles.skeleton]}>
      <Skeleton variant="rows" rows={Math.min(Math.max(summary.pending, 1), 4)} thumb={76} />
    </View>
  );
  let empty: ReactElement;
  if (items.data === null) {
    empty = items.cause ? <ErrorState cause={items.cause} onRetry={items.reload} /> : placeholder;
  } else if (stillSaving) {
    empty = placeholder;
  } else if (landed.ids.size > 0) {
    // Every row landed and then left (deleted, or filed from its item screen).
    empty = <EmptyState title={strings.review.emptied.title} body={strings.review.emptied.body} />;
  } else {
    empty = (
      <EmptyState
        icon="camera"
        title={strings.review.nothing.title}
        body={strings.review.nothing.body}
        action={{ label: strings.review.nothing.action, icon: 'camera', onPress: tryAgain }}
      />
    );
  }

  return (
    <ScreenFrame
      kind="detail"
      bottomBar={
        <BottomBar>
          <Button
            label={strings.review.keepShooting}
            variant="secondary"
            fullWidth
            onPress={keepShooting}
            testID="fast-review-more"
          />
          <Button label={strings.review.done} fullWidth onPress={done} testID="fast-review-done" />
        </BottomBar>
      }
    >
      <Stack.Screen options={{ title: strings.review.title }} />
      <FlatList<ItemWithContext>
        data={list}
        keyExtractor={(item) => item.id}
        renderItem={({ item, index }) => (
          <View style={[styles.gutter, sheetCell(index, list.length, colors)]}>
            <ItemRow
              item={item}
              line="detail"
              tool="delete"
              thumb={76}
              onPress={openItem}
              onDelete={(id) => void remove(id)}
            />
          </View>
        )}
        ItemSeparatorComponent={Separator}
        ListHeaderComponent={header}
        ListEmptyComponent={empty}
        contentContainerStyle={styles.content}
        refreshControl={refreshControl}
      />
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  content: {
    paddingBottom: space.xl,
  },
  gutter: {
    marginHorizontal: GUTTER,
  },
  head: {
    paddingHorizontal: GUTTER,
    paddingTop: space.lg,
    paddingBottom: space.lg,
    gap: space.xs,
  },
  banner: {
    marginBottom: space.lg,
  },
  skeleton: {
    paddingTop: space.lg,
  },
});
