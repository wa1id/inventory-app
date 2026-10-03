import { formatCode, invalidCodeChars, normaliseCode } from '@/ui/code';

describe('normaliseCode', () => {
  it('drops spaces and hyphens and upper-cases', () => {
    expect(normaliseCode(' mmwky-m2h78 ')).toBe('MMWKYM2H78');
    expect(normaliseCode('mmwky\nm2h78\t')).toBe('MMWKYM2H78');
  });

  it('folds the look-alikes the way the server decodes them', () => {
    expect(normaliseCode('il0o')).toBe('1100');
    expect(normaliseCode('ILO')).toBe('110');
  });
});

describe('invalidCodeChars', () => {
  it('reports characters Crockford base32 never uses, once each', () => {
    expect(invalidCodeChars('U')).toEqual(['U']);
    expect(invalidCodeChars('ABUU!')).toEqual(['U', '!']);
    expect(invalidCodeChars(normaliseCode('MMWKY-M2H78'))).toEqual([]);
  });
});

describe('formatCode', () => {
  it('groups in fives', () => {
    expect(formatCode('')).toBe('');
    expect(formatCode('MMWKY')).toBe('MMWKY');
    expect(formatCode('MMWKYM2H78A')).toBe('MMWKY-M2H78-A');
  });
});
