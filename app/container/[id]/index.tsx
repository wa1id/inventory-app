import { FlatList, Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';

import type { ItemWithContext } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { CONTAINER_ICONS, MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

function ItemCard({ item, onPress }: { item: ItemWithContext; onPress: () => void }) {
  const { colors } = useTheme();

  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${item.name || strings.items.unnamed}${
        item.quantity > 1 ? `, quantity ${item.quantity}` : ''
      }`}
      style={({ pressed }) => [
        styles.itemCard,
        { backgroundColor: colors.surface, borderColor: colors.border, opacity: pressed ? 0.8 : 1 },
      ]}
    >
      {item.photoUri ? (
        <Image
          source={{ uri: item.photoUri }}
          style={styles.thumb}
          accessibilityIgnoresInvertColors
        />
      ) : (
        <View
          style={[styles.thumb, styles.thumbPlaceholder, { backgroundColor: colors.surfaceAlt }]}
        >
          <Text style={styles.thumbGlyph}>🧾</Text>
        </View>
      )}
      <View style={styles.itemBody}>
        <Text
          style={[
            styles.itemTitle,
            { color: item.name ? colors.text : colors.textMuted },
            !item.name && styles.itemTitleUnnamed,
          ]}
          numberOfLines={2}
        >
          {item.name || strings.items.unnamed}
        </Text>
        {item.category ? (
          <Text style={[styles.itemMeta, { color: colors.textMuted }]} numberOfLines={1}>
            {item.category}
          </Text>
        ) : null}
      </View>
      {item.quantity > 1 ? (
        <View style={[styles.qtyBadge, { backgroundColor: colors.surfaceAlt }]}>
          <Text style={[styles.qtyText, { color: colors.text }]}>×{item.quantity}</Text>
        </View>
      ) : null}
    </Pressable>
  );
}

export default function ContainerScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const router = useRouter();
  const { colors } = useTheme();

  const container = useInventoryQuery(() => repos.containers.getWithCounts(id), `container:${id}`);
  const items = useInventoryQuery(() => repos.items.listByContainer(id), `items-of:${id}`);
  const space = useInventoryQuery(
    async () => (container.data ? repos.spaces.getById(container.data.spaceId) : null),
    `space:${container.data?.spaceId ?? 'none'}`,
  );

  if (container.loading && !container.data) {
    return (
      <Screen edges={['left', 'right']}>
        <LoadingState />
      </Screen>
    );
  }

  if (container.error || !container.data) {
    return (
      <Screen edges={['left', 'right']}>
        <ErrorState
          message={container.error ?? 'That container no longer exists.'}
          onRetry={container.reload}
        />
      </Screen>
    );
  }

  const data = container.data;
  const title = data.name ?? data.shortCode;
  const list = items.data ?? [];

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <Stack.Screen
        options={{
          title,
          headerRight: () => (
            <Pressable
              onPress={() => router.push(`/container/${id}/edit`)}
              accessibilityRole="button"
              accessibilityLabel={`Edit ${title}`}
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
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.list}
        ListHeaderComponent={
          <View
            style={[styles.header, { backgroundColor: colors.surface, borderColor: colors.border }]}
          >
            <View style={styles.headerTop}>
              <Text
                style={styles.headerIcon}
                accessibilityElementsHidden
                importantForAccessibility="no"
              >
                {CONTAINER_ICONS[data.visualType] ?? CONTAINER_ICONS.other}
              </Text>
              <View style={styles.headerText}>
                <Text style={[styles.headerCode, { color: colors.textMuted }]}>
                  {space.data ? `${space.data.icon} ${space.data.name} · ` : ''}
                  {data.shortCode}
                </Text>
                <Text style={[styles.headerCount, { color: colors.text }]}>
                  {data.itemCount} item{data.itemCount === 1 ? '' : 's'}
                </Text>
              </View>
            </View>

            {/* Reserved QR slot the QR issue fills in (issue #5). */}
            <Pressable
              onPress={() => router.push(`/container/${id}/qr`)}
              accessibilityRole="button"
              accessibilityLabel={
                data.qrToken ? strings.containers.qrBound : strings.containers.qrUnbound
              }
              accessibilityHint="Opens the QR label for this container"
              style={[styles.qrRow, { borderColor: colors.border }]}
            >
              <Text style={styles.qrGlyph}>🏷️</Text>
              <Text
                style={[
                  styles.qrLabel,
                  { color: data.qrToken ? colors.success : colors.textMuted },
                ]}
              >
                {data.qrToken ? strings.containers.qrBound : strings.containers.qrUnbound}
              </Text>
              <Text style={[styles.chevron, { color: colors.textMuted }]}>›</Text>
            </Pressable>
          </View>
        }
        renderItem={({ item }) => (
          <ItemCard item={item} onPress={() => router.push(`/item/${item.id}`)} />
        )}
        ListEmptyComponent={
          <EmptyState
            icon="🧾"
            title={strings.items.empty.title}
            body={strings.items.empty.body}
            actionLabel={strings.items.empty.photoAction}
            onAction={() => router.push(`/capture?containerId=${id}`)}
            secondaryActionLabel={strings.items.empty.manualAction}
            onSecondaryAction={() => router.push(`/item/new?containerId=${id}`)}
            testID="items-empty"
          />
        }
      />

      {/* Pinned, and inside the bottom safe area: as a list footer this sat
          under the system navigation bar, so the main way into the capture
          flow was partly unreachable. */}
      {list.length > 0 ? (
        <View
          style={[
            styles.actionBar,
            { backgroundColor: colors.background, borderTopColor: colors.border },
          ]}
        >
          <Button
            label={strings.items.empty.photoAction}
            icon="📸"
            fullWidth
            onPress={() => router.push(`/capture?containerId=${id}`)}
            testID="items-capture"
          />
          <Button
            label={strings.items.empty.manualAction}
            variant="secondary"
            fullWidth
            onPress={() => router.push(`/item/new?containerId=${id}`)}
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
  header: {
    borderRadius: radius.lg,
    borderWidth: 1,
    padding: spacing.md,
    gap: spacing.md,
    marginBottom: spacing.xs,
  },
  headerTop: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
  },
  headerIcon: {
    fontSize: 32,
  },
  headerText: {
    flex: 1,
    gap: 2,
  },
  headerCode: {
    fontSize: 14,
  },
  headerCount: {
    fontSize: 17,
    fontWeight: '700',
  },
  qrRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    borderTopWidth: 1,
    paddingTop: spacing.md,
    minHeight: MIN_TOUCH_TARGET,
  },
  qrGlyph: {
    fontSize: 18,
  },
  qrLabel: {
    flex: 1,
    fontSize: 15,
    fontWeight: '600',
  },
  chevron: {
    fontSize: 24,
  },
  itemCard: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.sm,
    borderRadius: radius.lg,
    borderWidth: 1,
    minHeight: MIN_TOUCH_TARGET + spacing.md,
  },
  thumb: {
    width: 56,
    height: 56,
    borderRadius: radius.md,
  },
  thumbPlaceholder: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  thumbGlyph: {
    fontSize: 24,
  },
  itemBody: {
    flex: 1,
    gap: 2,
  },
  itemTitleUnnamed: {
    fontStyle: 'italic',
    fontWeight: '600',
  },
  itemTitle: {
    fontSize: 16,
    fontWeight: '600',
  },
  itemMeta: {
    fontSize: 14,
  },
  qtyBadge: {
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    borderRadius: radius.pill,
  },
  qtyText: {
    fontSize: 14,
    fontWeight: '700',
  },
  actionBar: {
    padding: spacing.lg,
    gap: spacing.sm,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  headerButton: {
    minHeight: MIN_TOUCH_TARGET,
    justifyContent: 'center',
    paddingHorizontal: spacing.sm,
  },
});
