import { useCallback, useEffect, useState } from 'react';
import { Alert } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { recognizeItem } from '@/services/ai/recognition';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';
import {
  EMPTY_ITEM_FORM,
  ItemForm,
  applySuggestion,
  validateItemForm,
  type ItemFormErrors,
  type ItemFormValues,
} from '@/ui/components/ItemForm';
import { Button } from '@/ui/components/Button';
import { Screen } from '@/ui/components/Screen';
import {
  SuggestionBanner,
  staleSuggestionName,
  type SuggestionState,
} from '@/ui/components/SuggestionBanner';

/** Route params arrive as strings; anything unusable becomes undefined. */
function toPositiveInt(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

/**
 * Review-and-save screen for a new item.
 *
 * Reached two ways: straight from a container ("add without a photo") or after
 * capture with a `photoUri`. When a photo is present, recognition runs in the
 * background and merely prefills the same controls — the user can type over it
 * at any point, and a failure never blocks saving (issues #7, #13).
 */
export default function NewItemScreen() {
  const { containerId, photoUri, photoThumbUri, photoWidth, photoHeight, photoBytes } =
    useLocalSearchParams<{
      containerId: string;
      photoUri?: string;
      photoThumbUri?: string;
      photoWidth?: string;
      photoHeight?: string;
      photoBytes?: string;
    }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();

  const [values, setValues] = useState<ItemFormValues>(EMPTY_ITEM_FORM);
  const [errors, setErrors] = useState<ItemFormErrors>({});
  const [saving, setSaving] = useState(false);
  const [suggestion, setSuggestion] = useState<SuggestionState>(
    photoUri ? { status: 'running' } : { status: 'idle' },
  );
  const [photo, setPhoto] = useState<string | null>(photoUri ?? null);

  const { data: container } = useInventoryQuery(
    () => repos.containers.getWithCounts(containerId),
    `container:${containerId}`,
  );
  const { data: space } = useInventoryQuery(
    async () => (container ? repos.spaces.getById(container.spaceId) : null),
    `space:${container?.spaceId ?? 'none'}`,
  );

  /**
   * Sets only terminal states. `running` is established by the initial state
   * (photo present) or by the retry handler, so the kick-off effect never
   * writes state synchronously.
   *
   * @param nameHint The name the user typed over ours; asks the backend to
   *   describe *that* item instead of repeating its own identification.
   * @param overwrite Replace the supporting fields rather than filling the
   *   blanks. Only for an explicit "update the other details": those fields
   *   were derived from an identification the user has since rejected, so
   *   keeping them would file the item under the wrong category and tags.
   *   A hint alone never implies this — a retry can be name-anchored without
   *   being allowed to discard what the user typed.
   */
  const runRecognition = useCallback(async (uri: string, nameHint?: string, overwrite = false) => {
    const result = await recognizeItem({ imageUri: uri, nameHint });

    if (result.status === 'failed') {
      setSuggestion({ status: 'failed', reason: result.reason });
      return;
    }

    setValues((current) => applySuggestion(current, result.suggestion, { overwrite }));

    // Record which name the details now describe, so a further edit to the
    // title is recognised as making them stale again.
    setSuggestion(
      overwrite && nameHint
        ? // The hint, not the echoed name: this is the title now in the field,
          // so a backend that ignored the hint cannot leave the banner asking
          // to refresh a name it just refreshed.
          { status: 'refreshed', forName: nameHint }
        : {
            status: 'applied',
            confidence: result.suggestion.confidence,
            forName: result.suggestion.name ?? '',
          },
    );
  }, []);

  useEffect(() => {
    // Kicking off an async request on mount is what effects are for. The rule
    // flags this because `runRecognition` transitively calls setState, but it
    // only does so after awaiting the network call — never synchronously in
    // this effect body, so no cascading render occurs.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (photo) void runRecognition(photo);
  }, [photo, runRecognition]);

  const typedName = values.name.trim();
  /** Set once the title no longer matches what the other fields describe. */
  const staleName = staleSuggestionName(suggestion, typedName);

  function refreshFromName(uri: string, hint: string) {
    setSuggestion({ status: 'refreshing' });
    void runRecognition(uri, hint, true);
  }

  /**
   * @param andAnother Return straight to the camera instead of the saved item.
   *   Adding things off a shelf is a run, not a single errand, so the common
   *   case should not cost a trip back through the container screen.
   */
  async function save(andAnother = false) {
    const { errors: nextErrors, parsed } = validateItemForm(values);
    setErrors(nextErrors);
    if (!parsed) return;

    setSaving(true);
    try {
      const item = await repos.items.create({
        containerId,
        ...parsed,
        photo: photo
          ? {
              uri: photo,
              thumbUri: photoThumbUri,
              width: toPositiveInt(photoWidth),
              height: toPositiveInt(photoHeight),
              byteSize: toPositiveInt(photoBytes),
            }
          : null,
      });

      logEvent('item_created', {
        hasPhoto: Boolean(photo),
        suggestionAccepted: suggestion.status === 'applied' || suggestion.status === 'refreshed',
        hinted: suggestion.status === 'refreshed',
      });
      invalidate();
      // `replace`, not `push`: the saved form must not sit in the back stack,
      // so Back from the camera lands on the container either way.
      if (andAnother) router.replace(`/capture?containerId=${containerId}`);
      else router.dismissTo(`/item/${item.id}`);
    } catch (cause) {
      setSaving(false);
      Alert.alert(
        'Could not save',
        cause instanceof Error
          ? cause.message
          : 'The item could not be saved. Your details are still here.',
      );
    }
  }

  function discardPhoto() {
    if (!photo) return;
    const uri = photo;
    setPhoto(null);
    setSuggestion({ status: 'idle' });
    // The photo was written to app storage during capture; drop the file since
    // it is not referenced by any item row.
    deleteStoredPhotos([uri]);
  }

  const locationLabel = container
    ? containerId === DROP_ZONE_CONTAINER_ID
      ? strings.dropZone.title
      : `${space ? `${space.name} > ` : ''}${container.name ?? container.shortCode}`
    : undefined;

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ItemForm
        values={values}
        onChange={(next) => {
          setValues(next);
          if (Object.keys(errors).length > 0) setErrors({});
        }}
        errors={errors}
        photoUri={photo}
        onRemovePhoto={photo ? discardPhoto : undefined}
        locationLabel={locationLabel}
        suggestionBanner={
          <SuggestionBanner
            state={staleName ? { status: 'stale', forName: staleName } : suggestion}
            onRetry={
              photo
                ? () => {
                    setSuggestion({ status: 'running' });
                    // A name typed before the retry anchors it: there is no
                    // reason to ask the photo alone when the user has already
                    // said what the thing is.
                    void runRecognition(photo, typedName || undefined);
                  }
                : undefined
            }
            onRefresh={photo && staleName ? () => refreshFromName(photo, staleName) : undefined}
          />
        }
        onSubmit={() => void save()}
        submitLabel={strings.items.save}
        saving={saving}
        footer={
          <>
            <Button
              label={strings.items.saveAndAdd}
              icon="📸"
              variant="secondary"
              fullWidth
              disabled={saving}
              onPress={() => void save(true)}
              testID="item-save-and-add"
            />
            <Button
              label={strings.common.cancel}
              variant="ghost"
              fullWidth
              onPress={() => router.back()}
            />
          </>
        }
      />
    </Screen>
  );
}
