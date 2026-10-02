import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react';
import { FlatList, StyleSheet, View } from 'react-native';
import { router, useScrollToTop } from 'expo-router';

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
import { GutterSheetSeparator, sheetCell } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { animateNextLayout } from '@/ui/motion';
import { focusSearch, openQuickSnap, type MoveResult } from '@/ui/navigation';
import { openForResult } from '@/ui/routeResult';
import { needsRefreshBanner } from '@/ui/spaces/spaceSetup';
import { usePullToRefresh } from '@/ui/spaces/usePullToRefresh';
import { GUTTER, space, useTheme } from '@/ui/theme';

/**
 * Stable for the memoised rows: the item screen as a filing run (name it,
 * file it, then on to the next one).
 */
function openItem(id: string) {
  router.push(`/item/${id}?filing=1`);
}

/**
 * The holding area for things added "somewhere" or photographed with Quick
 * Snap before they had a home (issue #26), and the owner's filing queue.
 *
 * Capturing and filing are separate jobs done at different moments, usually
 * standing in a room versus sitting down later, so this screen exists to make
 * the second one cheap rather than to make the first one wait for it. Filing
 * a named item is two taps and you stay on the list: "File…"
 * opens the place picker and the row leaves as soon as it is filed. Opening a
 * row starts a filing run on the item screen, where an unnamed photo gets its
 * name and then its home, one after another. The card that only ever opened
 * Move, then dropped you inside the destination container, is gone.
 *
 * The list is the drop-zone read shared with the tab badge and Home's card
 * (`DropZoneProvider`), so the three never disagree.
 */
export default function DropZoneScreen() {
  const { colors } = useTheme();
  const { items, loading, cause, refreshFailed, reading, reload } = useDropZone();
  // Rows filed a moment ago leave at once rather than when the refetch lands.
  const [hidden, setHidden] = useState<HiddenRows | null>(null);
  // One move sheet at a time: a second tap while the first opens would stack another.
  const filingRef = useRef(false);

  // Re-tapping the active tab scrolls back to the top.
  const listRef = useRef<FlatList<ItemWithContext>>(null);
  useScrollToTop(listRef);
  const refreshControl = usePullToRefresh(reading, reload);

  // The categories of waiting items are offered when naming them.
  useEffect(() => {
    rememberCategories(items);
  }, [items]);

  const rows = visibleRows(items, hidden);

  // The list as last drawn, for a filing that finishes after the move sheet:
  // a refetch may have replaced it while the sheet was open.
  const shownRef = useRef(items);
  useEffect(() => {
    shownRef.current = items;
  });

  // No `filing=1` here: the list itself is the run, and the move sheet's
  // toast ("Filed in Tool chest (Garage)" with Undo) is the confirmation.
  // Stable for the memoised rows (`reload` is).
  const fileItem = useCallback(
    (id: string) => {
      void (async () => {
        if (filingRef.current) return;
        filingRef.current = true;
        try {
          const moved = await openForResult<MoveResult>((request) =>
            router.push(`/item/${id}/move?request=${request}`),
          );
          if (!moved) return;
          const shown = shownRef.current;
          animateNextLayout();
          setHidden((previous) => hideRow(previous, shown, id));
          reload();
        } finally {
          filingRef.current = false;
        }
      })();
    },
    [reload],
  );

  const header = (
    <>
      <TabRootHeader
        title={strings.dropZone.title}
        // Quick Snap sits under the intro, not in the title row, which it
        // crowded at 360 pt. With nothing waiting, the empty state's primary
        // is the one Quick Snap.
        subtitle={
          rows.length > 0 ? (
            <>
              <AppText variant="meta" tone="graphite">
                {strings.dropZone.intro2(rows.length)}
              </AppText>
              <Button
                label={strings.dropZone.quickSnap}
                icon="layers"
                variant="secondary"
                size="sm"
                onPress={openQuickSnap}
                testID="drop-zone-capture"
                style={styles.quickSnap}
              />
            </>
          ) : undefined
        }
        actions={
          <IconButton
            icon="search"
            accessibilityLabel={strings.a11y.searchHousehold}
            accessibilityHint={strings.a11y.searchHint}
            onPress={focusSearch}
            testID="drop-zone-search"
          />
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
        action={{ label: strings.dropZone.emptyAll.action, icon: 'layers', onPress: openQuickSnap }}
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
              onFile={fileItem}
            />
          </View>
        )}
        ItemSeparatorComponent={GutterSheetSeparator}
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
  quickSnap: {
    marginTop: space.md,
  },
});
