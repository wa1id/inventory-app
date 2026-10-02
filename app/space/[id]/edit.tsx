import { useRef, useState } from 'react';
import { StyleSheet, View, type TextInput } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { DROP_ZONE_SPACE_ID } from '@/db/constants';
import type { Space } from '@/db/types';
import { useDirtyGuard } from '@/hooks/useDirtyGuard';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { ErrorState } from '@/ui/components/ErrorState';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { Skeleton } from '@/ui/components/Skeleton';
import { confirm } from '@/ui/confirm';
import { haptics } from '@/ui/haptics';
import { goToTab } from '@/ui/navigation';
import { DropZoneLocked, FormLayout, SaveNotice } from '@/ui/spaces/FormLayout';
import { SpaceFields } from '@/ui/spaces/SpaceFields';
import {
  isOffline,
  labelsInSpace,
  spaceDeleteBody,
  spaceValuesChanged,
  type SpaceValues,
} from '@/ui/spaces/spaceSetup';
import { GUTTER, space, useTheme } from '@/ui/theme';

export default function EditSpaceScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  if (id === DROP_ZONE_SPACE_ID) return <DropZoneLocked />;
  return <EditSpace id={id} />;
}

/**
 * Rename, re-icon or recolour a space, or delete it with everything in it.
 *
 * Save is the primary action in the bottom bar; Delete is quiet red text at
 * the end of the form, behind a confirm that spells out what goes with it.
 * They used to be equal-weight neighbours (entities §16.E). The sheet's
 * Cancel comes from the root layout.
 */
function EditSpace({ id }: { id: string }) {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const toast = useToast();
  const { colors } = useTheme();
  const nameRef = useRef<TextInput>(null);

  const spaceQuery = useInventoryQuery(() => repos.spaces.getById(id), `space:${id}`);
  // Only for the preview row's counts; `getById` has none.
  const countsQuery = useInventoryQuery(() => repos.spaces.listWithCounts(), 'spaces');
  const stored = spaceQuery.data;

  const [values, setValues] = useState<SpaceValues>({ name: '', icon: '', color: '' });
  const [nameError, setNameError] = useState<string | null>(null);
  /** A failed save; a `null` cause means the space was deleted elsewhere. */
  const [failure, setFailure] = useState<{ cause: unknown } | null>(null);
  const [busy, setBusy] = useState<'save' | 'delete' | null>(null);
  const busyRef = useRef(false);

  // Seed the form from the loaded record once per id, during render rather
  // than in an effect, so a background refetch never overwrites typing
  // (entities §14.2).
  const [seed, setSeed] = useState<{ id: string; values: SpaceValues } | null>(null);
  if (stored && seed?.id !== stored.id) {
    const initial = { name: stored.name, icon: stored.icon, color: stored.color };
    setSeed({ id: stored.id, values: initial });
    setValues(initial);
  }

  const gone = failure !== null && failure.cause === null;
  const dirty =
    stored !== null && seed !== null && !gone && spaceValuesChanged(values, seed.values);
  useDirtyGuard(dirty, { saving: busy !== null });

  function release() {
    busyRef.current = false;
    setBusy(null);
  }

  async function save() {
    if (busyRef.current) return;
    if (!values.name.trim()) {
      setNameError(strings.spaceForm.nameRequired);
      nameRef.current?.focus();
      return;
    }
    busyRef.current = true;
    setBusy('save');
    setFailure(null);
    try {
      const updated = await repos.spaces.update(id, { ...values, name: values.name.trim() });
      if (!updated) {
        // Deleted on another phone while this was open: never a fake success.
        release();
        setFailure({ cause: null });
        haptics.error();
        return;
      }
      logEvent('space_updated');
      invalidate();
      router.back();
      // An edit closes and says so, like every other form (spec §2.5 rule 5).
      toast.show({ message: strings.spaceForm.saved });
    } catch (cause) {
      release();
      setFailure({ cause });
      haptics.error();
    }
  }

  /**
   * Deleting a space takes its containers and items with it, so the confirm
   * says exactly what is lost, QR labels included (issue #4). Every step can
   * fail over the network, so all of it is caught and told (entities §15.5).
   */
  async function deleteSpace(current: Space) {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy('delete');
    try {
      const [impact, containers] = await Promise.all([
        repos.spaces.deletionImpact(id),
        repos.containers.listBySpace(id),
      ]);
      const labels = labelsInSpace(impact.qrBindingCount, containers);
      const confirmed = await confirm({
        title: strings.spaceForm.deleteTitle(current.name),
        body: spaceDeleteBody(impact, labels),
        confirmLabel: strings.common.delete,
      });
      if (!confirmed) {
        release();
        return;
      }
      const result = await repos.spaces.delete(id);
      // Nothing deleted means another phone deleted it first (the HTTP delete
      // answers a 404 that way): it is gone either way, but this phone did
      // not do it, so it is neither counted nor claimed.
      if (result.deleted) {
        deleteStoredPhotos(result.orphanedPhotoUris);
        logEvent('space_deleted', {
          containerCount: impact.containerCount,
          itemCount: impact.itemCount,
        });
      }
      invalidate();
      goToTab('/spaces');
      toast.show({
        message: result.deleted
          ? strings.spaceForm.deleted(current.name)
          : strings.spaceForm.alreadyDeleted(current.name),
      });
    } catch (cause) {
      release();
      haptics.error();
      toast.show({
        tone: 'error',
        message: strings.spaceForm.deleteFailed(current.name, isOffline(cause)),
      });
    }
  }

  function change(next: SpaceValues) {
    if (next.name !== values.name) setNameError(null);
    if (!gone) setFailure(null);
    setValues(next);
  }

  if (stored === null) {
    return (
      <ScreenFrame kind="modal">
        {spaceQuery.cause ? (
          <ErrorState cause={spaceQuery.cause} subject="space" onRetry={spaceQuery.reload} />
        ) : spaceQuery.loading ? (
          <View style={styles.skeleton}>
            <Skeleton variant="rows" rows={3} thumb={null} />
          </View>
        ) : (
          <ErrorState
            cause={null}
            subject="space"
            secondary={{ label: strings.common.goToSpaces, onPress: () => goToTab('/spaces') }}
          />
        )}
      </ScreenFrame>
    );
  }

  const counts = countsQuery.data?.find((entry) => entry.id === id);

  return (
    <FormLayout
      notice={
        failure ? (
          <SaveNotice
            cause={failure.cause}
            subject="space"
            action={
              gone
                ? { label: strings.common.goToSpaces, onPress: () => goToTab('/spaces') }
                : undefined
            }
          />
        ) : null
      }
      bottomBar={
        <BottomBar>
          <Button
            label={strings.spaceForm.save}
            onPress={() => void save()}
            loading={busy === 'save'}
            disabled={busy === 'delete' || gone}
            fullWidth
            testID="space-save"
          />
        </BottomBar>
      }
    >
      <SpaceFields
        values={values}
        onChange={change}
        nameError={nameError}
        onSubmit={() => void save()}
        nameRef={nameRef}
        previewCounts={
          counts ? { containers: counts.containerCount, items: counts.itemCount } : null
        }
        previewFallbackName={stored.name}
      />

      <View style={[styles.danger, { borderTopColor: colors.rule }]}>
        <Button
          label={strings.spaceForm.delete}
          icon="trash"
          variant="destructive"
          onPress={() => void deleteSpace(stored)}
          loading={busy === 'delete'}
          disabled={busy === 'save' || gone}
          accessibilityHint={strings.spaceForm.deleteHint}
          testID="space-delete"
        />
      </View>
    </FormLayout>
  );
}

const styles = StyleSheet.create({
  skeleton: {
    padding: GUTTER,
  },
  // With the form's 16 pt gap, 40 pt above the rule: Delete is never a
  // neighbour of Save.
  danger: {
    marginTop: space.xl,
    paddingTop: space.lg,
    borderTopWidth: 1,
  },
});
