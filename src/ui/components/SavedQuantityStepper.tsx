import { StyleSheet, View } from 'react-native';

import { useLayoutScale } from '@/hooks/useLayoutScale';
import { useSavedQuantity, type QuantityErrorKind } from '@/hooks/useSavedQuantity';
import { strings } from '@/i18n/strings';
import { useToast } from '@/providers/ToastProvider';
import { AppText } from '@/ui/components/AppText';
import { QuantityStepper } from '@/ui/components/QuantityStepper';
import { space } from '@/ui/theme';

export interface SavedQuantityStepperProps {
  /** A blank `name` (an unnamed item) keeps the labels generic. */
  item: { id: string; name: string; quantity: number; updatedAt: number };
  size?: 'compact' | 'large';
  testIDSuffix?: string;
  /**
   * Where a compact stepper reports a failed save, with the sentence naming
   * the item ("The quantity of “Wood screws” was not saved. Try again.").
   * Defaults to an error toast, so a failure in a long list is never silent.
   */
  onError?: (message: string, kind: QuantityErrorKind) => void;
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
  size: kind = 'large',
  testIDSuffix,
  onError,
}: SavedQuantityStepperProps) {
  const large = kind === 'large';
  const { stacked } = useLayoutScale();
  const name = item.name.trim() ? item.name : undefined;
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
    <View style={large ? [styles.large, stacked ? null : styles.largeEnd] : styles.compact}>
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
  // Beside its label, the "None left right now" note lines up with the
  // stepper's end; stacked, the stepper is full width and the note starts
  // under the label like the rest of the column.
  largeEnd: {
    alignItems: 'flex-end',
  },
  compact: {
    alignItems: 'flex-end',
    gap: space.xs,
  },
});
