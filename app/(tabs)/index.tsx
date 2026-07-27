import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import type { SpaceWithCounts } from '@/db/types';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { onColor, radius, spacing, useTheme } from '@/ui/theme';

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

export default function SpacesScreen() {
  const repos = useRepositories();
  const router = useRouter();
  const { colors } = useTheme();

  const { data, loading, error, reload } = useInventoryQuery(
    () => repos.spaces.listWithCounts(),
    'spaces',
  );

  if (loading && data === null) {
    return (
      <Screen edges={['left', 'right']}>
        <LoadingState />
      </Screen>
    );
  }

  if (error) {
    return (
      <Screen edges={['left', 'right']}>
        <ErrorState message={error} onRetry={reload} />
      </Screen>
    );
  }

  const spaces = data ?? [];

  return (
    <Screen edges={['left', 'right']}>
      <FlatList
        data={spaces}
        keyExtractor={(space) => space.id}
        numColumns={2}
        columnWrapperStyle={spaces.length > 0 ? styles.column : undefined}
        contentContainerStyle={[styles.list, spaces.length === 0 && styles.listEmpty]}
        renderItem={({ item }) => (
          <SpaceCard space={item} onPress={() => router.push(`/space/${item.id}`)} />
        )}
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
