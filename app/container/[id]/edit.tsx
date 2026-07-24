import { useState } from 'react';
import { Alert, ScrollView, StyleSheet, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { CONTAINER_VISUAL_TYPES, type ContainerVisualType } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { ChoiceRow } from '@/ui/components/PickerRow';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { TextField } from '@/ui/components/TextField';
import { CONTAINER_ICONS, spacing } from '@/ui/theme';

const TYPE_OPTIONS = CONTAINER_VISUAL_TYPES.map((value) => ({
  value,
  label: `${CONTAINER_ICONS[value] ?? ''} ${value}`.trim(),
}));

export default function EditContainerScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();

  const container = useInventoryQuery(() => repos.containers.getById(id), `container:${id}`);
  const spaces = useInventoryQuery(() => repos.spaces.listWithCounts(), 'spaces');

  const [name, setName] = useState('');
  const [visualType, setVisualType] = useState<ContainerVisualType>('box');
  const [spaceId, setSpaceId] = useState<string>('');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  // Seed the form from the loaded record exactly once, during render rather
  // than in an effect: React documents this as the way to adjust state when
  // inputs change, and it avoids the extra render pass an effect would cost.
  const [seededId, setSeededId] = useState<string | null>(null);
  if (container.data && seededId !== container.data.id) {
    setSeededId(container.data.id);
    setName(container.data.name ?? '');
    setVisualType(container.data.visualType);
    setSpaceId(container.data.spaceId);
  }

  async function save() {
    setSaving(true);
    try {
      await repos.containers.update(id, { name, visualType, spaceId });
      logEvent('container_updated');
      invalidate();
      router.back();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The container could not be saved.');
      setSaving(false);
    }
  }

  async function confirmDelete() {
    const impact = await repos.containers.deletionImpact(id);
    const detail =
      impact.itemCount === 0
        ? `This container is empty.${impact.hasQrBinding ? ' Its QR label will be unlinked.' : ''}`
        : `This also deletes ${impact.itemCount} item${impact.itemCount === 1 ? '' : 's'}${
            impact.hasQrBinding ? ' and unlinks its QR label' : ''
          }. This cannot be undone.`;

    Alert.alert(strings.containers.deleteTitle, detail, [
      { text: strings.common.cancel, style: 'cancel' },
      {
        text: strings.common.delete,
        style: 'destructive',
        onPress: async () => {
          const spaceIdBefore = container.data?.spaceId;
          const result = await repos.containers.delete(id);
          deleteStoredPhotos(result.orphanedPhotoUris);
          logEvent('container_deleted', { itemCount: impact.itemCount });
          invalidate();
          router.dismissTo(spaceIdBefore ? `/space/${spaceIdBefore}` : '/');
        },
      },
    ]);
  }

  if (container.loading && !container.data) {
    return (
      <Screen>
        <LoadingState />
      </Screen>
    );
  }

  if (container.error || !container.data) {
    return (
      <Screen>
        <ErrorState
          message={container.error ?? 'That container no longer exists.'}
          onRetry={container.reload}
        />
      </Screen>
    );
  }

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <TextField
          label={strings.containers.nameLabel}
          placeholder={container.data.shortCode}
          value={name}
          onChangeText={setName}
          error={error}
        />

        <ChoiceRow
          label={strings.containers.typeLabel}
          options={TYPE_OPTIONS}
          value={visualType}
          onChange={setVisualType}
        />

        <ChoiceRow
          label={strings.containers.spaceLabel}
          options={(spaces.data ?? []).map((space) => ({
            value: space.id,
            label: `${space.icon} ${space.name}`,
          }))}
          value={spaceId}
          onChange={setSpaceId}
        />

        <View style={styles.actions}>
          <Button label={strings.common.save} onPress={save} loading={saving} fullWidth />
          <Button
            label="Delete container"
            onPress={confirmDelete}
            variant="danger"
            fullWidth
            accessibilityHint="Deletes this container and the items inside it"
          />
        </View>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: spacing.lg,
    gap: spacing.xl,
  },
  actions: {
    gap: spacing.sm,
    marginTop: spacing.md,
  },
});
