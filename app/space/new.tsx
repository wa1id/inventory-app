import { useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { useRouter } from 'expo-router';

import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { ChoiceRow, ColorRow } from '@/ui/components/PickerRow';
import { Screen } from '@/ui/components/Screen';
import { TextField } from '@/ui/components/TextField';
import { SPACE_COLORS, SPACE_ICONS, spacing } from '@/ui/theme';

export default function NewSpaceScreen() {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();

  const [name, setName] = useState('');
  const [icon, setIcon] = useState<string>(SPACE_ICONS[0]);
  const [color, setColor] = useState<string>(SPACE_COLORS[0]);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function save() {
    if (!name.trim()) {
      setError(strings.spaces.nameRequired);
      return;
    }

    setSaving(true);
    try {
      const space = await repos.spaces.create({ name, icon, color });
      logEvent('space_created');
      invalidate();
      // Replace so Back from the space screen returns to the dashboard rather
      // than reopening this form.
      router.replace(`/space/${space.id}`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The space could not be saved.');
      setSaving(false);
    }
  }

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <TextField
          label={strings.spaces.nameLabel}
          placeholder={strings.spaces.namePlaceholder}
          value={name}
          onChangeText={(value) => {
            setName(value);
            if (error) setError(null);
          }}
          error={error}
          required
          autoFocus
          returnKeyType="done"
          onSubmitEditing={save}
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
  actions: {
    gap: spacing.sm,
    marginTop: spacing.md,
  },
});
