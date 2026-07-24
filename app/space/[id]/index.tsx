import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';

import type { ContainerWithCounts } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { CONTAINER_ICONS, MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

function ContainerCard({
  container,
  onPress,
}: {
  container: ContainerWithCounts;
  onPress: () => void;
}) {
  const { colors } = useTheme();
  const title = container.name ?? container.shortCode;

  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${title}, ${container.itemCount} item${
        container.itemCount === 1 ? '' : 's'
      }${container.qrToken ? ', QR label attached' : ''}`}
      style={({ pressed }) => [
        styles.card,
        { backgroundColor: colors.surface, borderColor: colors.border, opacity: pressed ? 0.8 : 1 },
      ]}
    >
      <Text style={styles.icon} accessibilityElementsHidden importantForAccessibility="no">
        {CONTAINER_ICONS[container.visualType] ?? CONTAINER_ICONS.other}
      </Text>
      <View style={styles.cardBody}>
        <Text style={[styles.cardTitle, { color: colors.text }]} numberOfLines={2}>
          {title}
        </Text>
        <Text style={[styles.cardMeta, { color: colors.textMuted }]}>
          {container.shortCode} · {container.itemCount} item
          {container.itemCount === 1 ? '' : 's'}
        </Text>
      </View>
      {container.qrToken ? (
        <Text style={styles.qrBadge} accessibilityElementsHidden importantForAccessibility="no">
          🏷️
        </Text>
      ) : null}
    </Pressable>
  );
}

export default function SpaceScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const router = useRouter();
  const { colors } = useTheme();

  const space = useInventoryQuery(() => repos.spaces.getById(id), `space:${id}`);
  const containers = useInventoryQuery(
    () => repos.containers.listBySpace(id),
    `containers-of:${id}`,
  );

  if ((space.loading && !space.data) || (containers.loading && !containers.data)) {
    return (
      <Screen edges={['left', 'right']}>
        <LoadingState />
      </Screen>
    );
  }

  if (space.error || containers.error || !space.data) {
    return (
      <Screen edges={['left', 'right']}>
        <ErrorState
          message={space.error ?? containers.error ?? 'That space no longer exists.'}
          onRetry={() => {
            space.reload();
            containers.reload();
          }}
        />
      </Screen>
    );
  }

  const list = containers.data ?? [];

  return (
    <Screen edges={['left', 'right']}>
      <Stack.Screen
        options={{
          title: space.data.name,
          headerRight: () => (
            <Pressable
              onPress={() => router.push(`/space/${id}/edit`)}
              accessibilityRole="button"
              accessibilityLabel={`Edit ${space.data?.name ?? 'space'}`}
              hitSlop={spacing.sm}
              style={styles.headerButton}
            >
              <Text style={{ color: colors.primary, fontSize: 16, fontWeight: '600' }}>
                {strings.common.edit}
              </Text>
            </Pressable>
          ),
        }}
      />

      <FlatList
        data={list}
        keyExtractor={(container) => container.id}
        contentContainerStyle={[styles.list, list.length === 0 && styles.listEmpty]}
        renderItem={({ item }) => (
          <ContainerCard container={item} onPress={() => router.push(`/container/${item.id}`)} />
        )}
        ListEmptyComponent={
          <EmptyState
            icon="📦"
            title={strings.containers.empty.title}
            body={strings.containers.empty.body}
            actionLabel={strings.containers.empty.action}
            onAction={() => router.push(`/container/new?spaceId=${id}`)}
            testID="containers-empty"
          />
        }
        ListFooterComponent={
          list.length > 0 ? (
            <View style={styles.footer}>
              <Button
                label={strings.containers.create}
                icon="＋"
                variant="secondary"
                fullWidth
                onPress={() => router.push(`/container/new?spaceId=${id}`)}
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
    minHeight: MIN_TOUCH_TARGET + spacing.md,
  },
  icon: {
    fontSize: 28,
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
  qrBadge: {
    fontSize: 18,
  },
  footer: {
    paddingTop: spacing.sm,
  },
  headerButton: {
    minHeight: MIN_TOUCH_TARGET,
    justifyContent: 'center',
    paddingHorizontal: spacing.sm,
  },
});
