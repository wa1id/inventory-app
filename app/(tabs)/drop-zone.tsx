import { useEffect, useRef, useState, type ReactElement } from 'react';
import { FlatList, StyleSheet, View } from 'react-native';
import { useRouter, useScrollToTop } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { ItemWithContext } from '@/db/types';
import { strings } from '@/i18n/strings';
import { useDropZone } from '@/providers/DropZoneProvider';
import { hideRow, visibleRows, type HiddenRows } from '@/ui/capture/captureFlow';
import { rememberCategories } from '@/ui/categoryMemory';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { IconButton } from '@/ui/components/IconButton';
import { ItemRow } from '@/ui/components/ItemRow';
import { ScreenFrame, TabRootHeader } from '@/ui/components/ScreenFrame';
import { SheetSeparator, sheetCell } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { animateNextLayout } from '@/ui/motion';
import { focusSearch, type MoveResult } from '@/ui/navigation';
import { openForResult } from '@/ui/routeResult';
import { needsRefreshBanner } from '@/ui/spaces/spaceSetup';
import { usePullToRefresh } from '@/ui/spaces/usePullToRefresh';
import { GUTTER, space, useTheme } from '@/ui/theme';

const QUICK_SNAP_HREF = `/capture?containerId=${DROP_ZONE_CONTAINER_ID}&mode=fast` as const;

/** The rule between two rows of the sheet, inside the screen gutter. */
function Separator() {
  return (
    <View style={styles.gutter}>
      <SheetSeparator />
    </View>
  );
}

/**
 * The holding area for things added "somewhere" or photographed with Quick
 * Snap before they had a home (issue #26), and the owner's filing queue.
 *
 * Capturing and filing are separate jobs done at different moments, usually
 * standing in a room versus sitting down later, so this screen exists to make
 * the second one cheap rather than to make the first one wait for it. Filing
 * a named item is two taps and you stay on the list (spec §6.7): "File…"
 * opens the place picker and the row leaves as soon as it is filed. Opening a
 * row starts a filing run on the item screen, where an unnamed photo gets its
 * name and then its home, one after another. The card that only ever opened
 * Move, then dropped you inside the destination container, is gone (UX-4).
 *
 * The list is the drop-zone read shared with the tab badge and Home's card
 * (`DropZoneProvider`), so the three never disagree.
 */
export default function DropZoneScreen() {
  const router = useRouter();
  const { colors } = useTheme();
  const { items, loading, cause, refreshFailed, reading, reload } = useDropZone();
  // Rows filed a moment ago leave at once rather than when the refetch lands.
  const [hidden, setHidden] = useState<HiddenRows | null>(null);
  // One move sheet at a time: a second tap while the first opens would stack another.
  const filingRef = useRef(false);

  // Re-tapping the active tab scrolls back to the top (spec §2.1).
  const listRef = useRef<FlatList<ItemWithContext>>(null);
  useScrollToTop(listRef);
  const refreshControl = usePullToRefresh(reading, reload);

  // The categories of waiting items are offered when naming them (§4.30).
  useEffect(() => {
    rememberCategories(items);
  }, [items]);

  const rows = visibleRows(items, hidden);

  function quickSnap() {
    router.push(QUICK_SNAP_HREF);
  }

  // The item screen as a filing run: name it, file it, then on to the next one.
  function openItem(id: string) {
    router.push(`/item/${id}?filing=1`);
  }

  // No `filing=1` here: the list itself is the run, and the move sheet's
  // toast ("Filed in Tool chest (Garage)" with Undo) is the confirmation.
  async function file(id: string) {
    if (filingRef.current) return;
    filingRef.current = true;
    try {
      const moved = await openForResult<MoveResult>((request) =>
        router.push(`/item/${id}/move?request=${request}`),
      );
      if (!moved) return;
      animateNextLayout();
      setHidden((previous) => hideRow(previous, items, id));
      reload();
    } finally {
      filingRef.current = false;
    }
  }

  const header = (
    <>
      <TabRootHeader
        title={strings.dropZone.title}
        subtitle={
          rows.length > 0 ? (
            <AppText variant="meta" tone="graphite">
              {strings.dropZone.intro2(rows.length)}
            </AppText>
          ) : undefined
        }
        actions={
          <>
            <Button
              label={strings.dropZone.quickSnap}
              icon="layers"
              variant="secondary"
              size="sm"
              onPress={quickSnap}
              testID="drop-zone-capture"
              style={styles.headerButton}
            />
            <IconButton
              icon="search"
              accessibilityLabel={strings.a11y.searchHousehold}
              accessibilityHint={strings.a11y.searchHint}
              onPress={focusSearch}
              testID="drop-zone-search"
            />
          </>
        }
      />
      {/* Offline has the connection banner; anything else is said here, over the old list. */}
      {needsRefreshBanner(refreshFailed, cause) ? (
        <View style={[styles.gutter, styles.banner]}>
          <Banner
            tone="info"
            message={strings.errors.refreshFailed}
            action={{ label: strings.common.tryAgain, onPress: reload }}
          />
        </View>
      ) : null}
    </>
  );

  // A failed first read is never shown as "everything is filed" (issue #12).
  let empty: ReactElement;
  if (loading) {
    empty = (
      <View style={styles.gutter}>
        <Skeleton variant="rows" thumb={76} />
      </View>
    );
  } else if (cause && !refreshFailed) {
    empty = <ErrorState cause={cause} onRetry={reload} />;
  } else {
    empty = (
      <EmptyState
        icon="inbox"
        title={strings.dropZone.emptyAll.title}
        body={strings.dropZone.emptyAll.body}
        action={{ label: strings.dropZone.emptyAll.action, icon: 'layers', onPress: quickSnap }}
        testID="drop-zone-empty"
      />
    );
  }

  return (
    <ScreenFrame kind="tabRoot">
      <FlatList
        ref={listRef}
        data={rows}
        keyExtractor={(item) => item.id}
        renderItem={({ item, index }) => (
          <View style={[styles.gutter, sheetCell(index, rows.length, colors)]}>
            <ItemRow
              item={item}
              line="added"
              tool="file"
              thumb={76}
              onPress={openItem}
              onFile={(id) => void file(id)}
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
  banner: {
    marginBottom: space.lg,
  },
  // Buttons hold themselves to the start; in the title row they centre on it.
  headerButton: {
    alignSelf: 'center',
  },
});
