import { useRef, type ReactElement } from 'react';
import { FlatList, StyleSheet, View } from 'react-native';
import { useRouter, useScrollToTop } from 'expo-router';

import type { SpaceWithCounts } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { Icon } from '@/ui/components/Icon';
import { IconButton } from '@/ui/components/IconButton';
import { SpaceRow } from '@/ui/components/PlaceRows';
import { Row } from '@/ui/components/Row';
import { ScreenFrame, SearchButton, TabRootHeader } from '@/ui/components/ScreenFrame';
import { GutterSheetSeparator, sheetCell } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { needsRefreshBanner } from '@/ui/errors';
import { openSpace } from '@/ui/navigation';
import { usePullToRefresh } from '@/ui/spaces/usePullToRefresh';
import { GUTTER, OPTION_MIN, THUMB, space, useTheme } from '@/ui/theme';

/**
 * "New space" as the last row of the sheet, so the owner's next step is in
 * reach at the end of the list without a bar pinned over it.
 */
function NewSpaceRow({ index, count }: { index: number; count: number }) {
  const router = useRouter();
  const { colors } = useTheme();

  return (
    <>
      <GutterSheetSeparator />
      <View style={[styles.gutter, sheetCell(index, count, colors)]}>
        <Row
          onPress={() => router.push('/space/new')}
          leading={
            // As wide as a space tile, so the label lines up with the names above.
            <View style={styles.plusSlot}>
              <Icon name="plus" color={colors.ink} />
            </View>
          }
          minHeight={OPTION_MIN}
          accessibilityLabel={strings.spaces.newSpace}
          testID="spaces-create-row"
        >
          <AppText variant="name">{strings.spaces.newSpace}</AppText>
        </Row>
      </View>
    </>
  );
}

/**
 * The Spaces tab: the house, room by room, and where the owner sets it up.
 *
 * Desk rows replace the colour-filled grid of PR #28 (brief decision 1): a
 * space is recognised by its tinted icon tile before its name is read, and
 * the text beside it is always ink, whatever colour was picked.
 */
export default function SpacesScreen() {
  const repos = useRepositories();
  const router = useRouter();
  const { session } = useHousehold();
  const { colors } = useTheme();

  // Re-tapping the active tab scrolls back to the top.
  const listRef = useRef<FlatList<SpaceWithCounts>>(null);
  useScrollToTop(listRef);

  const { data, loading, cause, refreshFailed, reload } = useInventoryQuery(
    () => repos.spaces.listWithCounts(),
    'spaces',
  );
  const refreshControl = usePullToRefresh(loading, reload);

  const spaces = data ?? [];
  // The "New space" row closes the sheet, so it counts as its last cell.
  const cells = spaces.length + 1;

  const header = (
    <>
      <TabRootHeader
        title={strings.spaces.title}
        // No "0 spaces" over the empty state, which says as much.
        subtitle={
          data && data.length > 0 ? (
            <AppText variant="meta" tone="graphite">
              {strings.spaces.count(data.length)}
            </AppText>
          ) : undefined
        }
        actions={
          <>
            <SearchButton testID="spaces-search" />
            <IconButton
              icon="plus"
              accessibilityLabel={strings.spaces.newSpace}
              onPress={() => router.push('/space/new')}
              testID="spaces-create"
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

  // A failed first read is never shown as "no spaces yet" (issue #12).
  let empty: ReactElement;
  if (data === null) {
    empty = cause ? (
      <ErrorState cause={cause} onRetry={reload} />
    ) : (
      <View style={styles.gutter}>
        <Skeleton variant="rows" />
      </View>
    );
  } else {
    empty = (
      <EmptyState
        icon="spaces"
        title={strings.spaces.start.title}
        body={strings.spaces.start.body}
        action={{
          label: strings.spaces.start.action,
          icon: 'plus',
          onPress: () => router.push('/space/new'),
          testID: 'spaces-empty',
        }}
        // A phone that has not joined may be about to: its household already has spaces.
        secondary={
          session
            ? undefined
            : { label: strings.spaces.start.join, onPress: () => router.push('/household') }
        }
      />
    );
  }

  return (
    <ScreenFrame kind="tabRoot">
      <FlatList
        ref={listRef}
        data={spaces}
        keyExtractor={(item) => item.id}
        renderItem={({ item, index }) => (
          <View style={[styles.gutter, sheetCell(index, cells, colors)]}>
            <SpaceRow space={item} onPress={openSpace} />
          </View>
        )}
        ItemSeparatorComponent={GutterSheetSeparator}
        ListHeaderComponent={header}
        ListFooterComponent={
          spaces.length > 0 ? <NewSpaceRow index={spaces.length} count={cells} /> : null
        }
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
  plusSlot: {
    width: THUMB,
    alignItems: 'center',
  },
});
