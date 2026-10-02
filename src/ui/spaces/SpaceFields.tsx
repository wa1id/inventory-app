import type { RefObject } from 'react';
import { StyleSheet, View, type TextInput } from 'react-native';

import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Row } from '@/ui/components/Row';
import { Sheet } from '@/ui/components/Sheet';
import { SpaceTile } from '@/ui/components/SpaceTile';
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
   * The preview row's second line: "New space" for one not made yet, the
   * real counts for one being edited, or `null` while those load, which hides
   * the preview rather than showing wrong numbers.
   */
  previewMeta: string | null;
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
 * as selected when edited, and swatches are named rather than
 * "Colour 3".
 */
export function SpaceFields({
  values,
  onChange,
  nameError,
  onSubmit,
  nameRef,
  previewMeta,
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
      {previewMeta !== null ? (
        // A picture of the fields above, so screen readers skip it. Labelled
        // like every other block, so it is not taken for a stray list row.
        <View
          style={styles.preview}
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
        >
          <AppText variant="label">{strings.spaceForm.previewLabel}</AppText>
          <Sheet>
            {/* The Spaces tab's row, drawn static: no chevron, nothing to open. */}
            <Row
              leading={<SpaceTile icon={values.icon} color={values.color} size={56} />}
              testID="space-row-preview"
            >
              <AppText variant="name" style={styles.previewName}>
                {values.name.trim() || previewFallbackName}
              </AppText>
              <AppText variant="meta" tone="graphite">
                {previewMeta}
              </AppText>
            </Row>
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
  // As the pickers' label sits over its grid.
  preview: {
    gap: space.sm,
  },
  previewName: {
    flexShrink: 1,
  },
});
