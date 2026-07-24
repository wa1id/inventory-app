import { useState } from 'react';
import { Alert, ScrollView, StyleSheet, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { ChoiceRow, ColorRow } from '@/ui/components/PickerRow';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { TextField } from '@/ui/components/TextField';
import { SPACE_COLORS, SPACE_ICONS, spacing } from '@/ui/theme';

export default function EditSpaceScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();

  const {
    data: space,
    loading,
    error,
    reload,
  } = useInventoryQuery(() => repos.spaces.getById(id), `space:${id}`);

  const [name, setName] = useState('');
  const [icon, setIcon] = useState<string>(SPACE_ICONS[0]);
  const [color, setColor] = useState<string>(SPACE_COLORS[0]);
  const [validation, setValidation] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  // Seed the form from the loaded record exactly once, during render rather
  // than in an effect: React documents this as the way to adjust state when
  // inputs change, and it avoids the extra render pass an effect would cost.
  const [seededId, setSeededId] = useState<string | null>(null);
  if (space && seededId !== space.id) {
    setSeededId(space.id);
    setName(space.name);
    setIcon(space.icon);
    setColor(space.color);
  }

  async function save() {
    if (!name.trim()) {
      setValidation(strings.spaces.nameRequired);
      return;
    }

    setSaving(true);
    try {
      await repos.spaces.update(id, { name, icon, color });
      logEvent('space_updated');
      invalidate();
      router.back();
    } catch (cause) {
      setValidation(cause instanceof Error ? cause.message : 'The space could not be saved.');
      setSaving(false);
    }
  }

  /**
   * Deleting a space takes its containers and items with it, so the confirm
   * dialog spells out exactly what is lost (issue #4).
   */
  async function confirmDelete() {
    const impact = await repos.spaces.deletionImpact(id);
    const detail =
      impact.containerCount === 0 && impact.itemCount === 0
        ? 'This space is empty.'
        : `This also deletes ${impact.containerCount} container${
            impact.containerCount === 1 ? '' : 's'
          } and ${impact.itemCount} item${impact.itemCount === 1 ? '' : 's'}${
            impact.qrBindingCount > 0
              ? `, and unlinks ${impact.qrBindingCount} QR label${
                  impact.qrBindingCount === 1 ? '' : 's'
                }`
              : ''
          }. This cannot be undone.`;

    Alert.alert(strings.spaces.deleteTitle, detail, [
      { text: strings.common.cancel, style: 'cancel' },
      {
        text: strings.common.delete,
        style: 'destructive',
        onPress: async () => {
          const result = await repos.spaces.delete(id);
          deleteStoredPhotos(result.orphanedPhotoUris);
          logEvent('space_deleted', {
            containerCount: impact.containerCount,
            itemCount: impact.itemCount,
          });
          invalidate();
          router.dismissTo('/');
        },
      },
    ]);
  }

  if (loading && !space) {
    return (
      <Screen>
        <LoadingState />
      </Screen>
    );
  }

  if (error || !space) {
    return (
      <Screen>
        <ErrorState message={error ?? 'That space no longer exists.'} onRetry={reload} />
      </Screen>
    );
  }

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <TextField
          label={strings.spaces.nameLabel}
          value={name}
          onChangeText={(value) => {
            setName(value);
            if (validation) setValidation(null);
          }}
          error={validation}
          required
        />

        <ChoiceRow
          label={strings.spaces.iconLabel}
          options={SPACE_ICONS.map((value) => ({ value, label: value }))}
          value={icon}
          onChange={setIcon}
        />

        <ColorRow
          label={strings.spaces.colorLabel}
          colors={SPACE_COLORS}
          value={color}
          onChange={setColor}
        />

        <View style={styles.actions}>
          <Button label={strings.common.save} onPress={save} loading={saving} fullWidth />
          <Button
            label="Delete space"
            onPress={confirmDelete}
            variant="danger"
            fullWidth
            accessibilityHint="Deletes this space and everything inside it"
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
