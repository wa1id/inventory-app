import { useState } from 'react';
import { Alert, FlatList, Pressable, StyleSheet, Text, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { ConflictError, HouseholdHttpError } from '@/services/household/client';
import { logEvent } from '@/services/telemetry';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { CONTAINER_ICONS, MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

/**
 * Files one item into a container.
 *
 * Flat rather than a space-then-container drill-down: most inventories have few
 * enough containers that one list beats two taps, and the space name rides
 * along on each row so the choice stays unambiguous.
 */
export default function MoveItemScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const { colors } = useTheme();

  const [saving, setSaving] = useState(false);

  const item = useInventoryQuery(() => repos.items.getById(id), `item:${id}`);
  const containers = useInventoryQuery(() => repos.containers.listAllWithSpace(), 'containers-all');

  async function moveTo(containerId: string) {
    if (saving) return;
    setSaving(true);
    try {
      await repos.items.update(id, {
        containerId,
        expectedUpdatedAt: item.data?.updatedAt,
      });
      logEvent('item_moved');
      invalidate();
      router.replace(`/container/${containerId}`);
    } catch (cause) {
      setSaving(false);
      Alert.alert(
        'Could not move',
        cause instanceof ConflictError
          ? strings.household.conflict
          : cause instanceof HouseholdHttpError &&
              (cause.code === 'offline' || cause.code === 'timeout')
            ? strings.household.offline
            : cause instanceof Error
              ? cause.message
              : 'The item could not be moved.',
      );
    }
  }

  if ((item.loading && !item.data) || (containers.loading && !containers.data)) {
    return (
      <Screen edges={['left', 'right', 'bottom']}>
        <LoadingState />
      </Screen>
    );
  }

  if (item.error || containers.error) {
    return (
      <Screen edges={['left', 'right', 'bottom']}>
        <ErrorState
          message={item.error ?? containers.error ?? 'That item no longer exists.'}
          onRetry={() => {
            item.reload();
            containers.reload();
          }}
        />
      </Screen>
    );
  }

  const list = containers.data ?? [];

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <FlatList
        data={list}
        keyExtractor={(container) => container.id}
        contentContainerStyle={[styles.list, list.length === 0 && styles.listEmpty]}
        ListHeaderComponent={
          item.data ? (
            <Text style={[styles.intro, { color: colors.textMuted }]}>
              {strings.dropZone.moveIntro(item.data.name || strings.items.unnamed)}
            </Text>
          ) : null
        }
        renderItem={({ item: container }) => (
          <Pressable
            onPress={() => void moveTo(container.id)}
            disabled={saving}
            accessibilityRole="button"
            accessibilityLabel={`${container.name ?? container.shortCode}, in ${container.spaceName}`}
            testID={`move-to-${container.id}`}
            style={({ pressed }) => [
              styles.row,
              {
                backgroundColor: colors.surface,
                borderColor: colors.border,
                opacity: saving ? 0.5 : pressed ? 0.8 : 1,
              },
            ]}
          >
            <Text style={styles.glyph} accessibilityElementsHidden importantForAccessibility="no">
              {CONTAINER_ICONS[container.visualType] ?? CONTAINER_ICONS.other}
            </Text>
            <View style={styles.rowBody}>
              <Text style={[styles.rowTitle, { color: colors.text }]} numberOfLines={1}>
                {container.name ?? container.shortCode}
              </Text>
              <Text style={[styles.rowMeta, { color: colors.textMuted }]} numberOfLines={1}>
                {container.spaceName} · {container.itemCount} item
                {container.itemCount === 1 ? '' : 's'}
              </Text>
            </View>
            <Text style={[styles.chevron, { color: colors.textMuted }]}>›</Text>
          </Pressable>
        )}
        ListEmptyComponent={
          <EmptyState
            icon="📦"
            title={strings.dropZone.noContainers.title}
            body={strings.dropZone.noContainers.body}
            actionLabel={strings.spaces.create}
            onAction={() => router.replace('/space/new')}
            testID="move-no-containers"
          />
        }
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: {
    padding: spacing.lg,
    gap: spacing.sm,
  },
  listEmpty: {
    flexGrow: 1,
    justifyContent: 'center',
  },
  intro: {
    fontSize: 14,
    lineHeight: 20,
    marginBottom: spacing.sm,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.md,
    borderRadius: radius.lg,
    borderWidth: 1,
    minHeight: MIN_TOUCH_TARGET,
  },
  glyph: {
    fontSize: 26,
  },
  rowBody: {
    flex: 1,
    gap: 2,
  },
  rowTitle: {
    fontSize: 16,
    fontWeight: '700',
  },
  rowMeta: {
    fontSize: 14,
  },
  chevron: {
    fontSize: 26,
  },
});
