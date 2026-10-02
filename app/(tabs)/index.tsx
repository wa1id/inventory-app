import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  FlatList,
  Keyboard,
  RefreshControl,
  StyleSheet,
  View,
  type ListRenderItem,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
  type TextInput,
} from 'react-native';
import { router, useLocalSearchParams, useNavigation } from 'expo-router';
import type { BottomTabNavigationProp } from 'expo-router/js-tabs';
import type { ParamListBase } from 'expo-router/react-navigation';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { ItemWithContext } from '@/db/types';
import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { inlineIconSize, useLayoutScale } from '@/hooks/useLayoutScale';
import { useSearch } from '@/hooks/useSearch';
import { strings } from '@/i18n/strings';
import { useConnection } from '@/providers/ConnectionProvider';
import { useRepositories } from '@/providers/DatabaseProvider';
import { useDropZone } from '@/providers/DropZoneProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import type { LocationSearchResult, SearchResults } from '@/repositories/search';
import { rememberCategories } from '@/ui/categoryMemory';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { Icon } from '@/ui/components/Icon';
import { IconButton } from '@/ui/components/IconButton';
import { ItemRow } from '@/ui/components/ItemRow';
import { PlaceRow, type ContainerWithSpace } from '@/ui/components/PlaceRows';
import { ScreenFrame, TabRootHeader } from '@/ui/components/ScreenFrame';
import { SearchField } from '@/ui/components/SearchField';
import { Section, SheetSeparator, sheetCell } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { describeError } from '@/ui/errors';
import { DropZoneCard } from '@/ui/home/DropZoneCard';
import {
  FIELD_ENTRY,
  RECENT_FIRST,
  RECENT_MORE,
  householdCounts,
  idleEntries,
  resultEntries,
  type HomeEntry,
  type IdleBody,
} from '@/ui/home/homeList';
import { TotalLine } from '@/ui/home/TotalLine';
import { useUnpairedNotice } from '@/ui/home/unpairedNotice';
import { animateNextLayout, delay } from '@/ui/motion';
import { goToTab, openContainer, openSpace } from '@/ui/navigation';
import { useSearchFocusRequest } from '@/ui/searchFocus';
import { GUTTER, space, useTheme } from '@/ui/theme';

const QUICK_SNAP_HREF = `/capture?containerId=${DROP_ZONE_CONTAINER_ID}&mode=fast` as const;
const NO_CONTAINERS: ContainerWithSpace[] = [];
const SEARCHING: HomeEntry = { kind: 'status', key: 'status', status: 'searching' };

/**
 * A failure the screen does not need to explain itself: the connection
 * banner covers the home server being unreachable, and the removed-phone
 * layer covers a phone that is no longer in the household.
 */
function explainedElsewhere(cause: unknown): boolean {
  const { kind } = describeError(cause);
  return kind === 'offline' || kind === 'revoked';
}

// Opening a result puts the keyboard away; the query stays for the way back.
function openItem(id: string) {
  Keyboard.dismiss();
  router.push(`/item/${id}`);
}

function announceSummary(results: SearchResults) {
  AccessibilityInfo.announceForAccessibility(
    strings.search.summary(results.items.length, results.locations.length),
  );
}

function openPlace(hit: LocationSearchResult) {
  Keyboard.dismiss();
  // Never `/container/drop-zone` or the drop zone's space (B4): both helpers
  // send the system records to the Drop zone tab.
  if (hit.kind === 'space') openSpace(hit.id);
  else openContainer(hit.id);
}

/**
 * Home: her first screen. It answers "where is it?" and "do we still have
 * it?" in place, and shows the household at a glance.
 *
 * One list: the title block scrolls away and the search field stays pinned
 * at the top (the list's one sticky row). With the field focused or holding
 * a query the title block goes, so results start right under the field.
 * Results replace the overview in place; the item rows carry where each
 * thing is and a quantity chip, so most searches end without opening
 * anything (#1, #14, `111b579`). Search used to be its own tab with a 14 px
 * location chip (`search.tsx:373-385`); it lives here now (UX-6, UX-11).
 */
export default function HomeScreen() {
  const repos = useRepositories();
  const { colors } = useTheme();
  const { fontScale } = useLayoutScale();
  const { session } = useHousehold();
  const connection = useConnection();
  const dropZone = useDropZone();
  const navigation = useNavigation<BottomTabNavigationProp<ParamListBase>>();
  const params = useLocalSearchParams<{ q?: string }>();

  const [query, setQuery] = useState('');
  const [focused, setFocused] = useState(false);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [recentLimit, setRecentLimit] = useState(RECENT_FIRST);
  const [pulled, setPulled] = useState(false);

  // `/?q=` fills the field once per value; typing afterwards is hers.
  const [prefilled, setPrefilled] = useState<string | undefined>(undefined);
  if (params.q && params.q !== prefilled) {
    setPrefilled(params.q);
    setQuery(params.q);
  }

  const trimmed = query.trim();
  const searching = trimmed !== '';
  const compact = focused || searching;

  // Containers are only needed to draw place results, so they are read once
  // she heads for the field, and kept fresh from then on like any other list.
  // Reading on focus rather than on the first letter means the first place
  // results draw as container rows straight away, instead of PlaceRow's
  // plain fallback swapping to them a moment later.
  const [wantsPlaces, setWantsPlaces] = useState(false);
  if (compact && !wantsPlaces) setWantsPlaces(true);

  const spaces = useInventoryQuery(() => repos.spaces.listWithCounts(), 'spaces');
  // Twelve first: when joined, a list resolves only once its thumbnails are
  // in (§7.5 R9). "Show more" asks for forty; the twelve stay on screen meanwhile.
  const recent = useInventoryQuery(
    () => repos.items.listRecent(recentLimit),
    `recent:${recentLimit}`,
  );
  const containers = useInventoryQuery(
    () => (wantsPlaces ? repos.containers.listAllWithSpace() : Promise.resolve(NO_CONTAINERS)),
    wantsPlaces ? 'containers-all' : 'containers-none',
  );
  const search = useSearch(query);

  // The recent rows on screen. "Show more" reads forty under a new key, and a
  // failed read keeps only data read under its own key, so without this a
  // failed "Show more" would swap the twelve rows for an error page. They
  // stay instead, under the "could not be refreshed" banner (§5.0).
  const [shownRecent, setShownRecent] = useState<readonly ItemWithContext[] | null>(null);
  if (recent.data !== null && recent.data !== shownRecent) setShownRecent(recent.data);
  const recentRows = recent.data ?? shownRecent;

  const paired = session !== null;
  const notice = useUnpairedNotice(paired);
  const householdName = session?.householdName.trim() || strings.home.title;

  const listRef = useRef<FlatList<HomeEntry>>(null);
  const inputRef = useRef<TextInput>(null);
  const scrollY = useRef(0);
  /** The search key was pressed before the results were in (see `announceResults`). */
  const announceWhenSettled = useRef(false);

  useEffect(() => {
    if (recent.data) rememberCategories(recent.data);
  }, [recent.data]);

  // Re-tapping Home: back to the top, and from the top into the field (§2.1).
  useEffect(
    () =>
      navigation.addListener('tabPress', () => {
        if (!navigation.isFocused()) return;
        if (scrollY.current > 1) listRef.current?.scrollToOffset({ offset: 0, animated: true });
        else inputRef.current?.focus();
      }),
    [navigation],
  );

  // The search buttons on other screens land here with the keyboard up (§2.5 rule 4).
  useSearchFocusRequest(() => inputRef.current?.focus());

  const spacesById = useMemo(
    () => new Map((spaces.data ?? []).map((entry) => [entry.id, entry])),
    [spaces.data],
  );
  const containersById = useMemo(
    () => new Map((containers.data ?? NO_CONTAINERS).map((entry) => [entry.id, entry])),
    [containers.data],
  );

  const toggleExpand = useCallback((id: string) => {
    setExpandedId((current) => (current === id ? null : id));
  }, []);

  // A pull ends when every list it asked for has answered.
  const reloading = spaces.loading || recent.loading || (searching && search.refreshing);
  if (pulled && !reloading) setPulled(false);

  function reloadOverview() {
    spaces.reload();
    recent.reload();
    dropZone.reload();
  }

  function refresh() {
    setPulled(true);
    reloadOverview();
    if (searching) {
      search.retry();
      // Place rows take their codes and types from this list.
      containers.reload();
    }
  }

  function changeFocus(next: boolean) {
    if ((next || searching) !== compact) animateNextLayout();
    setFocused(next);
  }

  function changeQuery(text: string) {
    const nextSearching = text.trim() !== '';
    if ((focused || nextSearching) !== compact) animateNextLayout();
    // Results start at the top, not wherever Recently added was scrolled to.
    if (nextSearching && !searching)
      listRef.current?.scrollToOffset({ offset: 0, animated: false });
    // A new list starts with every chip closed.
    setExpandedId(null);
    // Typing again takes back a summary still waiting to be said.
    announceWhenSettled.current = false;
    setQuery(text);
  }

  // The summary is not a live region (it changes as she types), so it is said
  // when she presses the search key. Pressed before the results are in (a
  // fast typist, dictation, a slow home server), it is said when they arrive
  // rather than not at all; the field has already let go of focus by then.
  function announceResults() {
    // An empty field has no results; the last search's are still held.
    if (!searching) return;
    if (search.pending || !search.results) {
      announceWhenSettled.current = true;
      return;
    }
    announceSummary(search.results);
  }

  useEffect(() => {
    if (!announceWhenSettled.current || search.pending) return;
    if (search.results) {
      announceWhenSettled.current = false;
      announceSummary(search.results);
    } else if (search.cause) {
      // The error state announces itself.
      announceWhenSettled.current = false;
    }
  }, [search.pending, search.results, search.cause]);

  function onScroll(event: NativeSyntheticEvent<NativeScrollEvent>) {
    scrollY.current = event.nativeEvent.contentOffset.y;
  }

  // Older results stay while a new query runs, dimmed and out of reach; past
  // 600 ms the skeleton takes their place. The skeleton waits 180 ms before it
  // shows, so it is mounted that much earlier and the swap has no gap.
  const showingOlder =
    search.pending &&
    search.results !== null &&
    search.results.items.length + search.results.locations.length > 0;
  const mountSkeleton = useDelayedFlag(showingOlder, delay.searchSkeleton - delay.skeleton);
  const dropOlder = useDelayedFlag(showingOlder, delay.searchSkeleton);
  // Without older results the skeleton counts from when the search starts
  // (after the debounce), not from the keystroke, so a quick search never
  // flashes one.
  const searchStarted = useDelayedFlag(
    searching && !showingOlder && (search.pending || search.results === null),
    delay.searchDebounce,
  );

  const dim = showingOlder && !dropOlder;

  const idleBody: IdleBody = (() => {
    if (recentRows === null) {
      return { kind: 'status', status: recent.cause ? 'error' : 'loading' };
    }
    if (recentRows.length === 0 && dropZone.count === 0) {
      // Not joined: whether there are spaces decides the next step.
      if (!paired && spaces.data === null) {
        return { kind: 'status', status: spaces.cause ? 'error' : 'loading' };
      }
      return { kind: 'status', status: 'empty' };
    }
    return {
      kind: 'list',
      recent: recentRows,
      canShowMore: recentLimit === RECENT_FIRST && recentRows.length === RECENT_FIRST,
    };
  })();
  const startHere =
    idleBody.kind === 'status' && idleBody.status === 'empty' && !paired && !spaces.data?.length;

  const searchBody: HomeEntry[] = (() => {
    if (search.pending) {
      if (dim && search.results) {
        const older = resultEntries(search.results, false);
        // The skeleton goes in above them, still invisible, ready to take over.
        return mountSkeleton ? [SEARCHING, ...older] : older;
      }
      return [SEARCHING];
    }
    if (search.results === null) {
      return [search.cause ? { kind: 'status', key: 'status', status: 'searchFailed' } : SEARCHING];
    }
    return resultEntries(
      search.results,
      search.cause !== null && !explainedElsewhere(search.cause),
    );
  })();

  const entries: HomeEntry[] = [
    FIELD_ENTRY,
    ...(searching
      ? searchBody
      : idleEntries({
          // The empty household already offers to join; the notice would repeat it.
          notice: notice.visible && !startHere,
          // Anything on screen that the last read could not refresh: the
          // summary, the recent rows, or the drop-zone card's items.
          refreshFailed: [
            { cause: spaces.cause, shown: spaces.data !== null },
            { cause: recent.cause, shown: recentRows !== null },
            { cause: dropZone.cause, shown: dropZone.count > 0 },
          ].some(({ cause, shown }) => cause !== null && shown && !explainedElsewhere(cause)),
          dropZoneCount: dropZone.count,
          body: idleBody,
        })),
  ];

  const counts =
    spaces.data && !dropZone.loading && !(dropZone.cause && dropZone.count === 0)
      ? householdCounts(spaces.data, dropZone.count)
      : null;
  const reconnecting = paired && connection.state === 'offline';

  const header = compact ? null : (
    <TabRootHeader
      title={householdName}
      actions={
        <IconButton
          icon="settings"
          accessibilityLabel={strings.home.settings}
          onPress={() => router.push('/settings')}
          testID="home-settings"
        />
      }
      subtitle={
        <>
          {counts ? (
            <AppText variant="meta" tone="graphite">
              {strings.home.summary(counts.spaces, counts.containers, counts.items)}
            </AppText>
          ) : null}
          {/* Where the data lives is always on screen (UX-10, UX-15). */}
          <View style={styles.caption}>
            <Icon
              name={paired ? 'server' : 'phone'}
              size={inlineIconSize(16, fontScale)}
              color={reconnecting ? colors.signal : colors.graphite}
            />
            <AppText
              variant="caption"
              tone={reconnecting ? 'signal' : 'graphite'}
              style={styles.captionText}
            >
              {reconnecting
                ? strings.connection.sharedReconnecting
                : paired
                  ? strings.connection.shared
                  : strings.connection.local}
            </AppText>
          </View>
        </>
      }
    />
  );

  function renderStatus(status: Extract<HomeEntry, { kind: 'status' }>['status']) {
    switch (status) {
      case 'loading':
        return (
          <View style={[styles.gutter, styles.block]}>
            <Skeleton variant="list" rows={4} />
          </View>
        );
      case 'searching':
        return searchStarted || mountSkeleton ? (
          <View style={[styles.gutter, styles.block]}>
            <Skeleton variant="rows" rows={5} />
          </View>
        ) : null;
      case 'error':
        // Never an empty list: a failed read must not look like "you own nothing".
        return (
          <ErrorState
            cause={recent.cause ?? spaces.cause}
            onRetry={reloadOverview}
            testID="home-error"
          />
        );
      case 'searchFailed': {
        const described = describeError(search.cause);
        return (
          <ErrorState
            cause={search.cause}
            title={described.kind === 'offline' ? undefined : strings.search.failed}
            onRetry={search.retry}
          />
        );
      }
      case 'noResults':
        return (
          <EmptyState
            icon="search"
            title={strings.search.none.title(trimmed)}
            body={strings.search.none.body}
            secondary={{
              label: strings.search.none.add(trimmed),
              onPress: () => router.push({ pathname: '/item/new', params: { name: trimmed } }),
              testID: 'search-add-missing',
            }}
          />
        );
      case 'empty':
        if (paired) {
          return (
            <EmptyState
              title={strings.home.empty.paired.titleIn(householdName)}
              body={strings.home.empty.paired.body}
              action={{
                label: strings.home.empty.paired.add,
                icon: 'plus',
                onPress: () => router.push('/item/new'),
              }}
              testID="home-empty"
            />
          );
        }
        return startHere ? (
          <EmptyState
            title={strings.home.empty.unpaired.title}
            body={strings.home.empty.unpaired.body}
            action={{
              label: strings.home.empty.unpaired.join,
              onPress: () => router.push('/household'),
            }}
            secondary={{
              label: strings.home.empty.unpaired.start,
              onPress: () => router.push('/space/new'),
            }}
            testID="home-empty"
          />
        ) : (
          <EmptyState
            title={strings.home.empty.local.title}
            body={strings.home.empty.local.body}
            action={{
              label: strings.home.empty.local.add,
              icon: 'plus',
              onPress: () => router.push('/item/new'),
            }}
            testID="home-empty"
          />
        );
    }
  }

  function renderEntry(entry: HomeEntry) {
    switch (entry.kind) {
      case 'field':
        return (
          <View style={[styles.field, { backgroundColor: colors.plaster }]}>
            <SearchField
              size="large"
              value={query}
              onChangeText={changeQuery}
              onSubmit={announceResults}
              onFocus={() => changeFocus(true)}
              onBlur={() => changeFocus(false)}
              placeholder={strings.home.searchPlaceholder}
              busy={search.pending}
              inputRef={inputRef}
              testID="search-input"
            />
          </View>
        );
      case 'notice':
        return (
          <View style={[styles.gutter, styles.block]}>
            {/* Part of the page rather than news, so it is read in order, not announced. */}
            <Banner
              tone="info"
              icon="phone"
              title={strings.home.unpaired.title}
              message={strings.home.unpaired.body}
              action={{
                label: strings.home.unpaired.join,
                onPress: () => router.push('/household'),
                testID: 'unpaired-join',
              }}
              secondary={{
                label: strings.common.notNow,
                onPress: notice.dismiss,
                accessibilityHint: strings.home.unpaired.notNowHint,
              }}
              live="off"
            />
          </View>
        );
      case 'refreshFailed':
        return (
          <View style={[styles.gutter, styles.block]}>
            <Banner
              tone="info"
              message={strings.errors.refreshFailed}
              action={{
                label: strings.common.tryAgain,
                onPress: searching ? search.retry : reloadOverview,
              }}
            />
          </View>
        );
      case 'dropZone':
        return (
          <View style={[styles.gutter, styles.block]}>
            <DropZoneCard
              items={dropZone.items}
              count={dropZone.count}
              onSort={() => goToTab('/drop-zone')}
              onQuickSnap={() => router.push(QUICK_SNAP_HREF)}
            />
          </View>
        );
      case 'summary':
        // Not a live region: it changes with every keystroke (`d8cf59d`).
        return (
          <View style={[styles.gutter, styles.summary]}>
            <AppText variant="meta" tone="graphite">
              {entry.text}
            </AppText>
          </View>
        );
      case 'title':
        return (
          <View style={styles.gutter}>
            <Section title={entry.title} count={entry.count} first={entry.first} />
          </View>
        );
      case 'totals':
        return (
          <View style={[styles.gutter, styles.totals]}>
            <TotalLine totals={entry.totals} />
          </View>
        );
      case 'item':
        return (
          <View
            style={[styles.gutter, sheetCell(entry.position.index, entry.position.count, colors)]}
          >
            {entry.position.index > 0 ? <SheetSeparator /> : null}
            <ItemRow
              item={entry.item}
              line="where"
              tool="chip"
              terms={searching ? search.results?.terms : undefined}
              expanded={expandedId === entry.item.id}
              onToggleExpand={toggleExpand}
              onPress={openItem}
            />
          </View>
        );
      case 'place':
        return (
          <View
            style={[styles.gutter, sheetCell(entry.position.index, entry.position.count, colors)]}
          >
            {entry.position.index > 0 ? <SheetSeparator /> : null}
            <PlaceRow
              hit={entry.hit}
              spaces={spacesById}
              containers={containersById}
              onPress={openPlace}
            />
          </View>
        );
      case 'more':
        return (
          <View style={[styles.gutter, styles.more]}>
            <Button
              label={strings.common.showMore}
              accessibilityLabel={strings.home.recentMoreA11y}
              variant="quiet"
              onPress={() => setRecentLimit(RECENT_MORE)}
              testID="recent-more"
            />
          </View>
        );
      case 'status':
        return renderStatus(entry.status);
    }
  }

  const renderItem: ListRenderItem<HomeEntry> = ({ item: entry }) => {
    if (entry.kind === 'field' || entry.kind === 'status') return renderEntry(entry);
    // Results for the previous query stay for continuity, but are never
    // tappable or announced as the answer to what is in the field now. The
    // wrapper is always there, so dimming never remounts a row (and its
    // quantity hook).
    const older = dim;
    return (
      <View
        style={older ? styles.dim : null}
        accessibilityElementsHidden={older}
        importantForAccessibility={older ? 'no-hide-descendants' : 'auto'}
      >
        {renderEntry(entry)}
      </View>
    );
  };

  return (
    <ScreenFrame kind="tabRoot">
      <FlatList
        ref={listRef}
        data={entries}
        keyExtractor={(entry) => entry.key}
        renderItem={renderItem}
        ListHeaderComponent={header}
        // The field is the first entry, after the title block when it shows.
        stickyHeaderIndices={[header ? 1 : 0]}
        onScroll={onScroll}
        scrollEventThrottle={32}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="on-drag"
        contentContainerStyle={styles.content}
        refreshControl={
          <RefreshControl
            refreshing={pulled}
            onRefresh={refresh}
            tintColor={colors.graphite}
            colors={[colors.ink]}
            progressBackgroundColor={colors.sheet}
          />
        }
        testID="home-list"
      />
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  content: {
    paddingBottom: space.xl,
  },
  caption: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.xs,
  },
  // Text beside an icon in a row is measured at the row's full width, so
  // without shrinking it runs past the gutter when it wraps at large sizes.
  captionText: {
    flexShrink: 1,
  },
  field: {
    paddingHorizontal: GUTTER,
    paddingVertical: space.sm,
  },
  gutter: {
    marginHorizontal: GUTTER,
  },
  block: {
    marginTop: space.md,
  },
  summary: {
    marginTop: space.xs,
  },
  totals: {
    marginBottom: space.sm,
  },
  more: {
    marginTop: space.sm,
  },
  dim: {
    opacity: 0.5,
    pointerEvents: 'none',
  },
});
