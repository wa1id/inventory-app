import { normalizeForCodeMatch, toLikePattern, tokenizeQuery } from '@/core/tokenize';
import { generateShortCode, normalizeShortCode } from '@/core/shortCode';

describe('tokenizeQuery', () => {
  it('lowercases and splits on whitespace', () => {
    expect(tokenizeQuery('Cordless Drill')).toEqual(['cordless', 'drill']);
  });

  it('returns nothing for empty or whitespace-only input', () => {
    expect(tokenizeQuery('')).toEqual([]);
    expect(tokenizeQuery('   ')).toEqual([]);
    expect(tokenizeQuery('!!! ??? ...')).toEqual([]);
  });

  it('deduplicates repeated terms', () => {
    expect(tokenizeQuery('drill drill DRILL')).toEqual(['drill']);
  });

  it('keeps dashes inside short codes but trims leading/trailing ones', () => {
    expect(tokenizeQuery('BOX-7K2M')).toEqual(['box-7k2m']);
    expect(tokenizeQuery('-drill-')).toEqual(['drill']);
  });

  it('splits on punctuation that is not a dash', () => {
    expect(tokenizeQuery('screws, nails; bolts')).toEqual(['screws', 'nails', 'bolts']);
  });

  it('strips accents so unaccented queries still match', () => {
    expect(tokenizeQuery('Café')).toEqual(['cafe']);
  });

  it('keeps digits and non-latin scripts', () => {
    expect(tokenizeQuery('18v battery')).toEqual(['18v', 'battery']);
    expect(tokenizeQuery('ワイヤー')).toEqual(['ワイヤー']);
  });

  it('caps the number of terms', () => {
    const query = Array.from({ length: 40 }, (_, i) => `term${i}`).join(' ');
    expect(tokenizeQuery(query)).toHaveLength(12);
  });
});

describe('toLikePattern', () => {
  it('wraps a term in wildcards', () => {
    expect(toLikePattern('drill')).toBe('%drill%');
  });

  it('escapes LIKE wildcards so they match literally', () => {
    expect(toLikePattern('50%')).toBe('%50\\%%');
    expect(toLikePattern('a_b')).toBe('%a\\_b%');
  });
});

describe('short codes', () => {
  it('uses an unambiguous alphabet', () => {
    for (let i = 0; i < 200; i += 1) {
      const code = generateShortCode('box');
      expect(code).toMatch(/^BOX-[2-9A-HJ-NP-Z]{4}$/);
      // O/0 and I/1 are excluded because codes get handwritten on labels.
      expect(code.slice(4)).not.toMatch(/[OI01]/);
    }
  });

  it('compares codes ignoring case and dashes', () => {
    expect(normalizeShortCode('box-7k2m')).toBe('BOX7K2M');
    expect(normalizeForCodeMatch('BOX-7K2M')).toBe('box7k2m');
  });
});
