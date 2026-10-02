import { FlatList, Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { ItemWithContext } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { radius, spacing, useTheme } from '@/ui/theme';

function UnsortedCard({ item, onPress }: { item: ItemWithContext; onPress: () => void }) {
  const { colors } = useTheme();

  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${item.name || strings.items.unnamed}. ${strings.dropZone.fileAction}`}
      style={({ pressed }) => [
        styles.card,
        { backgroundColor: colors.surface, borderColor: colors.border, opacity: pressed ? 0.8 : 1 },
      ]}
    >
      {item.photoUri ? (
        <Image
          source={{ uri: item.photoThumbUri ?? item.photoUri }}
          style={styles.thumb}
          accessibilityIgnoresInvertColors
        />
      ) : (
        <View style={[styles.thumb, styles.thumbEmpty, { backgroundColor: colors.surfaceAlt }]}>
          <Text style={styles.thumbGlyph}>🧾</Text>
        </View>
      )}

      <View style={styles.cardBody}>
        <Text
          style={[
            styles.cardTitle,
            { color: item.name ? colors.text : colors.textMuted },
            !item.name && styles.cardTitleUnnamed,
          ]}
          numberOfLines={2}
        >
          {item.name || strings.items.unnamed}
        </Text>
        <Text style={[styles.cardAction, { color: colors.primary }]}>
          {strings.dropZone.fileAction} ›
        </Text>
      </View>
    </Pressable>
  );
}

/**
 * The holding area for things photographed before they had a home (issue #26).
 *
 * Capturing and filing are separate jobs done at different moments — usually
 * standing in a room versus sitting down later — so this screen exists to make
 * the second one cheap rather than to make the first one wait for it.
 */
export default function DropZoneScreen() {
  const repos = useRepositories();
  const router = useRouter();
  const { colors } = useTheme();

  const { data, loading, error, reload } = useInventoryQuery(
    () => repos.items.listUnsorted(),
    'drop-zone',
  );

  if (loading && data === null) {
    return (
      <Screen edges={['left', 'right', 'bottom']}>
        <LoadingState />
      </Screen>
    );
  }

  if (error) {
    return (
      <Screen edges={['left', 'right', 'bottom']}>
        <ErrorState message={error} onRetry={reload} />
      </Screen>
    );
  }

  const items = data ?? [];

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <FlatList
        data={items}
        keyExtractor={(item) => item.id}
        contentContainerStyle={[styles.list, items.length === 0 && styles.listEmpty]}
        renderItem={({ item }) => (
          <UnsortedCard item={item} onPress={() => router.push(`/item/${item.id}/move`)} />
        )}
        ListHeaderComponent={
          items.length > 0 ? (
            <Text style={[styles.intro, { color: colors.textMuted }]}>
              {strings.dropZone.intro}
            </Text>
          ) : null
        }
        ListEmptyComponent={
          <EmptyState
            icon="📥"
            title={strings.dropZone.empty.title}
            body={strings.dropZone.empty.body}
            actionLabel={strings.dropZone.capture}
            onAction={() => router.push(`/capture?containerId=${DROP_ZONE_CONTAINER_ID}&mode=fast`)}
            testID="drop-zone-empty"
          />
        }
      />

      {items.length > 0 ? (
        <View
          style={[
            styles.actionBar,
            { backgroundColor: colors.background, borderTopColor: colors.border },
          ]}
        >
          <Button
            label={strings.dropZone.capture}
            icon="📸"
            fullWidth
            onPress={() => router.push(`/capture?containerId=${DROP_ZONE_CONTAINER_ID}&mode=fast`)}
            testID="drop-zone-capture"
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
  intro: {
    fontSize: 14,
    lineHeight: 20,
    marginBottom: spacing.xs,
  },
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.sm,
    borderRadius: radius.lg,
    borderWidth: 1,
  },
  thumb: {
    width: 64,
    height: 64,
    borderRadius: radius.md,
  },
  thumbEmpty: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  thumbGlyph: {
    fontSize: 24,
  },
  cardBody: {
    flex: 1,
    gap: spacing.xs,
  },
  cardTitle: {
    fontSize: 17,
    fontWeight: '700',
  },
  cardTitleUnnamed: {
    fontStyle: 'italic',
    fontWeight: '600',
  },
  cardAction: {
    fontSize: 15,
    fontWeight: '600',
  },
  actionBar: {
    padding: spacing.lg,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
});
