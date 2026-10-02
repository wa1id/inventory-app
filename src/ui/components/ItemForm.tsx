import { useRef, useState, type RefObject } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';

import { parseQuantityInput } from '@/core/quantity';
import { strings } from '@/i18n/strings';
import type { RecognitionSuggestion } from '@/services/ai/contract';
import { useCategorySuggestions } from '@/ui/categoryMemory';
import { Chip } from '@/ui/components/pickers/Chip';
import { TextField } from '@/ui/components/TextField';
import { space } from '@/ui/theme';

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
  if (!name) errors.name = strings.forms.itemNameRequired;

  const quantity = parseQuantityInput(values.quantity);
  if (quantity === null) {
    errors.quantity = strings.forms.quantityInvalid;
  }

  if (Object.keys(errors).length > 0 || quantity === null) {
    return { errors, parsed: null };
  }

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

export interface ItemDetailsFieldsProps {
  values: ItemFormValues;
  onChange: (values: ItemFormValues) => void;
  /** Lets the field before these (the name) chain into Category with the return key. */
  refs?: {
    category?: RefObject<TextInput | null>;
    tags?: RefObject<TextInput | null>;
    notes?: RefObject<TextInput | null>;
  };
}

/**
 * Category, Tags and Notes: the details under "More details" in the Add sheet
 * and the Edit details form.
 *
 * Return moves Category → Tags → Notes with the keyboard up; in Notes it
 * starts a new line. Category chips only fill the field on an explicit tap,
 * then move on to Tags, so a suggestion never lands while someone is typing.
 */
export function ItemDetailsFields({ values, onChange, refs }: ItemDetailsFieldsProps) {
  // What `categoryMemory` has seen, most recent first; the field never fetches
  // (a fetch would download photos just to read category names).
  const suggestions = useCategorySuggestions(values.category);
  const categoryLocal = useRef<TextInput>(null);
  const tagsLocal = useRef<TextInput>(null);
  const notesLocal = useRef<TextInput>(null);
  const categoryRef = refs?.category ?? categoryLocal;
  const tagsRef = refs?.tags ?? tagsLocal;
  const notesRef = refs?.notes ?? notesLocal;
  const [categoryFocused, setCategoryFocused] = useState(false);
  const chips = categoryFocused ? suggestions : [];

  function set<K extends keyof ItemFormValues>(key: K, value: ItemFormValues[K]) {
    onChange({ ...values, [key]: value });
  }

  return (
    <View style={styles.details}>
      <View style={styles.category}>
        <TextField
          label={strings.forms.categoryLabel}
          placeholder={strings.forms.categoryPlaceholder}
          value={values.category}
          onChangeText={(value) => set('category', value)}
          onFocus={() => setCategoryFocused(true)}
          onBlur={() => setCategoryFocused(false)}
          inputRef={categoryRef}
          nextRef={tagsRef}
          testID="item-category"
        />
        {chips.length > 0 ? (
          <View style={styles.chips}>
            {chips.map((category, index) => (
              <Chip
                key={category}
                label={category}
                onPress={() => {
                  set('category', category);
                  tagsRef.current?.focus();
                }}
                testID={`item-category-chip-${index}`}
              />
            ))}
          </View>
        ) : null}
      </View>

      <TextField
        label={strings.forms.tagsLabel}
        placeholder={strings.forms.tagsPlaceholder}
        value={values.tags}
        onChangeText={(value) => set('tags', value)}
        hint={strings.forms.tagsHint}
        inputRef={tagsRef}
        nextRef={notesRef}
        testID="item-tags"
      />

      <TextField
        label={strings.forms.notesLabel}
        value={values.notes}
        onChangeText={(value) => set('notes', value)}
        multiline
        inputRef={notesRef}
        testID="item-notes"
      />
    </View>
  );
}

const styles = StyleSheet.create({
  details: {
    gap: space.lg,
  },
  category: {
    gap: space.sm,
  },
  chips: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: space.sm,
  },
});
