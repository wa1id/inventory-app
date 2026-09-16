/**
 * Quantity is a whole number of things currently in a container.
 *
 * Zero is allowed: the item stays filed so you still know where it belongs
 * when none are there. The stepper refuses to go below that, and caps at a
 * household-scale maximum so a held plus button cannot run away.
 */
export const MIN_QUANTITY = 0;
export const MAX_QUANTITY = 9999;

/** Integer in [MIN_QUANTITY, MAX_QUANTITY], otherwise MIN_QUANTITY. */
export function clampQuantity(value: number): number {
  if (!Number.isInteger(value)) return MIN_QUANTITY;
  if (value < MIN_QUANTITY) return MIN_QUANTITY;
  if (value > MAX_QUANTITY) return MAX_QUANTITY;
  return value;
}

/**
 * Parses what the user typed into the quantity field.
 *
 * Empty, fractional, and negative values are rejected rather than coerced so
 * a mid-edit field is not silently replaced. Values above MAX_QUANTITY are
 * still parsed — the stepper clamps on commit.
 */
export function parseQuantityInput(raw: string): number | null {
  const trimmed = raw.trim();
  if (trimmed === '') return null;
  const value = Number(trimmed);
  if (!Number.isInteger(value) || value < MIN_QUANTITY) return null;
  return value;
}

export function stepQuantity(current: number, delta: number): number {
  return clampQuantity(current + delta);
}
