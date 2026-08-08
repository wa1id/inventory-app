import { useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { strings } from '@/i18n/strings';
import type { RecognitionSuggestion } from '@/services/ai/contract';
import { Button } from '@/ui/components/Button';
import { TextField } from '@/ui/components/TextField';
import { radius, spacing, useTheme } from '@/ui/theme';

export interface ItemFormValues {
  name: string;
  category: string;
  tags: string;
  quantity: string;
  notes: string;
}

export interface ItemFormErrors {
  name?: string;
  quantity?: string;
}

export const EMPTY_ITEM_FORM: ItemFormValues = {
  name: '',
  category: '',
  tags: '',
  quantity: '1',
  notes: '',
};

/** Parsed, validated values ready for the repository. */
export interface ParsedItemForm {
  name: string;
  category: string | null;
  tags: string[];
  quantity: number;
  notes: string | null;
}

/**
 * Validates the form without discarding anything the user typed.
 *
 * Returns errors alongside the parsed result so a recoverable failure can be
 * shown inline while the entered values stay on screen (issue #13).
 */
export function validateItemForm(values: ItemFormValues): {
  errors: ItemFormErrors;
  parsed: ParsedItemForm | null;
} {
  const errors: ItemFormErrors = {};

  const name = values.name.trim();
  if (!name) errors.name = strings.items.nameRequired;

  const quantity = Number(values.quantity.trim());
  if (!Number.isInteger(quantity) || quantity < 1) {
    errors.quantity = strings.items.quantityInvalid;
  }

  if (Object.keys(errors).length > 0) return { errors, parsed: null };

  return {
    errors,
    parsed: {
      name,
      category: values.category.trim() || null,
      tags: values.tags
        .split(',')
        .map((tag) => tag.trim())
        .filter(Boolean),
      quantity,
      notes: values.notes.trim() || null,
    },
  };
}

/**
 * Folds a photo suggestion into the form.
 *
 * Two modes, because "the AI answered" and "the user rejected the answer and
 * asked again" call for opposite defaults:
 *
 * - `overwrite: false` — the first pass. Fills only blanks, so a suggestion
 *   landing while the user types cannot take a field back off them (issue #13).
 * - `overwrite: true` — an explicit refresh after the user corrected the name.
 *   The supporting fields were derived from an identification they rejected, so
 *   leaving them would file the item under the wrong category and tags.
 *
 * The name is never taken from the suggestion once the field holds anything:
 * on a refresh it is the correction that prompted the request in the first
 * place. Quantity and notes are the user's alone and are never touched.
 */
export function applySuggestion(
  current: ItemFormValues,
  suggestion: RecognitionSuggestion,
  { overwrite = false }: { overwrite?: boolean } = {},
): ItemFormValues {
  const tags = suggestion.tags.join(', ');

  return {
    ...current,
    name: current.name || (suggestion.name ?? ''),
    ...(overwrite
      ? { category: suggestion.category ?? '', tags }
      : {
          category: current.category || (suggestion.category ?? ''),
          tags: current.tags || tags,
        }),
  };
}

interface ItemFormProps {
  values: ItemFormValues;
  onChange: (values: ItemFormValues) => void;
  errors: ItemFormErrors;
  photoUri?: string | null;
  onRemovePhoto?: () => void;
  /** Banner describing AI suggestion state; rendered above the fields. */
  suggestionBanner?: React.ReactNode;
  locationLabel?: string;
  onSubmit: () => void;
  submitLabel: string;
  saving?: boolean;
  footer?: React.ReactNode;
}

export function ItemForm({
  values,
  onChange,
  errors,
  photoUri,
  onRemovePhoto,
  suggestionBanner,
  locationLabel,
  onSubmit,
  submitLabel,
  saving = false,
  footer,
}: ItemFormProps) {
  const { colors } = useTheme();
  const [showAdvanced, setShowAdvanced] = useState(false);

  function set<K extends keyof ItemFormValues>(key: K, value: ItemFormValues[K]) {
    onChange({ ...values, [key]: value });
  }

  return (
    <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {photoUri ? (
        <View style={styles.photoWrap}>
          <Image source={{ uri: photoUri }} style={styles.photo} accessibilityIgnoresInvertColors />
          {onRemovePhoto ? (
            <Button label="Remove photo" variant="ghost" onPress={onRemovePhoto} />
          ) : null}
        </View>
      ) : null}

      {locationLabel ? (
        <View style={[styles.locationChip, { backgroundColor: colors.surfaceAlt }]}>
          <Text style={[styles.locationText, { color: colors.text }]}>📍 {locationLabel}</Text>
        </View>
      ) : null}

      {suggestionBanner}

      <TextField
        label={strings.items.nameLabel}
        placeholder={strings.items.namePlaceholder}
        value={values.name}
        onChangeText={(value) => set('name', value)}
        error={errors.name}
        required
        autoFocus={!photoUri}
      />

      <TextField
        label={strings.items.categoryLabel}
        placeholder="Tools"
        value={values.category}
        onChangeText={(value) => set('category', value)}
      />

      <TextField
        label={strings.items.quantityLabel}
        value={values.quantity}
        onChangeText={(value) => set('quantity', value)}
        error={errors.quantity}
        keyboardType="number-pad"
      />

      {showAdvanced ? (
        <>
          <TextField
            label={strings.items.tagsLabel}
            placeholder="winter, fragile"
            value={values.tags}
            onChangeText={(value) => set('tags', value)}
            hint={strings.items.tagsHint}
          />

          <TextField
            label={strings.items.notesLabel}
            value={values.notes}
            onChangeText={(value) => set('notes', value)}
            multiline
            numberOfLines={4}
          />
        </>
      ) : (
        <Button
          label="More details"
          variant="ghost"
          onPress={() => setShowAdvanced(true)}
          accessibilityHint="Shows tags and notes"
        />
      )}

      <View style={styles.actions}>
        <Button label={submitLabel} onPress={onSubmit} loading={saving} fullWidth />
        {footer}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: spacing.lg,
    gap: spacing.lg,
    paddingBottom: spacing.xxl,
  },
  photoWrap: {
    alignItems: 'center',
    gap: spacing.sm,
  },
  photo: {
    width: '100%',
    height: 220,
    borderRadius: radius.lg,
    resizeMode: 'cover',
  },
  locationChip: {
    alignSelf: 'flex-start',
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.pill,
  },
  locationText: {
    fontSize: 14,
    fontWeight: '600',
  },
  actions: {
    gap: spacing.sm,
    marginTop: spacing.md,
  },
});
