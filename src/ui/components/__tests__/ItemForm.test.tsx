import type { RecognitionSuggestion } from '@/services/ai/contract';
import { applySuggestion, validateItemForm, EMPTY_ITEM_FORM } from '@/ui/components/ItemForm';

describe('validateItemForm', () => {
  it('accepts a minimal item', () => {
    const { errors, parsed } = validateItemForm({ ...EMPTY_ITEM_FORM, name: 'Drill' });

    expect(errors).toEqual({});
    expect(parsed).toEqual({
      name: 'Drill',
      category: null,
      tags: [],
      quantity: 1,
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

  it('splits and trims tags, dropping empties', () => {
    const { parsed } = validateItemForm({
      ...EMPTY_ITEM_FORM,
      name: 'Drill',
      tags: ' power tool ,, dewalt , ',
    });
    expect(parsed?.tags).toEqual(['power tool', 'dewalt']);
  });

  it('reports every problem at once so nothing is lost between attempts', () => {
    const { errors } = validateItemForm({
      ...EMPTY_ITEM_FORM,
      name: '',
      quantity: '0',
    });

    expect(Object.keys(errors).sort()).toEqual(['name', 'quantity']);
  });
});

describe('applySuggestion', () => {
  const suggestion: RecognitionSuggestion = {
    name: 'Cordless drill',
    category: 'Power Tools',
    tags: ['dewalt', '18v'],
    confidence: 0.9,
  };

  it('fills an untouched form', () => {
    const values = applySuggestion(EMPTY_ITEM_FORM, suggestion);

    expect(values).toMatchObject({
      name: 'Cordless drill',
      category: 'Power Tools',
      tags: 'dewalt, 18v',
    });
  });

  it('never takes back a field the user typed while it was in flight', () => {
    const typed = {
      ...EMPTY_ITEM_FORM,
      name: 'Angle grinder',
      category: 'Garage',
      quantity: '3',
      notes: 'top shelf',
    };

    const values = applySuggestion(typed, suggestion);

    expect(values.name).toBe('Angle grinder');
    expect(values.category).toBe('Garage');
    expect(values.quantity).toBe('3');
    expect(values.notes).toBe('top shelf');
    // Blanks are still worth filling.
    expect(values.tags).toBe('dewalt, 18v');
  });

  it('replaces the supporting fields on an explicit refresh', () => {
    const wrong = {
      ...EMPTY_ITEM_FORM,
      name: 'Angle grinder',
      category: 'Kitchenware',
      tags: 'blender, mixing',
    };

    const values = applySuggestion(wrong, suggestion, { overwrite: true });

    expect(values.category).toBe('Power Tools');
    expect(values.tags).toBe('dewalt, 18v');
  });

  it('keeps the corrected name on a refresh, whatever the backend echoes', () => {
    const values = applySuggestion({ ...EMPTY_ITEM_FORM, name: 'Angle grinder' }, suggestion, {
      overwrite: true,
    });

    expect(values.name).toBe('Angle grinder');
  });

  it('leaves quantity and notes alone even on a refresh', () => {
    const values = applySuggestion(
      { ...EMPTY_ITEM_FORM, name: 'Angle grinder', quantity: '4', notes: 'chipped' },
      suggestion,
      { overwrite: true },
    );

    expect(values.quantity).toBe('4');
    expect(values.notes).toBe('chipped');
  });

  it('clears fields a refreshed suggestion has nothing to say about', () => {
    // Otherwise the old guess's category survives on an item it never
    // described, which is the bug the refresh exists to fix.
    const values = applySuggestion(
      { ...EMPTY_ITEM_FORM, name: 'Shoebox', category: 'Power Tools', tags: 'dewalt' },
      { name: 'Shoebox', category: null, tags: [], confidence: 0.6 },
      { overwrite: true },
    );

    expect(values.category).toBe('');
    expect(values.tags).toBe('');
  });
});
