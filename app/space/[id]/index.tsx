import { useEffect, useMemo, type ReactElement } from 'react';
import { FlatList, StyleSheet, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { DROP_ZONE_SPACE_ID } from '@/db/constants';
import { useCollapsingTitle } from '@/hooks/useCollapsingTitle';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { IconButton } from '@/ui/components/IconButton';
import { ContainerRow } from '@/ui/components/PlaceRows';
import { ScreenFrame, SearchButton } from '@/ui/components/ScreenFrame';
import { GutterSheetSeparator, sheetCell } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { SpaceTile } from '@/ui/components/SpaceTile';
import { goToTab, openContainer } from '@/ui/navigation';
import { byContainerLabel, needsRefreshBanner } from '@/ui/spaces/spaceSetup';
import { usePullToRefresh } from '@/ui/spaces/usePullToRefresh';
import { GUTTER, space, useTheme } from '@/ui/theme';

/**
 * The drop zone's system space is the Drop zone tab, not a space screen.
 * An old link goes there; no `<Redirect>`, which would
 * stack a second tab shell.
 */
function ToDropZone() {
  useEffect(() => {
    goToTab('/drop-zone');
  }, []);
  return null;
}

/** Search and, once the space is known, Edit; icons instead of the old blue "Edit" text. */
function HeaderActions({ spaceId, name }: { spaceId: string; name: string | null }) {
  const router = useRouter();
  return (
    <View style={styles.headerActions}>
      <SearchButton />
      {name !== null ? (
        <IconButton
          icon="edit"
          accessibilityLabel={strings.spaces.edit(name)}
          onPress={() => router.push(`/space/${spaceId}/edit`)}
          testID="space-edit"
        />
      ) : null}
    </View>
  );
}

export default function SpaceScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  if (id === DROP_ZONE_SPACE_ID) return <ToDropZone />;
  return <SpaceDetail id={id} />;
}

/**
 * One space: its containers, sorted by label.
 *
 * The space is told by its tile and title in the content, on the plaster like
 * every screen, rather than by a header filled with its colour (which needed
 * `onColor` juggling and fought the iOS 26 header). The title moves into the
 * header once it scrolls away. There are no peeks at each container's
 * contents: that would be one list call per row over the network.
 */
function SpaceDetail({ id }: { id: string }) {
  const repos = useRepositories();
  const router = useRouter();
  const { colors } = useTheme();
  const insets = useSafeAreaInsets();

  const spaceQuery = useInventoryQuery(() => repos.spaces.getById(id), `space:${id}`);
  const containers = useInventoryQuery(
    () => repos.containers.listBySpace(id),
    `containers-of:${id}`,
  );
  const spaceData = spaceQuery.data;
  const { onScroll, onTitleLayout } = useCollapsingTitle(spaceData?.name ?? '');

  function reloadAll() {
    spaceQuery.reload();
    containers.reload();
  }
  const refreshControl = usePullToRefresh(spaceQuery.loading || containers.loading, reloadAll);

  // The repository returns newest first; a room is scanned by name.
  const sorted = useMemo(
    () => (containers.data ? [...containers.data].sort(byContainerLabel) : []),
    [containers.data],
  );
  const itemTotal = sorted.reduce((total, container) => total + container.itemCount, 0);

  function newContainer() {
    router.push({ pathname: '/container/new', params: { spaceId: id } });
  }

  const headerOptions = (
    <Stack.Screen
      options={{
        headerRight: () => <HeaderActions spaceId={id} name={spaceData?.name ?? null} />,
      }}
    />
  );

  if (spaceData === null) {
    let state: ReactElement;
    if (spaceQuery.cause) {
      state = <ErrorState cause={spaceQuery.cause} subject="space" onRetry={reloadAll} />;
    } else if (spaceQuery.loading) {
      state = (
        <View style={styles.skeleton}>
          <Skeleton variant="list" />
        </View>
      );
    } else {
      // Read fine, but nothing there: deleted, probably on another phone.
      state = (
        <ErrorState
          cause={null}
          subject="space"
          secondary={{ label: strings.common.goToSpaces, onPress: () => goToTab('/spaces') }}
        />
      );
    }
    return (
      <ScreenFrame kind="detail">
        {headerOptions}
        {state}
      </ScreenFrame>
    );
  }

  const showRefreshBanner =
    needsRefreshBanner(spaceQuery.refreshFailed, spaceQuery.cause) ||
    needsRefreshBanner(containers.refreshFailed, containers.cause);
  // Over an empty state the head stops short: that state's own top padding is
  // the gap, 40 pt as on an empty container, not 64.
  const overEmpty = containers.data !== null && sorted.length === 0 && !showRefreshBanner;

  const head = (
    <View>
      {/* The title block alone, so a refresh banner under it does not delay the header title. */}
      <View style={[styles.head, overEmpty ? styles.headOverEmpty : null]} onLayout={onTitleLayout}>
        <SpaceTile icon={spaceData.icon} color={spaceData.color} size={64} surface="plaster" />
        <View style={styles.headText}>
          <AppText variant="title">{spaceData.name}</AppText>
          {/* Not "0 containers and 0 items" over "No containers in Shed yet". */}
          {sorted.length > 0 ? (
            <AppText variant="meta" tone="graphite">
              {strings.entities.spaceCounts(sorted.length, itemTotal)}
            </AppText>
          ) : null}
        </View>
      </View>
      {showRefreshBanner ? (
        <View style={[styles.gutter, styles.banner]}>
          <Banner
            tone="info"
            message={strings.errors.refreshFailed}
            action={{ label: strings.common.tryAgain, onPress: reloadAll }}
          />
        </View>
      ) : null}
    </View>
  );

  // A failed read of the containers is never shown as "no containers yet".
  let empty: ReactElement;
  if (containers.data === null) {
    empty = containers.cause ? (
      <ErrorState cause={containers.cause} onRetry={containers.reload} />
    ) : (
      <View style={styles.gutter}>
        <Skeleton variant="rows" thumb={null} rows={4} />
      </View>
    );
  } else {
    empty = (
      <EmptyState
        icon="box"
        title={strings.spaces.noContainers.title(spaceData.name)}
        body={strings.spaces.noContainers.body}
        action={{
          label: strings.spaces.noContainers.action,
          icon: 'plus',
          onPress: newContainer,
          testID: 'containers-empty',
        }}
      />
    );
  }

  const hasBar = sorted.length > 0;

  return (
    <ScreenFrame
      kind="detail"
      bottomBar={
        hasBar ? (
          <BottomBar>
            <Button
              label={strings.spaces.newContainer}
              icon="plus"
              variant="secondary"
              onPress={newContainer}
              fullWidth
              testID="containers-create"
            />
          </BottomBar>
        ) : null
      }
    >
      {headerOptions}
      <FlatList
        data={sorted}
        keyExtractor={(item) => item.id}
        renderItem={({ item, index }) => (
          <View style={[styles.gutter, sheetCell(index, sorted.length, colors)]}>
            <ContainerRow container={item} context="space" onPress={openContainer} />
          </View>
        )}
        ItemSeparatorComponent={GutterSheetSeparator}
        ListHeaderComponent={head}
        ListEmptyComponent={empty}
        onScroll={onScroll}
        scrollEventThrottle={16}
        refreshControl={refreshControl}
        // The bottom bar pads the home indicator itself; without it the list does.
        contentContainerStyle={{ paddingBottom: space.xl + (hasBar ? 0 : insets.bottom) }}
      />
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  headerActions: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  gutter: {
    marginHorizontal: GUTTER,
  },
  skeleton: {
    padding: GUTTER,
  },
  head: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.lg,
    paddingHorizontal: GUTTER,
    paddingTop: space.sm,
    paddingBottom: space.xl,
  },
  headOverEmpty: {
    paddingBottom: 0,
  },
  headText: {
    flex: 1,
    gap: space.xxs,
  },
  banner: {
    marginBottom: space.lg,
  },
});
