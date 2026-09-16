import { useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import * as Haptics from 'expo-haptics';

import {
  MAX_QUANTITY,
  MIN_QUANTITY,
  clampQuantity,
  parseQuantityInput,
  stepQuantity,
} from '@/core/quantity';
import { strings } from '@/i18n/strings';
import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

const REPEAT_DELAY_MS = 400;
const REPEAT_EVERY_MS = 80;

interface QuantityStepperProps {
  value: number;
  onChange: (next: number) => void;
  /** Uppercase field label, same treatment as TextField. */
  label?: string;
  error?: string | null;
  /** Tight control for a list row. Default fills the available width. */
  compact?: boolean;
  disabled?: boolean;
}

export function QuantityStepper({
  value,
  onChange,
  label,
  error,
  compact = false,
  disabled = false,
}: QuantityStepperProps) {
  const { colors } = useTheme();
  const valueRef = useRef(value);
  const [draft, setDraft] = useState<string | null>(null);
  const repeatRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    valueRef.current = value;
  }, [value]);

  useEffect(() => () => stopRepeat(), []);

  function stopRepeat() {
    if (repeatRef.current) clearInterval(repeatRef.current);
    repeatRef.current = null;
  }

  function commitDraft(): number {
    if (draft === null) return valueRef.current;
    const parsed = parseQuantityInput(draft);
    setDraft(null);
    if (parsed === null) return valueRef.current;
    const next = clampQuantity(parsed);
    valueRef.current = next;
    return next;
  }

  function bump(delta: number) {
    if (disabled) return;
    const base = commitDraft();
    const next = stepQuantity(base, delta);
    if (next === base) {
      stopRepeat();
      return;
    }
    valueRef.current = next;
    onChange(next);
    void Haptics.selectionAsync().catch(() => undefined);
  }

  function handlePress(delta: number) {
    bump(delta);
  }

  function handleLongPress(delta: number) {
    bump(delta);
    stopRepeat();
    repeatRef.current = setInterval(() => bump(delta), REPEAT_EVERY_MS);
  }

  function onSubmitEditing() {
    const next = commitDraft();
    if (next !== value) onChange(next);
  }

  const display = draft ?? String(value);
  const minusDisabled = disabled || value <= MIN_QUANTITY;
  const plusDisabled = disabled || value >= MAX_QUANTITY;
  const borderColor = error ? colors.danger : colors.border;

  return (
    <View style={styles.wrap}>
      {label ? <Text style={[styles.label, { color: colors.textMuted }]}>{label}</Text> : null}
      <View
        style={[
          styles.control,
          compact ? styles.controlCompact : styles.controlBlock,
          { backgroundColor: colors.surface, borderColor },
        ]}
      >
        <Pressable
          onPress={() => handlePress(-1)}
          onLongPress={() => handleLongPress(-1)}
          delayLongPress={REPEAT_DELAY_MS}
          onPressOut={stopRepeat}
          disabled={minusDisabled}
          accessibilityRole="button"
          accessibilityLabel={strings.items.quantityDecrease}
          accessibilityState={{ disabled: minusDisabled }}
          testID="quantity-decrease"
          style={({ pressed }) => [
            compact ? styles.btnCompact : styles.btn,
            { opacity: minusDisabled ? 0.35 : pressed ? 0.7 : 1 },
          ]}
        >
          <Text style={[styles.btnGlyph, { color: colors.text }]}>−</Text>
        </Pressable>

        <TextInput
          value={display}
          onChangeText={setDraft}
          onFocus={() => setDraft(String(valueRef.current))}
          onBlur={() => {
            const next = commitDraft();
            if (next !== value) onChange(next);
          }}
          onSubmitEditing={onSubmitEditing}
          keyboardType="number-pad"
          returnKeyType="done"
          selectTextOnFocus
          maxLength={String(MAX_QUANTITY).length}
          editable={!disabled}
          accessibilityLabel={strings.items.quantityA11y(value)}
          testID="quantity-input"
          style={[compact ? styles.valueCompact : styles.value, { color: colors.text }]}
        />

        <Pressable
          onPress={() => handlePress(1)}
          onLongPress={() => handleLongPress(1)}
          delayLongPress={REPEAT_DELAY_MS}
          onPressOut={stopRepeat}
          disabled={plusDisabled}
          accessibilityRole="button"
          accessibilityLabel={strings.items.quantityIncrease}
          accessibilityState={{ disabled: plusDisabled }}
          testID="quantity-increase"
          style={({ pressed }) => [
            compact ? styles.btnCompact : styles.btn,
            { opacity: plusDisabled ? 0.35 : pressed ? 0.7 : 1 },
          ]}
        >
          <Text style={[styles.btnGlyph, { color: colors.text }]}>+</Text>
        </Pressable>
      </View>
      {error ? (
        <Text style={[styles.message, { color: colors.danger }]} accessibilityLiveRegion="polite">
          {error}
        </Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    gap: spacing.xs,
    flexShrink: 0,
  },
  label: {
    fontSize: 13,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
  },
  control: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderRadius: radius.md,
    overflow: 'hidden',
  },
  controlBlock: {
    alignSelf: 'stretch',
  },
  controlCompact: {
    alignSelf: 'flex-end',
  },
  btn: {
    minWidth: MIN_TOUCH_TARGET + spacing.lg,
    minHeight: MIN_TOUCH_TARGET,
    alignItems: 'center',
    justifyContent: 'center',
    flex: 1,
  },
  btnCompact: {
    minWidth: MIN_TOUCH_TARGET,
    minHeight: MIN_TOUCH_TARGET,
    alignItems: 'center',
    justifyContent: 'center',
  },
  btnGlyph: {
    fontSize: 22,
    fontWeight: '600',
    lineHeight: 26,
  },
  value: {
    minWidth: 72,
    minHeight: MIN_TOUCH_TARGET,
    paddingHorizontal: spacing.sm,
    fontSize: 22,
    fontWeight: '700',
    fontVariant: ['tabular-nums'],
    textAlign: 'center',
  },
  valueCompact: {
    width: 44,
    minHeight: MIN_TOUCH_TARGET,
    fontSize: 16,
    fontWeight: '700',
    fontVariant: ['tabular-nums'],
    textAlign: 'center',
    paddingHorizontal: 0,
  },
  message: {
    fontSize: 13,
    lineHeight: 18,
  },
});
