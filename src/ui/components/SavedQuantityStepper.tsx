import { useSavedQuantity } from '@/hooks/useSavedQuantity';
import { strings } from '@/i18n/strings';
import { QuantityStepper } from '@/ui/components/QuantityStepper';

/** Plus/minus that writes through to the item immediately. */
export function SavedQuantityStepper({
  item,
  compact = false,
  showLabel = false,
}: {
  item: { id: string; quantity: number; updatedAt: number };
  compact?: boolean;
  showLabel?: boolean;
}) {
  const { quantity, setQuantity, error } = useSavedQuantity(item);
  return (
    <QuantityStepper
      value={quantity}
      onChange={setQuantity}
      compact={compact}
      label={showLabel ? strings.items.quantityLabel : undefined}
      error={compact ? null : error}
    />
  );
}
