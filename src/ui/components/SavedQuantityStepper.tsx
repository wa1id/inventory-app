import { StyleSheet, View } from 'react-native';

import { useSavedQuantity, type QuantityErrorKind } from '@/hooks/useSavedQuantity';
import { strings } from '@/i18n/strings';
import { useToast } from '@/providers/ToastProvider';
import { AppText } from '@/ui/components/AppText';
import { QuantityStepper } from '@/ui/components/QuantityStepper';
import { space } from '@/ui/theme';

export interface SavedQuantityStepperProps {
  /** `name` may be missing on legacy call sites; labels then stay generic. */
  item: { id: string; name?: string; quantity: number; updatedAt: number };
  size?: 'compact' | 'large';
  testIDSuffix?: string;
  /**
   * Where a compact stepper reports a failed save, with the sentence naming
   * the item ("The quantity of “Wood screws” was not saved. Try again.").
   * Defaults to an error toast, so a failure in a long list is never silent.
   */
  onError?: (message: string, kind: QuantityErrorKind) => void;
  /** @deprecated Use `size="compact"`. */
  compact?: boolean;
  /** @deprecated Shows "Quantity" above the stepper; new screens label it themselves. */
  showLabel?: boolean;
}

/**
 * Plus/minus that writes through to the item immediately: no Save button.
 *
 * Writes are optimistic, coalesced and retried on conflict by
 * `useSavedQuantity`; a failed one snaps the number back with an error haptic
 * and a sentence, so a count that did not save never looks saved.
 */
export function SavedQuantityStepper({
  item,
  size,
  testIDSuffix,
  onError,
  compact,
  showLabel = false,
}: SavedQuantityStepperProps) {
  const kind = size ?? (compact ? 'compact' : 'large');
  const large = kind === 'large';
  const name = item.name?.trim() ? item.name : undefined;
  const toast = useToast();
  const { quantity, setQuantity, error } = useSavedQuantity(item, {
    onError: (failure) => {
      // A large stepper has room for the sentence under itself.
      if (large) return;
      const message = strings.quantity.notSavedNamed(
        name ?? strings.entities.unnamedItem,
        failure === 'offline',
      );
      if (onError) onError(message, failure);
      else toast.show({ message, tone: 'error' });
    },
  });

  return (
    <View style={large ? styles.large : styles.compact}>
      {showLabel ? <AppText variant="label">{strings.quantity.label}</AppText> : null}
      <QuantityStepper
        value={quantity}
        onChange={setQuantity}
        size={kind}
        itemName={name}
        error={large ? error : null}
        testIDSuffix={testIDSuffix}
      />
      {large && !error && quantity === 0 ? (
        <AppText variant="meta" tone="signal" weight={600}>
          {strings.quantity.noneRightNow}
        </AppText>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  large: {
    gap: 6,
  },
  compact: {
    alignItems: 'flex-end',
    gap: space.xs,
  },
});
