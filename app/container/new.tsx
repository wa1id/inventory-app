import { useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { CONTAINER_VISUAL_TYPES, type ContainerVisualType } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { TileRow } from '@/ui/components/PickerRow';
import { Screen } from '@/ui/components/Screen';
import { TextField } from '@/ui/components/TextField';
import { CONTAINER_ICONS, spacing, useTheme } from '@/ui/theme';

const TYPE_OPTIONS = CONTAINER_VISUAL_TYPES.map((value) => ({
  value,
  glyph: CONTAINER_ICONS[value] ?? '📦',
  label: strings.containers.typeNames[value] ?? value,
}));

export default function NewContainerScreen() {
  const { spaceId } = useLocalSearchParams<{ spaceId: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const { colors } = useTheme();

  const [name, setName] = useState('');
  const [visualType, setVisualType] = useState<ContainerVisualType>('box');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const { data: space } = useInventoryQuery(
    () => repos.spaces.getById(spaceId),
    `space:${spaceId}`,
  );

  async function save() {
    setSaving(true);
    try {
      const container = await repos.containers.create({ spaceId, name, visualType });
      logEvent('container_created');
      invalidate();
      router.replace(`/container/${container.id}`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The container could not be saved.');
      setSaving(false);
    }
  }

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        {space ? (
          <Text style={[styles.context, { color: colors.textMuted }]}>
            Adding to {space.icon} {space.name}
          </Text>
        ) : null}

        <TileRow
          label={strings.containers.typeLabel}
          options={TYPE_OPTIONS}
          value={visualType}
          onChange={setVisualType}
        />

        <TextField
          label={strings.containers.nameLabel}
          placeholder={strings.containers.namePlaceholder}
          value={name}
          onChangeText={setName}
          error={error}
          hint="Leave empty and we'll label it with its code."
          returnKeyType="done"
          onSubmitEditing={save}
        />

        <View style={styles.actions}>
          <Button
            label={strings.containers.createAction}
            onPress={save}
            loading={saving}
            fullWidth
            testID="container-create"
          />
          <Button
            label={strings.common.cancel}
            onPress={() => router.back()}
            variant="ghost"
            fullWidth
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
  context: {
    fontSize: 15,
  },
  actions: {
    gap: spacing.sm,
    marginTop: spacing.md,
  },
});
