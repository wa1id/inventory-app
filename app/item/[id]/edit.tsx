import { useState } from 'react';
import { Alert } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import {
  EMPTY_ITEM_FORM,
  ItemForm,
  validateItemForm,
  type ItemFormErrors,
  type ItemFormValues,
} from '@/ui/components/ItemForm';

export default function EditItemScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();

  const {
    data: item,
    loading,
    error,
    reload,
  } = useInventoryQuery(() => repos.items.getById(id), `item:${id}`);

  const [values, setValues] = useState<ItemFormValues>(EMPTY_ITEM_FORM);
  const [errors, setErrors] = useState<ItemFormErrors>({});
  const [saving, setSaving] = useState(false);

  // Seed the form from the loaded record exactly once, during render rather
  // than in an effect: React documents this as the way to adjust state when
  // inputs change, and it avoids the extra render pass an effect would cost.
  const [seededId, setSeededId] = useState<string | null>(null);
  if (item && seededId !== item.id) {
    setSeededId(item.id);
    setValues({
      name: item.name,
      category: item.category ?? '',
      tags: item.tags.join(', '),
      quantity: String(item.quantity),
      estimatedValue: item.estimatedValue !== null ? String(item.estimatedValue) : '',
      currency: item.currency ?? '',
      notes: item.notes ?? '',
    });
  }

  async function save() {
    const { errors: nextErrors, parsed } = validateItemForm(values);
    setErrors(nextErrors);
    if (!parsed) return;

    setSaving(true);
    try {
      await repos.items.update(id, parsed);
      logEvent('item_updated');
      invalidate();
      router.back();
    } catch (cause) {
      setSaving(false);
      Alert.alert(
        'Could not save',
        cause instanceof Error
          ? cause.message
          : 'The item could not be saved. Your changes are still here.',
      );
    }
  }

  if (loading && !item) {
    return (
      <Screen>
        <LoadingState />
      </Screen>
    );
  }

  if (error || !item) {
    return (
      <Screen>
        <ErrorState message={error ?? 'That item no longer exists.'} onRetry={reload} />
      </Screen>
    );
  }

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ItemForm
        values={values}
        onChange={(next) => {
          setValues(next);
          if (Object.keys(errors).length > 0) setErrors({});
        }}
        errors={errors}
        photoUri={item.photoUri}
        locationLabel={`${item.spaceName} > ${item.containerName ?? item.containerShortCode}`}
        onSubmit={save}
        submitLabel={strings.common.save}
        saving={saving}
        footer={
          <Button
            label={strings.common.cancel}
            variant="ghost"
            fullWidth
            onPress={() => router.back()}
          />
        }
      />
    </Screen>
  );
}
