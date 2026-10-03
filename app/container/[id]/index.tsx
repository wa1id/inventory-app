import { useEffect, useMemo, useState, type ReactElement } from 'react';
import { Animated, FlatList, Pressable, StyleSheet, View } from 'react-native';
import { Stack, router, useLocalSearchParams } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { useCollapsingTitle } from '@/hooks/useCollapsingTitle';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { spellCode } from '@/ui/a11y';
import { rememberCategories } from '@/ui/categoryMemory';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { Icon } from '@/ui/components/Icon';
import { IconButton } from '@/ui/components/IconButton';
import { ItemRow } from '@/ui/components/ItemRow';
import { PressedOverlay, rippleFor, useFocusRing } from '@/ui/components/PressFeedback';
import { ScreenFrame, SearchButton } from '@/ui/components/ScreenFrame';
import { Section, GutterSheetSeparator, sheetCell } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { SpacePip } from '@/ui/components/SpacePip';
import { Tape } from '@/ui/components/Tape';
import { isFreshArrival, sortContents, titleOf, typeNameOf } from '@/ui/container/containerRules';
import { needsRefreshBanner } from '@/ui/errors';
import { motionMs, useReducedMotion } from '@/ui/motion';
import { goToTab, openSpace } from '@/ui/navigation';
import { usePullToRefresh } from '@/ui/spaces/usePullToRefresh';
import { GUTTER, MIN_TOUCH_TARGET, ROW_GAP, TYPE_ICON, space, useTheme } from '@/ui/theme';

/** How long a just-added row stays picked out before it starts to fade. */
const ARRIVAL_HOLD_MS = 600;
/** The fade itself. */
const ARRIVAL_FADE_MS = 1200;

/** Stable for the memoised rows: they hand back the item's id. */
function openItem(itemId: string) {
  router.push(`/item/${itemId}`);
}

/**
 * The drop zone is a real container row, but its screen is the Drop zone tab.
 * An old link goes there, in an effect rather than with
 * `<Redirect>`, which would stack a second tab shell.
 */
function ToDropZone() {
  useEffect(() => {
    goToTab('/drop-zone');
  }, []);
  return null;
}

/** Search and, once the container is known, Edit, as icons. */
function HeaderActions({ containerId, title }: { containerId: string; title: string | null }) {
  return (
    <View style={styles.headerActions}>
      <SearchButton />
      {title !== null ? (
        <IconButton
          icon="edit"
          accessibilityLabel={strings.container.edit(title)}
          onPress={() => router.push(`/container/${containerId}/edit`)}
          testID="container-edit"
        />
      ) : null}
    </View>
  );
}

interface CrumbSpace {
  id: string;
  name: string;
  color: string;
}

/**
 * "● Garage ›": the way back up to the space, a link rather than plain text,
 * so the space is one tap away however the container was opened.
 */
function SpaceCrumb({ place }: { place: CrumbSpace }) {
  const { colors } = useTheme();
  const focus = useFocusRing();
  return (
    <Pressable
      onPress={() => openSpace(place.id)}
      onFocus={focus.onFocus}
      onBlur={focus.onBlur}
      accessibilityRole="link"
      accessibilityLabel={strings.container.crumbA11y(place.name)}
      android_ripple={rippleFor(colors)}
      testID="container-space"
      style={[styles.crumb, focus.ringStyle]}
    >
      {({ pressed }) => (
        <>
          <PressedOverlay pressed={pressed} radius={6} />
          <SpacePip color={place.color} size={10} />
          <AppText variant="label" tone="graphite" style={styles.crumbName}>
            {place.name}
          </AppText>
          <Icon name="chevronRight" size={16} color={colors.graphite} />
        </>
      )}
    </Pressable>
  );
}

/**
 * The selected fill and ink bar on a row that has just arrived from Add, so
 * the eye finds it among the others; it fades out (at once under reduced
 * motion). Decided once, when the row first appears.
 */
function ArrivalHighlight({ createdAt }: { createdAt: number }) {
  const { colors } = useTheme();
  const reduced = useReducedMotion();
  const [fresh] = useState(() => isFreshArrival(createdAt, Date.now()));
  const [opacity] = useState(() => new Animated.Value(1));
  const [faded, setFaded] = useState(!fresh);

  useEffect(() => {
    if (!fresh) return;
    const fade = Animated.timing(opacity, {
      toValue: 0,
      delay: ARRIVAL_HOLD_MS + (reduced ? ARRIVAL_FADE_MS : 0),
      duration: motionMs(ARRIVAL_FADE_MS, reduced),
      useNativeDriver: true,
    });
    fade.start(({ finished }) => {
      if (finished) setFaded(true);
    });
    return () => fade.stop();
  }, [fresh, opacity, reduced]);

  if (faded) return null;
  return (
    <Animated.View
      pointerEvents="none"
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[StyleSheet.absoluteFill, { opacity, backgroundColor: colors.selected }]}
    >
      <View style={[styles.arrivalBar, { backgroundColor: colors.ink }]} />
    </Animated.View>
  );
}

export default function ContainerScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  if (id === DROP_ZONE_CONTAINER_ID) return <ToDropZone />;
  return <ContainerDetail id={id} />;
}

/**
 * "What's in this box?": the answer when a label is scanned, and where
 * things are counted and added.
 *
 * Its space is a link above the title, its code is the big tape from the box,
 * and what is in it reads by name with a stepper on every row. Nothing shows
 * until both the container and its contents have been read, so it never
 * flashes "empty" on the way, and a failed read of the contents is said as
 * such rather than as an empty box.
 */
function ContainerDetail({ id }: { id: string }) {
  const repos = useRepositories();
  const { colors } = useTheme();
  const insets = useSafeAreaInsets();
  const { stacked } = useLayoutScale();

  const containerQuery = useInventoryQuery(
    () => repos.containers.getWithCounts(id),
    `container:${id}`,
  );
  const itemsQuery = useInventoryQuery(() => repos.items.listByContainer(id), `items-of:${id}`);
  const spaceId = containerQuery.data?.spaceId ?? null;
  const spaceQuery = useInventoryQuery(
    async () => (spaceId ? repos.spaces.getById(spaceId) : null),
    `space:${spaceId ?? 'none'}`,
  );

  const container = containerQuery.data;
  const items = itemsQuery.data;
  const sorted = useMemo(() => (items ? sortContents(items) : []), [items]);
  const title = container ? titleOf(container) : '';
  const { onScroll, onTitleLayout } = useCollapsingTitle(title);

  // Category suggestions in the Add and Edit forms come from what has been seen.
  useEffect(() => {
    if (items) rememberCategories(items);
  }, [items]);

  function reloadAll() {
    containerQuery.reload();
    itemsQuery.reload();
    spaceQuery.reload();
  }
  const refreshControl = usePullToRefresh(
    containerQuery.loading || itemsQuery.loading || spaceQuery.loading,
    reloadAll,
  );

  function addHere() {
    router.push({ pathname: '/item/new', params: { containerId: id } });
  }
  function takePhoto() {
    // A container is a single-item entry point.
    router.push({ pathname: '/capture', params: { containerId: id } });
  }

  const headerOptions = (
    <Stack.Screen
      options={{
        headerRight: () => (
          <HeaderActions containerId={id} title={container ? titleOf(container) : null} />
        ),
      }}
    />
  );

  let blocking: ReactElement | null = null;
  if (container === null) {
    if (containerQuery.cause) {
      blocking = (
        <ErrorState cause={containerQuery.cause} subject="container" onRetry={reloadAll} />
      );
    } else if (containerQuery.loading) {
      blocking = <LoadingDetail />;
    } else {
      // Read fine, but nothing there: deleted, probably on another phone.
      blocking = (
        <ErrorState
          cause={null}
          subject="container"
          secondary={{ label: strings.common.goToSpaces, onPress: () => goToTab('/spaces') }}
        />
      );
    }
  } else if (items === null && !itemsQuery.cause) {
    blocking = <LoadingDetail />;
  }

  if (container === null || blocking !== null) {
    return (
      <ScreenFrame kind="detail">
        {headerOptions}
        {blocking}
      </ScreenFrame>
    );
  }

  // The space comes from its own read, or from any row, which carries it too.
  const first = sorted[0];
  const place: CrumbSpace | null = spaceQuery.data
    ? { id: spaceQuery.data.id, name: spaceQuery.data.name, color: spaceQuery.data.color }
    : first
      ? { id: first.spaceId, name: first.spaceName, color: first.spaceColor }
      : null;
  const typeName = typeNameOf(container.visualType);
  const count = items ? items.length : container.itemCount;
  const linked = container.qrToken !== null;
  const refreshFailed =
    needsRefreshBanner(containerQuery.refreshFailed, containerQuery.cause) ||
    needsRefreshBanner(itemsQuery.refreshFailed, itemsQuery.cause);

  const head = (
    <View style={styles.head}>
      {place ? (
        <SpaceCrumb place={place} />
      ) : spaceQuery.cause ? null : (
        // Keeps the title from jumping down when the space arrives.
        <View style={styles.crumbPlaceholder} />
      )}
      <AppText variant="title" onLayout={onTitleLayout}>
        {title}
      </AppText>
      <AppText variant="meta" tone="graphite" style={styles.sub}>
        {/* Empty: just the type, as "This bin is empty" below says the rest. */}
        {items !== null && items.length === 0 ? typeName : strings.container.sub(typeName, count)}
      </AppText>
      <View style={[styles.codeRow, stacked ? styles.codeRowStacked : null]}>
        <View
          accessible
          accessibilityRole="text"
          accessibilityLabel={strings.a11y.labelCodeTitle(spellCode(container.shortCode))}
        >
          <Tape code={container.shortCode} size="l" />
        </View>
        <View>
          <Button
            label={linked ? strings.container.qrLinked : strings.container.qrNone}
            accessibilityLabel={linked ? strings.container.qrLinkedA11y : strings.container.qrNone}
            icon="qr"
            variant="secondary"
            size="sm"
            onPress={() => router.push(`/container/${id}/qr`)}
            testID="container-qr"
          />
        </View>
      </View>
      {refreshFailed ? (
        <View style={styles.banner}>
          <Banner
            tone="info"
            message={strings.errors.refreshFailed}
            action={{ label: strings.common.tryAgain, onPress: reloadAll }}
          />
        </View>
      ) : null}
      {sorted.length > 0 ? (
        <Section title={strings.container.inHere} count={sorted.length} />
      ) : null}
    </View>
  );

  const empty =
    items === null ? (
      <ErrorState cause={itemsQuery.cause} onRetry={itemsQuery.reload} />
    ) : (
      <EmptyState
        icon={TYPE_ICON[container.visualType] ?? 'other'}
        title={strings.container.empty.title(typeName)}
        body={strings.container.empty.body}
        action={{
          label: strings.container.addHere,
          icon: 'plus',
          onPress: addHere,
          testID: 'items-empty',
        }}
        secondary={{
          label: strings.container.takePhoto,
          icon: 'camera',
          onPress: takePhoto,
          testID: 'items-capture-empty',
        }}
      />
    );

  const hasBar = sorted.length > 0;

  return (
    <ScreenFrame
      kind="detail"
      bottomBar={
        hasBar ? (
          // One bar, 72 pt, instead of two stacked full-width buttons (≈ 130 pt):
          // the camera as an icon, "Add here" as the primary under the thumb.
          <BottomBar>
            <View style={styles.barRow}>
              <IconButton
                icon="camera"
                variant="outlined"
                accessibilityLabel={strings.container.takePhotoA11y}
                onPress={takePhoto}
                testID="items-capture"
              />
              <Button
                label={strings.container.addHere}
                icon="plus"
                onPress={addHere}
                fullWidth
                style={styles.barPrimary}
                testID="items-add"
              />
            </View>
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
            <ArrivalHighlight createdAt={item.createdAt} />
            <ItemRow item={item} line="detail" tool="stepper" onPress={openItem} />
          </View>
        )}
        ItemSeparatorComponent={GutterSheetSeparator}
        ListHeaderComponent={head}
        ListEmptyComponent={empty}
        onScroll={onScroll}
        scrollEventThrottle={16}
        refreshControl={refreshControl}
        // Typing a count in a row's stepper must not be cut short by a tap
        // elsewhere, nor hidden behind the number pad on a low row (iOS).
        keyboardShouldPersistTaps="handled"
        automaticallyAdjustKeyboardInsets
        // The bottom bar pads the home indicator itself; without it the list does.
        contentContainerStyle={{ paddingBottom: space.xl + (hasBar ? 0 : insets.bottom) }}
      />
    </ScreenFrame>
  );
}

function LoadingDetail() {
  return (
    <View style={styles.loading}>
      <Skeleton variant="detail" />
    </View>
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
  loading: {
    padding: GUTTER,
  },
  // No bottom padding: "In here" brings its own gap, and so does the empty state.
  head: {
    paddingHorizontal: GUTTER,
  },
  crumb: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    gap: space.xs + 2,
    minHeight: MIN_TOUCH_TARGET,
    // The text lines up with the gutter; the pressed fill reaches a little past it.
    marginStart: -space.xs,
    paddingHorizontal: space.xs,
    borderRadius: 6,
    overflow: 'hidden',
  },
  crumbName: {
    flexShrink: 1,
  },
  crumbPlaceholder: {
    minHeight: MIN_TOUCH_TARGET,
  },
  sub: {
    marginTop: space.xxs,
  },
  codeRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.md,
    marginTop: space.lg,
  },
  codeRowStacked: {
    flexDirection: 'column',
    alignItems: 'flex-start',
  },
  banner: {
    marginTop: space.lg,
  },
  arrivalBar: {
    position: 'absolute',
    start: 0,
    top: 0,
    bottom: 0,
    width: 3,
  },
  barRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: ROW_GAP,
  },
  barPrimary: {
    flex: 1,
  },
});
