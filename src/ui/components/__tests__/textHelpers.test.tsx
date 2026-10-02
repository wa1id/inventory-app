import { splitHighlight } from '@/ui/components/AppText';
import { matchCategories } from '@/ui/components/ItemForm';
import { numberFieldWidth } from '@/ui/components/QuantityStepper';

describe('splitHighlight', () => {
  it('puts matches at odd indexes, case-insensitively', () => {
    expect(splitHighlight('Spare batteries AA', ['batt', 'aa'])).toEqual([
      'Spare ',
      'batt',
      'eries ',
      'AA',
      '',
    ]);
  });

  it('ignores one-letter terms and escapes regex characters', () => {
    expect(splitHighlight('USB-C (2m)', ['c', '(2m)'])).toEqual(['USB-C ', '(2m)', '']);
    expect(splitHighlight('Drill', [])).toEqual(['Drill']);
  });
});

describe('matchCategories', () => {
  const known = ['Tools', 'Toys', 'tools', 'Kitchen', 'Tape', 'Tins', 'Tea', 'Towels', 'Tiles'];

  it('offers known categories that start with what is typed, once each', () => {
    expect(matchCategories(known, 'to')).toEqual(['Tools', 'Toys', 'Towels']);
  });

  it('hides an exact match and caps the list at six', () => {
    expect(matchCategories(known, 'Tools')).toEqual([]);
    expect(matchCategories(known, '')).toHaveLength(6);
  });
});

describe('numberFieldWidth', () => {
  it('keeps the geometry minimum at normal text sizes', () => {
    expect(numberFieldWidth(3, 17, 1, 1.6, 48)).toBe(48);
    expect(numberFieldWidth(4, 22, 1, 1.6, 80)).toBe(80);
  });

  it('grows with the text size, up to the variant cap', () => {
    // 4 digits of 17 pt at 1.6× need about 68 pt plus the field's padding.
    expect(numberFieldWidth(4, 17, 1.6, 1.6, 56)).toBe(76);
    expect(numberFieldWidth(4, 17, 3.1, 1.6, 56)).toBe(76);
  });
});
