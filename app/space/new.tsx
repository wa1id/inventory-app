import { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';

import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { ChoiceRow, ColorRow } from '@/ui/components/PickerRow';
import { Screen } from '@/ui/components/Screen';
import { TextField } from '@/ui/components/TextField';
import {
  MIN_TOUCH_TARGET,
  radius,
  SPACE_COLORS,
  SPACE_ICONS,
  SPACE_PRESETS,
  spacing,
  useTheme,
} from '@/ui/theme';

export default function NewSpaceScreen() {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const { colors } = useTheme();

  const [name, setName] = useState('');
  const [icon, setIcon] = useState<string>(SPACE_ICONS[0]);
  const [color, setColor] = useState<string>(SPACE_COLORS[0]);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function create(space: { name: string; icon: string; color: string }) {
    // Guards the preset tiles as well as the button: they all write, and a
    // double tap would otherwise create two spaces.
    if (saving) return;

    setSaving(true);
    try {
      const created = await repos.spaces.create(space);
      logEvent('space_created');
      invalidate();
      // Replace so Back from the space screen returns to the dashboard rather
      // than reopening this form.
      router.replace(`/space/${created.id}`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The space could not be saved.');
      setSaving(false);
    }
  }

  function saveCustom() {
    if (!name.trim()) {
      setError(strings.spaces.nameRequired);
      return;
    }
    void create({ name: name.trim(), icon, color });
  }

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <View style={styles.section}>
          <Text style={[styles.sectionLabel, { color: colors.textMuted }]}>
            {strings.spaces.quickAddLabel}
          </Text>
          <View style={styles.presets}>
            {SPACE_PRESETS.map((preset) => (
              <Pressable
                key={preset.name}
                onPress={() => void create(preset)}
                disabled={saving}
                accessibilityRole="button"
                accessibilityLabel={preset.name}
                accessibilityHint={strings.spaces.presetHint(preset.name)}
                testID={`space-preset-${preset.name.toLowerCase()}`}
                style={({ pressed }) => [
                  styles.preset,
                  {
                    backgroundColor: colors.surfaceAlt,
                    borderColor: colors.border,
                    opacity: saving ? 0.5 : pressed ? 0.85 : 1,
                  },
                ]}
              >
                <Text
                  style={styles.presetIcon}
                  accessibilityElementsHidden
                  importantForAccessibility="no"
                >
                  {preset.icon}
                </Text>
                <Text style={[styles.presetName, { color: colors.text }]} numberOfLines={1}>
                  {preset.name}
                </Text>
              </Pressable>
            ))}
          </View>
        </View>

        <View style={[styles.divider, { backgroundColor: colors.border }]} />

        <View style={styles.section}>
          <Text style={[styles.sectionLabel, { color: colors.textMuted }]}>
            {strings.spaces.customLabel}
          </Text>

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
            returnKeyType="done"
            onSubmitEditing={saveCustom}
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
        </View>

        <View style={styles.actions}>
          <Button
            label={strings.spaces.customAction}
            onPress={saveCustom}
            loading={saving}
            disabled={!name.trim()}
            fullWidth
            testID="space-create-custom"
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
    gap: spacing.lg,
  },
  section: {
    gap: spacing.md,
  },
  sectionLabel: {
    fontSize: 13,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
  },
  presets: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.sm,
  },
  preset: {
    flexGrow: 1,
    flexBasis: '22%',
    minHeight: MIN_TOUCH_TARGET + spacing.xl,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.xs,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.sm,
    borderRadius: radius.md,
    borderWidth: 1,
  },
  presetIcon: {
    fontSize: 28,
  },
  presetName: {
    fontSize: 13,
    fontWeight: '600',
  },
  divider: {
    height: StyleSheet.hairlineWidth,
  },
  actions: {
    gap: spacing.sm,
  },
});
