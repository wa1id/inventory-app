import { useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  View,
  useWindowDimensions,
  type TextInput,
} from 'react-native';
import { useLocalSearchParams, useNavigation, useRouter } from 'expo-router';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { useDirtyGuard } from '@/hooks/useDirtyGuard';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { PressedOverlay, rippleFor, useFocusRing } from '@/ui/components/PressFeedback';
import { SpaceTile } from '@/ui/components/SpaceTile';
import { isOffline } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { delay } from '@/ui/motion';
import type { NewSpaceResult } from '@/ui/navigation';
import { abandonResult, deliverResult } from '@/ui/routeResult';
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

/**
 * Two presets to a row from a 390 pt phone at standard text size, the
 * narrowest where "Already added" (88 pt, the widest label) fits beside the
 * tile. At 360 pt half a row left 74, so it wrapped and "Wardrobe" broke
 * mid-word; narrower, or with larger text, each preset takes a whole row.
 */
const TWO_UP_WIDTH = 390;

function usePresetsTwoUp(): boolean {
  const { width, fontScale } = useWindowDimensions();
  const { stacked } = useLayoutScale();
  // Text smaller than standard does not lower the bar.
  return !stacked && width >= TWO_UP_WIDTH * Math.max(fontScale, 1);
}

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
 * rather than making a second Garage.
 */
function PresetTile({ preset, taken, busy, disabled, onPress }: PresetTileProps) {
  const { colors } = useTheme();
  const twoUp = usePresetsTwoUp();
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
        { flexBasis: twoUp ? '40%' : '100%' },
        // Only a free preset is a raised tile. A taken one stays readable but
        // lies flat on the plaster, so it does not look like it can be tapped.
        { backgroundColor: taken ? 'transparent' : colors.sheet, borderColor: colors.rule },
        // Only a wait dims the others.
        disabled && !busy && !taken ? styles.dimmed : null,
        focus.ringStyle,
      ]}
    >
      {({ pressed }) => (
        <>
          <PressedOverlay pressed={pressed} radius={radius.card} />
          <SpaceTile
            icon={preset.icon}
            color={preset.color}
            size={48}
            surface={taken ? 'plaster' : 'sheet'}
          />
          <View style={styles.presetText}>
            <AppText variant="name" tone={taken ? 'graphite' : 'ink'}>
              {preset.name}
            </AppText>
            {/* No check glyph: beside it "Already added" wraps in a half-width tile. */}
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
 * means you want to fill it. Opened with `request` (the
 * place picker, which has no space to offer a container in), the sheet hands
 * the new space back and closes instead, so the pick carries on.
 */
export default function NewSpaceScreen() {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const navigation = useNavigation();
  const toast = useToast();
  const { request } = useLocalSearchParams<{ request?: string }>();
  const { colors } = useTheme();
  const nameRef = useRef<TextInput>(null);

  // Closed without a space: whoever asked hears nothing came of it.
  useEffect(() => () => abandonResult(request), [request]);

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
    const name = input.name.trim();
    try {
      const created = await repos.spaces.create({ name, icon: input.icon, color: input.color });
      logEvent('space_created');
      invalidate();
      haptics.success();
      if (!navigation.isFocused()) {
        // The header Cancel closed the sheet mid-save (swipe-down and Android
        // back wait for it). Navigating now would replace or pop whatever is
        // in front, the tab shell included, and a picker that was waiting
        // would carry on with a sheet the person closed: the unmount tells it
        // nothing came of it. The space is made, and the list refreshes.
        toast.show({ message: strings.spaceForm.created(created.name) });
        return;
      }
      if (deliverResult<NewSpaceResult>(request, { spaceId: created.id, name: created.name })) {
        router.back();
      } else {
        // Replace, so Back from the new space returns to where this started.
        router.replace(`/space/${created.id}`);
      }
    } catch (cause) {
      savingRef.current = false;
      setSaving(null);
      haptics.error();
      // Normally the banner; a sheet closed under the save says it in a toast.
      if (navigation.isFocused()) {
        setFailure({ cause });
      } else {
        toast.show({
          tone: 'error',
          message: strings.spaceForm.notCreated(name, isOffline(cause)),
        });
      }
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
      {/* Headings, not section titles: the two ways in clearly outrank the field labels. */}
      <View style={styles.group}>
        <AppText variant="heading">{strings.spaceForm.quickAdd}</AppText>
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
      </View>

      <View style={[styles.rule, { backgroundColor: colors.rule }]} />

      <View style={styles.group}>
        <AppText variant="heading">{strings.spaceForm.yourOwn}</AppText>
        <SpaceFields
          values={values}
          onChange={change}
          nameError={nameError}
          onSubmit={createCustom}
          nameRef={nameRef}
          // A new space has nothing to count yet.
          previewMeta={strings.spaceForm.previewNew}
        />
      </View>
    </FormLayout>
  );
}

const styles = StyleSheet.create({
  group: {
    gap: space.md,
  },
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
