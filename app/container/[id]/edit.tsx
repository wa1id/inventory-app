import { useRef, useState, type ReactElement } from 'react';
import { StyleSheet, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { Container, ContainerVisualType } from '@/db/types';
import { useDirtyGuard } from '@/hooks/useDirtyGuard';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { ErrorState } from '@/ui/components/ErrorState';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { Skeleton } from '@/ui/components/Skeleton';
import { SpaceTile } from '@/ui/components/SpaceTile';
import { TextField } from '@/ui/components/TextField';
import { ChoiceList } from '@/ui/components/pickers/ChoiceList';
import { TypeGrid } from '@/ui/components/pickers/TypeGrid';
import { confirm } from '@/ui/confirm';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { goToTab } from '@/ui/navigation';
import { DropZoneLocked, FormLayout, SaveNotice } from '@/ui/spaces/FormLayout';
import {
  containerDeleteBody,
  containerLabel,
  containerValuesChanged,
  isOffline,
} from '@/ui/spaces/spaceSetup';
import { GUTTER, space, useTheme } from '@/ui/theme';

interface Values {
  name: string;
  visualType: ContainerVisualType;
  spaceId: string;
}

export default function EditContainerScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  // The drop zone is not a container anyone can rename, move or delete (B4).
  if (id === DROP_ZONE_CONTAINER_ID) return <DropZoneLocked />;
  return <EditContainer id={id} />;
}

/**
 * Rename, retype or move a container to another space, or delete it.
 *
 * The type is the same tile grid as when creating it (it was a strip of
 * lower-case chips here), the spaces are all on screen as a list (they were a
 * horizontal strip with the choice often off screen), and the label code is
 * said to stay as it is, because it is printed on the label (entities §6,
 * §14.13).
 */
function EditContainer({ id }: { id: string }) {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const toast = useToast();
  const { colors } = useTheme();

  const containerQuery = useInventoryQuery(() => repos.containers.getById(id), `container:${id}`);
  const spacesQuery = useInventoryQuery(() => repos.spaces.listWithCounts(), 'spaces');
  const stored = containerQuery.data;

  const [values, setValues] = useState<Values>({ name: '', visualType: 'box', spaceId: '' });
  /** A failed save; a `null` cause means the container was deleted elsewhere. */
  const [failure, setFailure] = useState<{ cause: unknown } | null>(null);
  const [busy, setBusy] = useState<'save' | 'delete' | null>(null);
  const busyRef = useRef(false);

  // Seed once per id, during render, so a background refetch never overwrites
  // what is being edited (entities §14.2).
  const [seed, setSeed] = useState<{ id: string; values: Values } | null>(null);
  if (stored && seed?.id !== stored.id) {
    const initial = {
      name: stored.name ?? '',
      visualType: stored.visualType,
      spaceId: stored.spaceId,
    };
    setSeed({ id: stored.id, values: initial });
    setValues(initial);
  }

  const gone = failure !== null && failure.cause === null;
  const dirty =
    stored !== null && seed !== null && !gone && containerValuesChanged(values, seed.values);
  useDirtyGuard(dirty, { saving: busy !== null });

  function release() {
    busyRef.current = false;
    setBusy(null);
  }

  function change(next: Partial<Values>) {
    if (!gone) setFailure(null);
    setValues((previous) => ({ ...previous, ...next }));
  }

  async function save() {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy('save');
    setFailure(null);
    try {
      // An emptied name is stored as null, and the container goes by its code again.
      const updated = await repos.containers.update(id, values);
      if (!updated) {
        // Deleted on another phone while this was open: never a fake success.
        release();
        setFailure({ cause: null });
        haptics.error();
        return;
      }
      logEvent('container_updated');
      invalidate();
      router.back();
      // An edit closes and says so, like every other form (spec §2.5 rule 5).
      toast.show({ message: strings.containerForm.saved });
    } catch (cause) {
      release();
      setFailure({ cause });
      haptics.error();
    }
  }

  /**
   * Deleting a container takes its items with it and unlinks its label, so
   * the confirm says so (issue #4); every step is caught and told, rather
   * than failing silently over the network (entities §15.5).
   */
  async function deleteContainer(current: Container) {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy('delete');
    const label = containerLabel(current);
    try {
      const impact = await repos.containers.deletionImpact(id);
      const confirmed = await confirm({
        title: strings.containerForm.deleteTitle(label),
        body: containerDeleteBody(impact),
        confirmLabel: strings.common.delete,
      });
      if (!confirmed) {
        release();
        return;
      }
      const result = await repos.containers.delete(id);
      // Nothing deleted means another phone deleted it first (the HTTP delete
      // answers a 404 that way): it is gone either way, but this phone did
      // not do it, so it is neither counted nor claimed.
      if (result.deleted) {
        deleteStoredPhotos(result.orphanedPhotoUris);
        logEvent('container_deleted', { itemCount: impact.itemCount });
      }
      invalidate();
      // Not `dismissTo`: when the space screen was never opened (the container
      // came from search or a label) that would leave the deleted container in
      // the stack (spec §2.5 rule 8).
      router.dismissAll();
      router.push(`/space/${current.spaceId}`);
      toast.show({
        message: result.deleted
          ? strings.containerForm.deleted(label)
          : strings.containerForm.alreadyDeleted(label),
      });
    } catch (cause) {
      release();
      haptics.error();
      toast.show({
        tone: 'error',
        message: strings.containerForm.deleteFailed(label, isOffline(cause)),
      });
    }
  }

  if (stored === null) {
    return (
      <ScreenFrame kind="modal">
        {containerQuery.cause ? (
          <ErrorState
            cause={containerQuery.cause}
            subject="container"
            onRetry={containerQuery.reload}
          />
        ) : containerQuery.loading ? (
          <View style={styles.skeleton}>
            <Skeleton variant="rows" rows={3} thumb={null} />
          </View>
        ) : (
          <ErrorState
            cause={null}
            subject="container"
            secondary={{ label: strings.common.goToSpaces, onPress: () => goToTab('/spaces') }}
          />
        )}
      </ScreenFrame>
    );
  }

  let spaceChoice: ReactElement;
  if (spacesQuery.data) {
    spaceChoice = (
      <ChoiceList
        accessibilityLabel={strings.containerForm.spaceLabel}
        options={spacesQuery.data.map((option) => ({
          value: option.id,
          title: option.name,
          leading: <SpaceTile icon={option.icon} color={option.color} size={32} />,
          testID: `space-option-${option.id}`,
        }))}
        value={values.spaceId}
        onChange={(spaceId) => change({ spaceId })}
      />
    );
  } else if (spacesQuery.cause) {
    const described = describeError(spacesQuery.cause);
    spaceChoice = (
      <Banner
        tone="warning"
        title={described.title}
        message={described.body}
        action={{ label: strings.common.tryAgain, onPress: spacesQuery.reload }}
      />
    );
  } else {
    spaceChoice = <Skeleton variant="rows" rows={3} thumb={null} />;
  }

  return (
    <FormLayout
      notice={
        failure ? (
          <SaveNotice
            cause={failure.cause}
            subject="container"
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
            label={strings.containerForm.save}
            onPress={() => void save()}
            loading={busy === 'save'}
            disabled={busy === 'delete' || gone}
            fullWidth
            testID="container-save"
          />
        </BottomBar>
      }
    >
      <TextField
        label={strings.containerForm.nameLabel}
        optional
        // Empty, it goes by its code, so the code is what the field shows.
        placeholder={stored.shortCode}
        hint={strings.containerForm.nameHint}
        value={values.name}
        onChangeText={(name) => change({ name })}
        returnKeyType="done"
        onSubmitEditing={() => void save()}
        testID="container-name"
      />

      <View style={styles.group}>
        <TypeGrid
          label={strings.containerForm.typeLabel}
          value={values.visualType}
          onChange={(visualType) => change({ visualType })}
        />
        <AppText variant="caption" tone="graphite">
          {strings.containerForm.codeStays(stored.shortCode)}
        </AppText>
      </View>

      <View style={styles.group}>
        <AppText variant="label">{strings.containerForm.spaceLabel}</AppText>
        {spaceChoice}
      </View>

      <View style={[styles.danger, { borderTopColor: colors.rule }]}>
        <Button
          label={strings.containerForm.delete}
          icon="trash"
          variant="destructive"
          onPress={() => void deleteContainer(stored)}
          loading={busy === 'delete'}
          disabled={busy === 'save' || gone}
          accessibilityHint={strings.containerForm.deleteHint}
          testID="container-delete"
        />
      </View>
    </FormLayout>
  );
}

const styles = StyleSheet.create({
  skeleton: {
    padding: GUTTER,
  },
  group: {
    gap: space.sm,
  },
  // With the form's 16 pt gap, 40 pt above the rule: Delete is never a
  // neighbour of Save.
  danger: {
    marginTop: space.xl,
    paddingTop: space.lg,
    borderTopWidth: 1,
  },
});
