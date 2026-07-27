import { useCallback, useEffect, useState } from 'react';
import { Alert } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { recognizeItem } from '@/services/ai/recognition';
import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';
import {
  EMPTY_ITEM_FORM,
  ItemForm,
  validateItemForm,
  type ItemFormErrors,
  type ItemFormValues,
} from '@/ui/components/ItemForm';
import { Button } from '@/ui/components/Button';
import { Screen } from '@/ui/components/Screen';
import { SuggestionBanner, type SuggestionState } from '@/ui/components/SuggestionBanner';

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
  const { containerId, photoUri, photoWidth, photoHeight, photoBytes } = useLocalSearchParams<{
    containerId: string;
    photoUri?: string;
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
   */
  const runRecognition = useCallback(async (uri: string) => {
    const result = await recognizeItem({ imageUri: uri });

    if (result.status === 'failed') {
      setSuggestion({ status: 'failed', reason: result.reason });
      return;
    }

    // Only fill fields the user has not already typed into: a suggestion
    // must never overwrite their work.
    setValues((current) => ({
      ...current,
      name: current.name || (result.suggestion.name ?? ''),
      category: current.category || (result.suggestion.category ?? ''),
      tags: current.tags || result.suggestion.tags.join(', '),
      estimatedValue:
        current.estimatedValue ||
        (result.suggestion.estimatedValue !== null ? String(result.suggestion.estimatedValue) : ''),
      currency: current.currency || (result.suggestion.currency ?? ''),
    }));
    setSuggestion({ status: 'applied', confidence: result.suggestion.confidence });
  }, []);

  useEffect(() => {
    // Kicking off an async request on mount is what effects are for. The rule
    // flags this because `runRecognition` transitively calls setState, but it
    // only does so after awaiting the network call — never synchronously in
    // this effect body, so no cascading render occurs.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (photo) void runRecognition(photo);
  }, [photo, runRecognition]);

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
              width: toPositiveInt(photoWidth),
              height: toPositiveInt(photoHeight),
              byteSize: toPositiveInt(photoBytes),
            }
          : null,
      });

      logEvent('item_created', {
        hasPhoto: Boolean(photo),
        suggestionAccepted: suggestion.status === 'applied',
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
    ? `${space ? `${space.name} > ` : ''}${container.name ?? container.shortCode}`
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
            state={suggestion}
            onRetry={
              photo
                ? () => {
                    setSuggestion({ status: 'running' });
                    void runRecognition(photo);
                  }
                : undefined
            }
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
