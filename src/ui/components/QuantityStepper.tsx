import { useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  InputAccessoryView,
  Platform,
  Pressable,
  StyleSheet,
  TextInput,
  View,
  type AccessibilityActionEvent,
} from 'react-native';

import {
  MAX_QUANTITY,
  MIN_QUANTITY,
  clampQuantity,
  parseQuantityInput,
  stepQuantity,
} from '@/core/quantity';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import { AppText, useTextStyle } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon } from '@/ui/components/Icon';
import { PressedOverlay, rippleFor } from '@/ui/components/PressFeedback';
import { haptics } from '@/ui/haptics';
import { delay } from '@/ui/motion';
import { radius, space, useTheme } from '@/ui/theme';
import { TEXT_VARIANTS, maxScale } from '@/ui/typography';

/** During hold-repeat only every fifth step ticks, so holding is not a buzz. */
const REPEAT_HAPTIC_EVERY = 5;

const GEOMETRY = {
  compact: { cell: 48, number: 48, numberWide: 56, icon: 20 },
  large: { cell: 56, number: 80, numberWide: 80, icon: 24 },
} as const;

/** A tabular digit is a little under 0.62 em wide in Atkinson and the system fonts. */
const DIGIT_EM = 0.62;

/**
 * The number field's width: the geometry's minimum, or wider when the digits
 * need it at the current text size. Set explicitly rather than left to the
 * input, which on some platforms (web) takes a default width of its own and
 * pushes the plus button and the row's text out of the way.
 */
export function numberFieldWidth(
  digits: number,
  fontSize: number,
  fontScale: number,
  maxFontScale: number,
  minimum: number,
): number {
  const scaled = fontSize * Math.min(Math.max(fontScale, 1), maxFontScale);
  return Math.max(minimum, Math.ceil(digits * scaled * DIGIT_EM) + 2 * space.xs);
}

export interface QuantityStepperProps {
  value: number;
  onChange: (next: number) => void;
  size?: 'compact' | 'large';
  /** Names the item in every label: "Increase quantity of Wood screws". */
  itemName?: string;
  /** `large` only, shown under the stepper. */
  error?: string | null;
  disabled?: boolean;
  /**
   * Appended to the testIDs on list rows, where several steppers share a
   * screen. Bare on the item screen and the Add form (kept contract).
   */
  testIDSuffix?: string;
  /** @deprecated Use `size="compact"`. */
  compact?: boolean;
  /** @deprecated Ignored; the field label belongs to the form around the stepper. */
  label?: string;
}

function StepButton({
  delta,
  size,
  disabled,
  itemName,
  testID,
  onStep,
  onRepeat,
  onStop,
}: {
  delta: 1 | -1;
  size: 'compact' | 'large';
  disabled: boolean;
  itemName?: string;
  testID: string;
  onStep: () => void;
  onRepeat: () => void;
  onStop: () => void;
}) {
  const { colors } = useTheme();
  const geometry = GEOMETRY[size];
  const increase = delta > 0;
  const label = itemName
    ? increase
      ? strings.quantity.increase(itemName)
      : strings.quantity.decrease(itemName)
    : increase
      ? strings.quantity.increasePlain
      : strings.quantity.decreasePlain;

  return (
    <Pressable
      onPress={onStep}
      onLongPress={onRepeat}
      delayLongPress={delay.stepRepeat}
      onPressOut={onStop}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled }}
      android_ripple={rippleFor(colors)}
      testID={testID}
      style={[styles.cell, { width: geometry.cell, height: geometry.cell }]}
    >
      {({ pressed }) => (
        <>
          <PressedOverlay pressed={pressed} />
          <Icon
            name={increase ? 'plus' : 'minus'}
            size={geometry.icon}
            color={disabled ? colors.ruleStrong : colors.ink}
          />
        </>
      )}
    </Pressable>
  );
}

/**
 * Minus, the number, plus. Controlled and free of I/O: the Add form holds the
 * value, `SavedQuantityStepper` writes it through.
 *
 * Tap steps by one; holding repeats after 400 ms every 80 ms until release or
 * a bound. Tapping the number types one: the draft commits on blur, on submit
 * or on the iOS "Done" bar (the number pad has no return key), and anything
 * that is not a whole number reverts. Pressing ± with a draft open commits
 * the draft first.
 *
 * VoiceOver gets one adjustable element (swipe up and down to step); TalkBack
 * gets three plain elements, because its adjustable model is hard to find.
 */
export function QuantityStepper({
  value,
  onChange,
  size,
  itemName,
  error,
  disabled = false,
  testIDSuffix,
  compact,
}: QuantityStepperProps) {
  const { colors } = useTheme();
  const { stacked, fontScale } = useLayoutScale();
  const kind = size ?? (compact ? 'compact' : 'large');
  const large = kind === 'large';
  const geometry = GEOMETRY[kind];
  const numberStyle = useTextStyle(large ? 'stepperL' : 'stepper');

  const valueRef = useRef(value);
  const inputRef = useRef<TextInput>(null);
  const repeatRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const repeatCountRef = useRef(0);
  const [draft, setDraft] = useState<string | null>(null);

  useEffect(() => {
    valueRef.current = value;
  }, [value]);

  useEffect(() => () => stopRepeat(), []);

  // VoiceOver does not read a live region; a failed save is announced instead.
  useEffect(() => {
    if (Platform.OS === 'ios' && large && error) AccessibilityInfo.announceForAccessibility(error);
  }, [error, large]);

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

  function bump(delta: number, repeating = false) {
    if (disabled) return;
    const base = commitDraft();
    const next = stepQuantity(base, delta);
    if (next === base) {
      stopRepeat();
      return;
    }
    valueRef.current = next;
    onChange(next);
    if (next === MIN_QUANTITY) {
      haptics.reachedZero();
    } else if (!repeating || ++repeatCountRef.current % REPEAT_HAPTIC_EVERY === 0) {
      haptics.step();
    }
  }

  function startRepeat(delta: number) {
    bump(delta);
    stopRepeat();
    repeatCountRef.current = 0;
    repeatRef.current = setInterval(() => bump(delta, true), delay.stepRepeatEvery);
  }

  function commitTyped() {
    const next = commitDraft();
    if (next !== value) onChange(next);
  }

  function onAccessibilityAction(event: AccessibilityActionEvent) {
    switch (event.nativeEvent.actionName) {
      case 'increment':
        bump(1);
        break;
      case 'decrement':
        bump(-1);
        break;
      case 'activate':
        inputRef.current?.focus();
        break;
    }
  }

  const suffix = testIDSuffix ? `-${testIDSuffix}` : '';
  const accessoryID = `qty-done-${testIDSuffix ?? 'form'}`;
  const ios = Platform.OS === 'ios';
  const empty = value <= MIN_QUANTITY;
  const minusDisabled = disabled || empty;
  const plusDisabled = disabled || value >= MAX_QUANTITY;
  const fieldLabel = itemName ? strings.quantity.field(itemName) : strings.quantity.fieldPlain;
  const valueText = empty ? strings.rows.noneLeft : String(value);
  const fill = large && stacked;

  return (
    <View style={[styles.wrap, fill ? styles.wrapFill : null]}>
      <View
        accessible={ios}
        accessibilityRole={ios ? 'adjustable' : undefined}
        accessibilityLabel={ios ? fieldLabel : undefined}
        accessibilityValue={
          ios ? { min: MIN_QUANTITY, max: MAX_QUANTITY, now: value, text: valueText } : undefined
        }
        accessibilityActions={
          ios
            ? [
                { name: 'increment' },
                { name: 'decrement' },
                { name: 'activate', label: strings.quantity.typeNumber },
              ]
            : undefined
        }
        onAccessibilityAction={ios ? onAccessibilityAction : undefined}
        style={[
          styles.control,
          {
            backgroundColor: colors.sheet,
            borderColor: error ? colors.signal : colors.control,
            opacity: disabled ? 0.45 : 1,
          },
          fill ? styles.controlFill : null,
        ]}
      >
        <StepButton
          delta={-1}
          size={kind}
          disabled={minusDisabled}
          itemName={itemName}
          testID={`quantity-decrease${suffix}`}
          onStep={() => bump(-1)}
          onRepeat={() => startRepeat(-1)}
          onStop={stopRepeat}
        />
        <TextInput
          ref={inputRef}
          value={draft ?? String(value)}
          onChangeText={setDraft}
          onFocus={() => setDraft(String(valueRef.current))}
          onBlur={commitTyped}
          onSubmitEditing={commitTyped}
          keyboardType="number-pad"
          returnKeyType="done"
          selectTextOnFocus
          maxLength={String(MAX_QUANTITY).length}
          editable={!disabled}
          inputAccessoryViewID={ios ? accessoryID : undefined}
          maxFontSizeMultiplier={maxScale(large ? 'stepperL' : 'stepper')}
          accessibilityLabel={ios ? undefined : `${fieldLabel}, ${valueText}`}
          testID={`quantity-input${suffix}`}
          style={[
            numberStyle,
            styles.number,
            {
              width: fill
                ? undefined
                : numberFieldWidth(
                    Math.max(String(value).length, draft?.length ?? 0),
                    TEXT_VARIANTS[large ? 'stepperL' : 'stepper'].size,
                    fontScale,
                    maxScale(large ? 'stepperL' : 'stepper'),
                    value >= 1000 ? geometry.numberWide : geometry.number,
                  ),
              minHeight: geometry.cell,
              color: empty && draft === null ? colors.signal : colors.ink,
              backgroundColor: draft !== null ? colors.numberFocus : 'transparent',
              borderColor: colors.ruleStrong,
            },
            fill ? styles.numberFill : null,
          ]}
        />
        <StepButton
          delta={1}
          size={kind}
          disabled={plusDisabled}
          itemName={itemName}
          testID={`quantity-increase${suffix}`}
          onStep={() => bump(1)}
          onRepeat={() => startRepeat(1)}
          onStop={stopRepeat}
        />
      </View>
      {large && error ? (
        <View style={styles.message} accessibilityLiveRegion="polite">
          <Icon name="warning" size={16} color={colors.signal} />
          <AppText variant="meta" tone="signal" weight={600} style={styles.messageText}>
            {error}
          </AppText>
        </View>
      ) : null}
      {ios ? (
        <InputAccessoryView nativeID={accessoryID} backgroundColor={colors.sheet2}>
          <View style={[styles.accessory, { borderTopColor: colors.rule }]}>
            <Button
              label={strings.quantity.done}
              variant="quiet"
              size="sm"
              onPress={() => inputRef.current?.blur()}
            />
          </View>
        </InputAccessoryView>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    gap: 6,
    flexShrink: 0,
    alignItems: 'flex-start',
  },
  wrapFill: {
    alignSelf: 'stretch',
    alignItems: 'stretch',
  },
  control: {
    flexDirection: 'row',
    alignItems: 'stretch',
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  controlFill: {
    alignSelf: 'stretch',
  },
  cell: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  number: {
    textAlign: 'center',
    paddingHorizontal: space.xs,
    paddingVertical: 0,
    borderLeftWidth: 1,
    borderRightWidth: 1,
  },
  numberFill: {
    flex: 1,
    // An input's own minimum width would otherwise push plus off the end (web).
    minWidth: 0,
  },
  message: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 6,
  },
  messageText: {
    flexShrink: 1,
  },
  accessory: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    paddingHorizontal: space.sm,
    paddingVertical: space.xs,
    borderTopWidth: 1,
  },
});
