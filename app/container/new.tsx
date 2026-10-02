import { useEffect, useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { useLocalSearchParams, useNavigation, useRouter } from 'expo-router';

import { DROP_ZONE_SPACE_ID } from '@/db/constants';
import type { ContainerVisualType } from '@/db/types';
import { useDirtyGuard } from '@/hooks/useDirtyGuard';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { ErrorState } from '@/ui/components/ErrorState';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { SpacePip } from '@/ui/components/SpacePip';
import { TextField } from '@/ui/components/TextField';
import { TypeGrid } from '@/ui/components/pickers/TypeGrid';
import { haptics } from '@/ui/haptics';
import type { NewContainerResult } from '@/ui/navigation';
import { abandonResult, deliverResult } from '@/ui/routeResult';
import { DropZoneLocked, FormLayout, SaveNotice } from '@/ui/spaces/FormLayout';
import { containerLabel, isOffline } from '@/ui/spaces/spaceSetup';
import { space } from '@/ui/theme';

const DEFAULT_TYPE: ContainerVisualType = 'box';

export default function NewContainerScreen() {
  const { spaceId, request } = useLocalSearchParams<{ spaceId: string; request?: string }>();

  // Opened from the place picker, the sheet answers with the new container;
  // closed without one, it tells the picker to stop waiting. Idempotent, so
  // it is harmless after a delivery.
  useEffect(() => () => abandonResult(request), [request]);

  // Nothing offers the drop zone's system space; a stale link gets no form.
  if (spaceId === DROP_ZONE_SPACE_ID) return <DropZoneLocked />;
  return <NewContainer spaceId={spaceId} request={request} />;
}

/**
 * A new container in a known space: its type, and a name only if wanted,
 * since an unnamed container goes by the code on its label. It opens
 * straight away, replacing this sheet, because a new
 * container is there to be filled; from the place picker it is handed back
 * instead and the picker files into it.
 */
function NewContainer({ spaceId, request }: { spaceId: string; request: string | undefined }) {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const navigation = useNavigation();
  const toast = useToast();

  const spaceQuery = useInventoryQuery(() => repos.spaces.getById(spaceId), `space:${spaceId}`);

  const [name, setName] = useState('');
  const [visualType, setVisualType] = useState<ContainerVisualType>(DEFAULT_TYPE);
  const [failure, setFailure] = useState<{ cause: unknown } | null>(null);
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);

  useDirtyGuard(name.trim() !== '' || visualType !== DEFAULT_TYPE, { saving });

  async function save() {
    // The button and the return key both save; a ref, so a double submit in
    // one frame cannot create two containers.
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    setFailure(null);
    try {
      const container = await repos.containers.create({ spaceId, name, visualType });
      logEvent('container_created');
      invalidate();
      haptics.success();
      if (!navigation.isFocused()) {
        // The header Cancel closed the sheet mid-save (swipe-down and Android
        // back wait for it). Navigating now would act on whatever is in front
        // (the place picker, Move, the label screen, the space), and a picker
        // that was waiting would file into a container from a sheet the person
        // closed: the unmount tells it nothing came of it. The container is
        // made, and the list in front refreshes to show it.
        toast.show({ message: strings.containerForm.created(containerLabel(container)) });
        return;
      }
      const delivered = deliverResult<NewContainerResult>(request, {
        containerId: container.id,
        name: container.name,
        shortCode: container.shortCode,
        visualType: container.visualType,
        spaceId: container.spaceId,
      });
      if (delivered) router.back();
      else router.replace(`/container/${container.id}`);
    } catch (cause) {
      savingRef.current = false;
      setSaving(false);
      haptics.error();
      // Normally the banner; a sheet closed under the save says it in a toast.
      if (navigation.isFocused()) {
        setFailure({ cause });
      } else {
        toast.show({ tone: 'error', message: strings.containerForm.notCreated(isOffline(cause)) });
      }
    }
  }

  const spaceData = spaceQuery.data;
  if (spaceData === null && !spaceQuery.loading && !spaceQuery.cause) {
    // The space was deleted, probably on another phone: nothing to add to.
    return (
      <ScreenFrame kind="modal">
        <ErrorState
          cause={null}
          subject="space"
          secondary={{ label: strings.common.goBack, onPress: () => router.back() }}
        />
      </ScreenFrame>
    );
  }

  return (
    <FormLayout
      notice={failure ? <SaveNotice cause={failure.cause} subject="container" /> : null}
      bottomBar={
        <BottomBar>
          <Button
            label={strings.containerForm.create}
            onPress={() => void save()}
            loading={saving}
            fullWidth
            testID="container-create"
          />
        </BottomBar>
      }
    >
      {spaceData ? (
        <View style={styles.context}>
          <SpacePip color={spaceData.color} size={10} />
          <AppText variant="meta" style={styles.contextText}>
            {strings.containerForm.inSpace(spaceData.name)}
          </AppText>
        </View>
      ) : null}

      <TypeGrid
        label={strings.containerForm.typeLabel}
        value={visualType}
        onChange={(next) => {
          setVisualType(next);
          setFailure(null);
        }}
      />

      <TextField
        label={strings.containerForm.nameLabel}
        optional
        placeholder={strings.containerForm.namePlaceholder}
        hint={strings.containerForm.nameHint}
        value={name}
        onChangeText={(next) => {
          setName(next);
          // Typing clears a failed save's notice; it used to stay forever.
          setFailure(null);
        }}
        returnKeyType="done"
        onSubmitEditing={() => void save()}
        testID="container-name"
      />
    </FormLayout>
  );
}

const styles = StyleSheet.create({
  context: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  contextText: {
    flexShrink: 1,
  },
});
