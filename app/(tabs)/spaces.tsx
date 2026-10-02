import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { useDropZone } from '@/providers/DropZoneProvider';
import type { SpaceWithCounts } from '@/db/types';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState, LoadingState, Screen, TabRootHeader } from '@/ui/components/Screen';
import { goToTab } from '@/ui/navigation';
import { onColor, radius, spacing, useTheme } from '@/ui/theme';

/** Fills the empty half of a trailing odd row so tiles keep a uniform width. */
const GRID_SPACER = Symbol('grid-spacer');

/**
 * A space as a colour-filled tile.
 *
 * The dashboard is the screen people see most, and spaces are recognised by
 * their colour and icon long before the label is read — so the tile leads with
 * both, and the container count rides in a corner badge rather than competing
 * with the name.
 */
function SpaceCard({ space, onPress }: { space: SpaceWithCounts; onPress: () => void }) {
  const foreground = onColor(space.color);

  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${space.name}, ${strings.spaces.counts(
        space.containerCount,
        space.itemCount,
      )}`}
      style={({ pressed }) => [
        styles.card,
        { backgroundColor: space.color, opacity: pressed ? 0.85 : 1 },
      ]}
    >
      <View style={styles.badgeRow}>
        <View style={[styles.badge, { backgroundColor: `${foreground}26` }]}>
          <Text style={[styles.badgeText, { color: foreground }]}>📦 {space.containerCount}</Text>
        </View>
      </View>

      <Text style={styles.cardIcon} accessibilityElementsHidden importantForAccessibility="no">
        {space.icon}
      </Text>

      <View style={styles.cardBody}>
        <Text style={[styles.cardTitle, { color: foreground }]} numberOfLines={2}>
          {space.name}
        </Text>
        <Text style={[styles.cardMeta, { color: foreground }]}>
          {strings.spaces.itemCount(space.itemCount)}
        </Text>
      </View>
    </Pressable>
  );
}

/**
 * A temporary copy of the pre-redesign dashboard, so browsing spaces keeps
 * working in the new tab bar until the Spaces tab is rebuilt (S2, spec §5.3).
 * Changes from the original: a "Spaces" title (the tab shell has no header),
 * the drop-zone count comes from the shared `DropZoneProvider` read (B9), the
 * card goes to the Drop zone tab with `goToTab` rather than pushing a path,
 * and a failed read is described rather than shown raw.
 */
export default function SpacesScreen() {
  const repos = useRepositories();
  const router = useRouter();
  const { colors } = useTheme();

  const { data, loading, cause, reload } = useInventoryQuery(
    () => repos.spaces.listWithCounts(),
    'spaces',
  );
  const dropZone = useDropZone();

  if (loading && data === null) {
    return (
      <Screen edges={['left', 'right']}>
        <LoadingState />
      </Screen>
    );
  }

  // A failed refresh keeps the spaces already on screen; the error page is
  // only for a first read that failed, in plain words rather than its code (B8).
  if (cause && data === null) {
    return (
      <Screen edges={['left', 'right']}>
        <ErrorState cause={cause} onRetry={reload} />
      </Screen>
    );
  }

  const spaces = data ?? [];
  // Tiles flex to fill their row, so an odd count would stretch the last one
  // across the full width. A trailing spacer keeps it half-width like the rest.
  const grid: (SpaceWithCounts | typeof GRID_SPACER)[] =
    spaces.length % 2 === 1 ? [...spaces, GRID_SPACER] : spaces;

  return (
    <Screen edges={['left', 'right']}>
      {/* The tab shell has no header, so the tab root carries its own title. */}
      <TabRootHeader title={strings.tabs.spaces} />
      <FlatList
        data={grid}
        keyExtractor={(entry) => (entry === GRID_SPACER ? 'grid-spacer' : entry.id)}
        numColumns={2}
        columnWrapperStyle={spaces.length > 0 ? styles.column : undefined}
        contentContainerStyle={[styles.list, spaces.length === 0 && styles.listEmpty]}
        renderItem={({ item }) =>
          item === GRID_SPACER ? (
            <View style={styles.spacer} />
          ) : (
            <SpaceCard space={item} onPress={() => router.push(`/space/${item.id}`)} />
          )
        }
        ListHeaderComponent={
          <Pressable
            onPress={() => goToTab('/drop-zone')}
            accessibilityRole="button"
            accessibilityLabel={`${strings.dropZone.title}. ${strings.dropZone.count(
              dropZone.count,
            )}`}
            testID="drop-zone-card"
            style={({ pressed }) => [
              styles.dropZone,
              { borderColor: colors.primary, opacity: pressed ? 0.8 : 1 },
            ]}
          >
            <View style={styles.dropZoneBody}>
              <Text style={[styles.dropZoneTitle, { color: colors.text }]}>
                📥 {strings.dropZone.title}
              </Text>
              <Text style={[styles.dropZoneMeta, { color: colors.textMuted }]}>
                {dropZone.count > 0
                  ? strings.dropZone.count(dropZone.count)
                  : strings.dropZone.tagline}
              </Text>
            </View>
            <Button
              label={strings.dropZone.quickSnap}
              icon="📸"
              onPress={() =>
                router.push(`/capture?containerId=${DROP_ZONE_CONTAINER_ID}&mode=fast`)
              }
              testID="quick-snap"
            />
          </Pressable>
        }
        ListEmptyComponent={
          <EmptyState
            icon="🏠"
            title={strings.spaces.empty.title}
            body={strings.spaces.empty.body}
            actionLabel={strings.spaces.empty.action}
            onAction={() => router.push('/space/new')}
            testID="spaces-empty"
          />
        }
      />

      {/* Pinned rather than a list footer: creating spaces stays one tap away
          no matter how far the grid has been scrolled. */}
      {spaces.length > 0 ? (
        <View
          style={[
            styles.actionBar,
            { backgroundColor: colors.background, borderTopColor: colors.border },
          ]}
        >
          <Button
            label={strings.spaces.create}
            icon="＋"
            onPress={() => router.push('/space/new')}
            fullWidth
            testID="spaces-create"
          />
        </View>
      ) : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  listEmpty: {
    flexGrow: 1,
    justifyContent: 'center',
  },
  column: {
    gap: spacing.md,
  },
  dropZone: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.md,
    marginBottom: spacing.md,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderStyle: 'dashed',
  },
  dropZoneBody: {
    flex: 1,
    gap: 2,
  },
  dropZoneTitle: {
    fontSize: 17,
    fontWeight: '700',
  },
  dropZoneMeta: {
    fontSize: 14,
  },
  spacer: {
    flex: 1,
  },
  card: {
    flex: 1,
    minHeight: 168,
    padding: spacing.md,
    borderRadius: radius.lg,
    justifyContent: 'space-between',
  },
  badgeRow: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
  },
  badge: {
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    borderRadius: radius.pill,
  },
  badgeText: {
    fontSize: 12,
    fontWeight: '700',
  },
  cardIcon: {
    fontSize: 40,
    textAlign: 'center',
  },
  cardBody: {
    gap: 2,
  },
  cardTitle: {
    fontSize: 18,
    fontWeight: '700',
  },
  cardMeta: {
    fontSize: 14,
    opacity: 0.85,
  },
  actionBar: {
    padding: spacing.lg,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
});
