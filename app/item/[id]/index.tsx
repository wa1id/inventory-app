import { Alert, Image, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

function DetailRow({ label, value }: { label: string; value: string }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.row, { borderColor: colors.border }]}>
      <Text style={[styles.rowLabel, { color: colors.textMuted }]}>{label}</Text>
      <Text style={[styles.rowValue, { color: colors.text }]}>{value}</Text>
    </View>
  );
}

export default function ItemScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const { colors } = useTheme();

  const {
    data: item,
    loading,
    error,
    reload,
  } = useInventoryQuery(() => repos.items.getById(id), `item:${id}`);

  function confirmDelete() {
    Alert.alert(strings.items.deleteTitle, strings.items.deleteBody, [
      { text: strings.common.cancel, style: 'cancel' },
      {
        text: strings.common.delete,
        style: 'destructive',
        onPress: async () => {
          const containerId = item?.containerId;
          const result = await repos.items.delete(id);
          deleteStoredPhotos(result.orphanedPhotoUris);
          logEvent('item_deleted');
          invalidate();
          router.dismissTo(containerId ? `/container/${containerId}` : '/');
        },
      },
    ]);
  }

  if (loading && !item) {
    return (
      <Screen>
        <LoadingState />
      </Screen>
    );
  }

  if (error || !item) {
    return (
      <Screen>
        <ErrorState message={error ?? 'That item no longer exists.'} onRetry={reload} />
      </Screen>
    );
  }

  const value =
    item.estimatedValue !== null
      ? `${item.estimatedValue.toFixed(2)}${item.currency ? ` ${item.currency}` : ''}`
      : null;

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <Stack.Screen
        options={{
          title: item.name || strings.items.unnamed,
          headerRight: () => (
            <Pressable
              onPress={() => router.push(`/item/${id}/edit`)}
              accessibilityRole="button"
              accessibilityLabel={`Edit ${item.name || strings.items.unnamed}`}
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

      <ScrollView contentContainerStyle={styles.content}>
        {item.photoUri ? (
          <Image
            source={{ uri: item.photoUri }}
            style={styles.photo}
            accessibilityIgnoresInvertColors
            accessibilityLabel={`Photo of ${item.name || strings.items.unnamed}`}
          />
        ) : null}

        <Text
          style={[styles.title, { color: item.name ? colors.text : colors.textMuted }]}
          accessibilityRole="header"
        >
          {item.name || strings.items.unnamed}
        </Text>

        {/* The whole point of the app: where is this thing? (issue #13) */}
        <Pressable
          onPress={() => router.push(`/container/${item.containerId}`)}
          accessibilityRole="button"
          accessibilityLabel={`Stored in ${item.spaceName}, ${
            item.containerName ?? item.containerShortCode
          }. Opens the container.`}
          style={[
            styles.locationCard,
            { backgroundColor: colors.surface, borderColor: colors.border },
          ]}
        >
          <Text style={styles.locationGlyph}>📍</Text>
          <View style={styles.locationBody}>
            <Text style={[styles.locationPath, { color: colors.text }]}>
              {item.spaceName} › {item.containerName ?? item.containerShortCode}
            </Text>
            <Text style={[styles.locationCode, { color: colors.textMuted }]}>
              {item.containerShortCode}
            </Text>
          </View>
          <Text style={[styles.chevron, { color: colors.textMuted }]}>›</Text>
        </Pressable>

        <View
          style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
        >
          <DetailRow label="Quantity" value={String(item.quantity)} />
          {item.category ? <DetailRow label="Category" value={item.category} /> : null}
          {value ? <DetailRow label="Estimated value" value={value} /> : null}
          {item.tags.length > 0 ? <DetailRow label="Tags" value={item.tags.join(', ')} /> : null}
          {item.notes ? <DetailRow label="Notes" value={item.notes} /> : null}
        </View>

        <Button
          label="Delete item"
          variant="danger"
          fullWidth
          onPress={confirmDelete}
          accessibilityHint="Permanently removes this item from your inventory"
        />
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: spacing.lg,
    gap: spacing.lg,
    paddingBottom: spacing.xxl,
  },
  photo: {
    width: '100%',
    height: 260,
    borderRadius: radius.lg,
    resizeMode: 'cover',
  },
  title: {
    fontSize: 24,
    fontWeight: '800',
  },
  locationCard: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.md,
    borderRadius: radius.lg,
    borderWidth: 1,
    minHeight: MIN_TOUCH_TARGET,
  },
  locationGlyph: {
    fontSize: 20,
  },
  locationBody: {
    flex: 1,
    gap: 2,
  },
  locationPath: {
    fontSize: 16,
    fontWeight: '700',
  },
  locationCode: {
    fontSize: 13,
    letterSpacing: 0.5,
  },
  chevron: {
    fontSize: 24,
  },
  card: {
    borderRadius: radius.lg,
    borderWidth: 1,
    paddingHorizontal: spacing.md,
  },
  row: {
    paddingVertical: spacing.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    gap: 2,
  },
  rowLabel: {
    fontSize: 13,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
  },
  rowValue: {
    fontSize: 16,
    lineHeight: 22,
  },
  headerButton: {
    minHeight: MIN_TOUCH_TARGET,
    justifyContent: 'center',
    paddingHorizontal: spacing.sm,
  },
});
