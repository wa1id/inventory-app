import { Alert, FlatList, Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { ItemWithContext } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { sessionItems, summarizeSession } from '@/services/capture/fastReview';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { LoadingState, Screen } from '@/ui/components/Screen';
import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

/**
 * Batch review after a fast-capture session (the reference app's "fast
 * review" step): every shot from the session in shutter order, names filling
 * in as recognition lands, with rename and delete one tap away before the
 * batch is accepted.
 *
 * The screen holds no session state of its own. Items were already written by
 * the capture pipeline; this is a filtered read that re-runs on every write,
 * which is also what makes late recognition results appear live.
 */
export default function FastReviewScreen() {
  const { containerId, since, expected } = useLocalSearchParams<{
    containerId: string;
    since: string;
    expected: string;
  }>();
  const router = useRouter();
  const { colors } = useTheme();
  const repos = useRepositories();
  const { invalidate } = useDatabase();

  const sinceMs = Number(since);
  const expectedCount = Number(expected) || 0;

  const items = useInventoryQuery(
    async () => sessionItems(await repos.items.listByContainer(containerId), sinceMs),
    `fast-review:${containerId}:${since}`,
  );

  const list = items.data ?? [];
  const summary = summarizeSession(list, expectedCount);

  const destination =
    containerId === DROP_ZONE_CONTAINER_ID ? '/drop-zone' : `/container/${containerId}`;

  function keepAll() {
    logEvent('fast_review_done', { kept: summary.saved, unnamed: summary.unnamed });
    router.replace(destination);
  }

  function keepShooting() {
    const params = new URLSearchParams({ containerId, mode: 'fast', since });
    router.replace(`/capture?${params.toString()}`);
  }

  function confirmRemove(item: ItemWithContext) {
    Alert.alert(strings.items.deleteTitle, strings.items.deleteBody, [
      { text: strings.common.cancel, style: 'cancel' },
      {
        text: strings.common.delete,
        style: 'destructive',
        onPress: async () => {
          const result = await repos.items.delete(item.id);
          deleteStoredPhotos(result.orphanedPhotoUris);
          logEvent('item_deleted');
          invalidate();
        },
      },
    ]);
  }

  if (items.loading && !items.data) {
    return (
      <Screen edges={['left', 'right']}>
        <LoadingState />
      </Screen>
    );
  }

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <FlatList
        data={list}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.list}
        ListHeaderComponent={
          <View style={styles.summary} accessibilityLiveRegion="polite">
            <Text style={[styles.summaryTitle, { color: colors.text }]} accessibilityRole="header">
              {strings.capture.review.summary(summary.saved)}
            </Text>
            {summary.pending > 0 ? (
              <Text style={[styles.summaryMeta, { color: colors.textMuted }]}>
                {strings.capture.review.pending(summary.pending)}
              </Text>
            ) : summary.unnamed > 0 ? (
              <Text style={[styles.summaryMeta, { color: colors.textMuted }]}>
                {strings.capture.review.toName(summary.unnamed)}
              </Text>
            ) : null}
          </View>
        }
        renderItem={({ item }) => (
          <View
            style={[styles.row, { backgroundColor: colors.surface, borderColor: colors.border }]}
          >
            <Pressable
              onPress={() => router.push(`/item/${item.id}/edit`)}
              accessibilityRole="button"
              accessibilityLabel={item.name || strings.items.unnamed}
              accessibilityHint="Opens this item to name or edit it"
              style={({ pressed }) => [styles.rowBody, { opacity: pressed ? 0.8 : 1 }]}
            >
              {item.photoUri ? (
                <Image
                  source={{ uri: item.photoUri }}
                  style={styles.thumb}
                  accessibilityIgnoresInvertColors
                />
              ) : (
                <View
                  style={[
                    styles.thumb,
                    styles.thumbPlaceholder,
                    { backgroundColor: colors.surfaceAlt },
                  ]}
                >
                  <Text style={styles.thumbGlyph}>🧾</Text>
                </View>
              )}
              <View style={styles.rowText}>
                <Text
                  style={[
                    styles.rowTitle,
                    { color: item.name ? colors.text : colors.textMuted },
                    !item.name && styles.rowTitleUnnamed,
                  ]}
                  numberOfLines={2}
                >
                  {item.name || strings.items.unnamed}
                </Text>
                {item.category ? (
                  <Text style={[styles.rowMeta, { color: colors.textMuted }]} numberOfLines={1}>
                    {item.category}
                  </Text>
                ) : null}
              </View>
            </Pressable>
            <Pressable
              onPress={() => confirmRemove(item)}
              accessibilityRole="button"
              accessibilityLabel={`Delete ${item.name || strings.items.unnamed}`}
              hitSlop={spacing.sm}
              style={styles.deleteButton}
            >
              <Text style={styles.deleteGlyph}>🗑️</Text>
            </Pressable>
          </View>
        )}
        ListEmptyComponent={
          summary.pending > 0 ? (
            <LoadingState label={strings.capture.review.pending(summary.pending)} />
          ) : (
            <EmptyState
              icon="📸"
              title={strings.capture.review.empty.title}
              body={strings.capture.review.empty.body}
            />
          )
        }
      />

      <View
        style={[
          styles.actionBar,
          { backgroundColor: colors.background, borderTopColor: colors.border },
        ]}
      >
        <Button
          label={strings.capture.review.keepAll(summary.saved)}
          fullWidth
          onPress={keepAll}
          testID="fast-review-done"
        />
        <Button
          label={strings.capture.review.keepShooting}
          variant="secondary"
          fullWidth
          onPress={keepShooting}
          testID="fast-review-more"
        />
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  summary: {
    gap: spacing.xs,
    marginBottom: spacing.xs,
  },
  summaryTitle: {
    fontSize: 20,
    fontWeight: '700',
  },
  summaryMeta: {
    fontSize: 15,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    borderRadius: radius.lg,
    borderWidth: 1,
    paddingRight: spacing.xs,
  },
  rowBody: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.sm,
    minHeight: MIN_TOUCH_TARGET + spacing.md,
  },
  rowText: {
    flex: 1,
    gap: 2,
  },
  rowTitle: {
    fontSize: 16,
    fontWeight: '600',
  },
  rowTitleUnnamed: {
    fontStyle: 'italic',
  },
  rowMeta: {
    fontSize: 14,
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
  deleteButton: {
    width: MIN_TOUCH_TARGET,
    height: MIN_TOUCH_TARGET,
    alignItems: 'center',
    justifyContent: 'center',
  },
  deleteGlyph: {
    fontSize: 18,
  },
  actionBar: {
    padding: spacing.lg,
    gap: spacing.sm,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
});
