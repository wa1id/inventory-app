import { validateItemForm, EMPTY_ITEM_FORM } from '@/ui/components/ItemForm';

describe('validateItemForm', () => {
  it('accepts a minimal item', () => {
    const { errors, parsed } = validateItemForm({ ...EMPTY_ITEM_FORM, name: 'Drill' });

    expect(errors).toEqual({});
    expect(parsed).toEqual({
      name: 'Drill',
      category: null,
      tags: [],
      quantity: 1,
      estimatedValue: null,
      currency: null,
      notes: null,
    });
  });

  it('requires a name', () => {
    const { errors, parsed } = validateItemForm({ ...EMPTY_ITEM_FORM, name: '   ' });
    expect(errors.name).toBeDefined();
    expect(parsed).toBeNull();
  });

  it.each(['0', '-1', '1.5', 'abc', ''])('rejects quantity %p', (quantity) => {
    const { errors } = validateItemForm({ ...EMPTY_ITEM_FORM, name: 'Drill', quantity });
    expect(errors.quantity).toBeDefined();
  });

  it('rejects a negative or non-numeric value but allows an empty one', () => {
    expect(
      validateItemForm({ ...EMPTY_ITEM_FORM, name: 'Drill', estimatedValue: '-5' }).errors
        .estimatedValue,
    ).toBeDefined();
    expect(
      validateItemForm({ ...EMPTY_ITEM_FORM, name: 'Drill', estimatedValue: 'free' }).errors
        .estimatedValue,
    ).toBeDefined();
    expect(
      validateItemForm({ ...EMPTY_ITEM_FORM, name: 'Drill', estimatedValue: '  ' }).errors
        .estimatedValue,
    ).toBeUndefined();
  });

  it('accepts a comma decimal separator', () => {
    const { parsed } = validateItemForm({
      ...EMPTY_ITEM_FORM,
      name: 'Drill',
      estimatedValue: '12,50',
    });
    expect(parsed?.estimatedValue).toBe(12.5);
  });

  it('splits and trims tags, dropping empties', () => {
    const { parsed } = validateItemForm({
      ...EMPTY_ITEM_FORM,
      name: 'Drill',
      tags: ' power tool ,, dewalt , ',
    });
    expect(parsed?.tags).toEqual(['power tool', 'dewalt']);
  });

  it('normalizes the currency code to upper case', () => {
    const { parsed } = validateItemForm({
      ...EMPTY_ITEM_FORM,
      name: 'Drill',
      currency: 'eur',
    });
    expect(parsed?.currency).toBe('EUR');
  });

  it('reports every problem at once so nothing is lost between attempts', () => {
    const { errors } = validateItemForm({
      ...EMPTY_ITEM_FORM,
      name: '',
      quantity: '0',
      estimatedValue: 'lots',
    });

    expect(Object.keys(errors).sort()).toEqual(['estimatedValue', 'name', 'quantity']);
  });
});
