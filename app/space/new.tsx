import { useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, View, type TextInput } from 'react-native';
import { useRouter } from 'expo-router';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { useDirtyGuard } from '@/hooks/useDirtyGuard';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { PressedOverlay, rippleFor, useFocusRing } from '@/ui/components/PressFeedback';
import { Section } from '@/ui/components/Sheet';
import { SpaceTile } from '@/ui/components/SpaceTile';
import { haptics } from '@/ui/haptics';
import { delay } from '@/ui/motion';
import { FormLayout, SaveNotice } from '@/ui/spaces/FormLayout';
import { SpaceFields } from '@/ui/spaces/SpaceFields';
import {
  isNameTaken,
  spaceValuesChanged,
  takenSpaceNames,
  type SpaceValues,
} from '@/ui/spaces/spaceSetup';
import { SPACE_COLORS, SPACE_ICONS, SPACE_PRESETS, radius, space, useTheme } from '@/ui/theme';

type Preset = (typeof SPACE_PRESETS)[number];

const DEFAULTS: SpaceValues = { name: '', icon: SPACE_ICONS[0], color: SPACE_COLORS[0] };

/** A new space holds nothing yet; the preview says so. */
const EMPTY_COUNTS = { containers: 0, items: 0 };

interface PresetTileProps {
  preset: Preset;
  /** A space with this name exists already. */
  taken: boolean;
  /** This preset is being created. */
  busy: boolean;
  /** Another save is under way. */
  disabled: boolean;
  onPress: () => void;
}

/**
 * One quick-add preset. A tap creates the space at once, zero typing being
 * the point of a preset; one that already exists says so and stays put
 * rather than making a second Garage (entities §1).
 */
function PresetTile({ preset, taken, busy, disabled, onPress }: PresetTileProps) {
  const { colors } = useTheme();
  const { stacked } = useLayoutScale();
  const focus = useFocusRing();
  const showSpinner = useDelayedFlag(busy, delay.spinner);

  return (
    <Pressable
      onPress={onPress}
      onFocus={focus.onFocus}
      onBlur={focus.onBlur}
      disabled={taken || disabled}
      accessibilityRole="button"
      accessibilityLabel={
        taken
          ? strings.spaceForm.presetAddedA11y(preset.name)
          : strings.spaceForm.presetA11y(preset.name)
      }
      accessibilityState={{ disabled: taken || disabled, busy }}
      testID={`space-preset-${preset.name.toLowerCase()}`}
      android_ripple={rippleFor(colors)}
      style={[
        styles.preset,
        { flexBasis: stacked ? '100%' : '40%' },
        { backgroundColor: colors.sheet, borderColor: colors.rule },
        // A taken preset stays readable; only a wait dims the others.
        disabled && !busy && !taken ? styles.dimmed : null,
        focus.ringStyle,
      ]}
    >
      {({ pressed }) => (
        <>
          <PressedOverlay pressed={pressed} radius={radius.card} />
          <SpaceTile icon={preset.icon} color={preset.color} size={48} />
          <View style={styles.presetText}>
            <AppText variant="name">{preset.name}</AppText>
            {taken ? (
              <AppText variant="caption" tone="graphite">
                {strings.spaceForm.alreadyAdded}
              </AppText>
            ) : null}
          </View>
          {showSpinner ? <ActivityIndicator color={colors.graphite} /> : null}
        </>
      )}
    </Pressable>
  );
}

/**
 * New space: a preset in one tap, or a name, icon and colour of your own.
 * Both end on the new space, replacing this sheet, because making a place
 * means you want to fill it (spec §2.5 rule 5).
 */
export default function NewSpaceScreen() {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const { colors } = useTheme();
  const nameRef = useRef<TextInput>(null);

  const [values, setValues] = useState<SpaceValues>(DEFAULTS);
  const [nameError, setNameError] = useState<string | null>(null);
  const [failure, setFailure] = useState<{ cause: unknown } | null>(null);
  /** What is being created: a preset's name, or `custom` for the form. */
  const [saving, setSaving] = useState<string | null>(null);
  const savingRef = useRef(false);

  // Existing names, so presets already added are shown as such. While this
  // loads (or if it fails) every preset stays available.
  const existing = useInventoryQuery(() => repos.spaces.listWithCounts(), 'spaces');
  const taken = useMemo(() => takenSpaceNames(existing.data ?? []), [existing.data]);

  useDirtyGuard(spaceValuesChanged(values, DEFAULTS), { saving: saving !== null });

  async function create(input: SpaceValues, source: string) {
    // One guard for the presets, the button and the return key: each of them
    // writes, and a double tap would otherwise make two spaces. A ref, so two
    // taps in the same frame cannot both pass it.
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(source);
    setFailure(null);
    try {
      const created = await repos.spaces.create({
        name: input.name.trim(),
        icon: input.icon,
        color: input.color,
      });
      logEvent('space_created');
      invalidate();
      haptics.success();
      // Replace, so Back from the new space returns to where this started.
      router.replace(`/space/${created.id}`);
    } catch (cause) {
      savingRef.current = false;
      setSaving(null);
      setFailure({ cause });
      haptics.error();
    }
  }

  function createCustom() {
    if (!values.name.trim()) {
      setNameError(strings.spaceForm.nameRequired);
      nameRef.current?.focus();
      return;
    }
    void create(values, 'custom');
  }

  function change(next: SpaceValues) {
    if (next.name !== values.name) setNameError(null);
    setFailure(null);
    setValues(next);
  }

  return (
    <FormLayout
      notice={failure ? <SaveNotice cause={failure.cause} subject="space" /> : null}
      bottomBar={
        <BottomBar>
          <Button
            label={strings.spaceForm.create}
            onPress={createCustom}
            loading={saving === 'custom'}
            disabled={saving !== null && saving !== 'custom'}
            fullWidth
            testID="space-create-custom"
          />
        </BottomBar>
      }
    >
      <Section title={strings.spaceForm.quickAdd} first>
        <View style={styles.presets}>
          {SPACE_PRESETS.map((preset) => (
            <PresetTile
              key={preset.name}
              preset={preset}
              taken={isNameTaken(preset.name, taken)}
              busy={saving === preset.name}
              disabled={saving !== null}
              onPress={() => void create({ ...preset }, preset.name)}
            />
          ))}
        </View>
      </Section>

      <View style={[styles.rule, { backgroundColor: colors.rule }]} />

      <Section title={strings.spaceForm.yourOwn} first>
        <SpaceFields
          values={values}
          onChange={change}
          nameError={nameError}
          onSubmit={createCustom}
          nameRef={nameRef}
          previewCounts={EMPTY_COUNTS}
        />
      </Section>
    </FormLayout>
  );
}

const styles = StyleSheet.create({
  presets: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: space.sm,
  },
  preset: {
    flexGrow: 1,
    minHeight: 64,
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
    paddingVertical: space.sm,
    paddingHorizontal: space.md,
    borderWidth: 1,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  dimmed: {
    opacity: 0.45,
  },
  presetText: {
    flex: 1,
    gap: space.xxs,
  },
  rule: {
    height: 1,
  },
});
