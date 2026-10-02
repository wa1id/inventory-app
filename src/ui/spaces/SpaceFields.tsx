import type { RefObject } from 'react';
import { StyleSheet, View, type TextInput } from 'react-native';

import { strings } from '@/i18n/strings';
import { SpaceRow } from '@/ui/components/PlaceRows';
import { Sheet } from '@/ui/components/Sheet';
import { TextField } from '@/ui/components/TextField';
import { EmojiPicker } from '@/ui/components/pickers/EmojiPicker';
import { SwatchPicker } from '@/ui/components/pickers/SwatchPicker';
import type { SpaceValues } from '@/ui/spaces/spaceSetup';
import { SPACE_COLORS, SPACE_ICONS, space } from '@/ui/theme';

export interface SpaceFieldsProps {
  values: SpaceValues;
  onChange: (values: SpaceValues) => void;
  /** "Give the space a name." under the name field. */
  nameError?: string | null;
  /** The keyboard's return key saves, as the form's primary button does. */
  onSubmit: () => void;
  nameRef?: RefObject<TextInput | null>;
  /**
   * What the preview row counts. New spaces hold nothing yet; an existing
   * space passes its real counts, or `null` while they load, which hides the
   * preview rather than showing wrong numbers.
   */
  previewCounts: { containers: number; items: number } | null;
  /**
   * The preview's name while the field is empty: "Kitchen" as an example for
   * a new space, the stored name for one being edited (never another room's).
   */
  previewFallbackName?: string;
}

/**
 * Name, icon and colour of a space, shared by New space and Edit space.
 *
 * The icons are drawn in the chosen colour and a live row shows the space as
 * the Spaces tab will, so the tint is seen before saving. The icon grid also
 * offers the presets' shirt and door, so a Wardrobe or Cellar shows its icon
 * as selected when edited (entities §3), and swatches are named rather than
 * "Colour 3".
 */
export function SpaceFields({
  values,
  onChange,
  nameError,
  onSubmit,
  nameRef,
  previewCounts,
  previewFallbackName = strings.spaceForm.previewName,
}: SpaceFieldsProps) {
  return (
    <View style={styles.fields}>
      <TextField
        label={strings.spaceForm.nameLabel}
        placeholder={strings.spaceForm.namePlaceholder}
        value={values.name}
        onChangeText={(name) => onChange({ ...values, name })}
        error={nameError}
        required
        inputRef={nameRef}
        returnKeyType="done"
        onSubmitEditing={onSubmit}
        testID="space-name"
      />
      <EmojiPicker
        label={strings.spaceForm.iconLabel}
        options={SPACE_ICONS}
        value={values.icon}
        color={values.color}
        onChange={(icon) => onChange({ ...values, icon })}
      />
      <SwatchPicker
        label={strings.spaceForm.colourLabel}
        colors={SPACE_COLORS}
        value={values.color}
        onChange={(color) => onChange({ ...values, color })}
      />
      {previewCounts ? (
        // A picture of the fields above, so screen readers skip it.
        <View accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
          <Sheet>
            <SpaceRow
              space={{
                id: 'preview',
                name: values.name.trim() || previewFallbackName,
                icon: values.icon,
                color: values.color,
                containerCount: previewCounts.containers,
                itemCount: previewCounts.items,
                createdAt: 0,
                updatedAt: 0,
              }}
            />
          </Sheet>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  fields: {
    gap: space.xl,
  },
});
