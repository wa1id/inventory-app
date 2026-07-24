import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import type { SpaceWithCounts } from '@/db/types';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

function SpaceCard({ space, onPress }: { space: SpaceWithCounts; onPress: () => void }) {
  const { colors } = useTheme();

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
        {
          backgroundColor: colors.surface,
          borderColor: colors.border,
          opacity: pressed ? 0.8 : 1,
        },
      ]}
    >
      <View style={[styles.swatch, { backgroundColor: space.color }]}>
        <Text style={styles.swatchIcon} accessibilityElementsHidden importantForAccessibility="no">
          {space.icon}
        </Text>
      </View>
      <View style={styles.cardBody}>
        <Text style={[styles.cardTitle, { color: colors.text }]} numberOfLines={2}>
          {space.name}
        </Text>
        <Text style={[styles.cardMeta, { color: colors.textMuted }]}>
          {strings.spaces.counts(space.containerCount, space.itemCount)}
        </Text>
      </View>
      <Text
        style={[styles.chevron, { color: colors.textMuted }]}
        accessibilityElementsHidden
        importantForAccessibility="no"
      >
        ›
      </Text>
    </Pressable>
  );
}

export default function SpacesScreen() {
  const repos = useRepositories();
  const router = useRouter();

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
        ListFooterComponent={
          spaces.length > 0 ? (
            <View style={styles.footer}>
              <Button
                label={strings.spaces.create}
                icon="＋"
                onPress={() => router.push('/space/new')}
                fullWidth
                variant="secondary"
              />
            </View>
          ) : null
        }
      />
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
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.md,
    borderRadius: radius.lg,
    borderWidth: 1,
    minHeight: MIN_TOUCH_TARGET + spacing.lg,
  },
  swatch: {
    width: 48,
    height: 48,
    borderRadius: radius.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  swatchIcon: {
    fontSize: 24,
  },
  cardBody: {
    flex: 1,
    gap: 2,
  },
  cardTitle: {
    fontSize: 17,
    fontWeight: '700',
  },
  cardMeta: {
    fontSize: 14,
  },
  chevron: {
    fontSize: 28,
    paddingHorizontal: spacing.xs,
  },
  footer: {
    paddingTop: spacing.sm,
  },
});
