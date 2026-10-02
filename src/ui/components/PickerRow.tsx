import { StyleSheet, View } from 'react-native';

import type { ContainerVisualType } from '@/db/types';
import { AppText } from '@/ui/components/AppText';
import { ChoiceList } from '@/ui/components/pickers/ChoiceList';
import { SwatchPicker, type SwatchPickerProps } from '@/ui/components/pickers/SwatchPicker';
import { TypeGrid } from '@/ui/components/pickers/TypeGrid';
import { space } from '@/ui/theme';

/*
 * The pre-redesign picker names, kept as thin aliases of `pickers/` so the
 * old space and container forms keep working until they are rewritten.
 * Removed in cleanup.
 */

interface Option<T> {
  value: T;
  label: string;
}

interface ChoiceRowProps<T> {
  label: string;
  options: readonly Option<T>[];
  value: T;
  onChange: (value: T) => void;
}

/** @deprecated Use `ChoiceList` (or `EmojiPicker` for space icons). */
export function ChoiceRow<T extends string>({
  label,
  options,
  value,
  onChange,
}: ChoiceRowProps<T>) {
  return (
    <View style={styles.container}>
      <AppText variant="label">{label}</AppText>
      <ChoiceList
        options={options.map((option) => ({ value: option.value, title: option.label }))}
        value={value}
        onChange={onChange}
        accessibilityLabel={label}
      />
    </View>
  );
}

/** @deprecated Use `SwatchPicker`. */
export function ColorRow(props: SwatchPickerProps) {
  return <SwatchPicker {...props} />;
}

interface TileRowProps {
  label: string;
  /** Glyphs and labels are ignored: types draw their own line icons now. */
  options: readonly { value: ContainerVisualType; glyph: string; label: string }[];
  value: ContainerVisualType;
  onChange: (value: ContainerVisualType) => void;
}

/** @deprecated Use `TypeGrid`. */
export function TileRow({ label, value, onChange }: TileRowProps) {
  return <TypeGrid label={label} value={value} onChange={onChange} />;
}

const styles = StyleSheet.create({
  container: {
    gap: space.sm,
  },
});
