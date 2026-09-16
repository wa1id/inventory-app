import {
  MAX_QUANTITY,
  MIN_QUANTITY,
  clampQuantity,
  parseQuantityInput,
  stepQuantity,
} from '@/core/quantity';

describe('clampQuantity', () => {
  it('keeps a whole number in range', () => {
    expect(clampQuantity(0)).toBe(0);
    expect(clampQuantity(8)).toBe(8);
    expect(clampQuantity(MAX_QUANTITY)).toBe(MAX_QUANTITY);
  });

  it('rejects fractions and non-numbers by falling back to empty', () => {
    expect(clampQuantity(1.5)).toBe(MIN_QUANTITY);
    expect(clampQuantity(Number.NaN)).toBe(MIN_QUANTITY);
  });

  it('stops below zero and above the household cap', () => {
    expect(clampQuantity(-1)).toBe(MIN_QUANTITY);
    expect(clampQuantity(MAX_QUANTITY + 1)).toBe(MAX_QUANTITY);
  });
});

describe('parseQuantityInput', () => {
  it.each(['', '   ', 'abc', '1.5', '-1'])('rejects %p', (raw) => {
    expect(parseQuantityInput(raw)).toBeNull();
  });

  it('accepts zero and trims whole numbers', () => {
    expect(parseQuantityInput('0')).toBe(0);
    expect(parseQuantityInput(' 12 ')).toBe(12);
  });
});

describe('stepQuantity', () => {
  it('moves by one and stops at the ends', () => {
    expect(stepQuantity(3, 1)).toBe(4);
    expect(stepQuantity(3, -1)).toBe(2);
    expect(stepQuantity(0, -1)).toBe(0);
    expect(stepQuantity(MAX_QUANTITY, 1)).toBe(MAX_QUANTITY);
  });
});
