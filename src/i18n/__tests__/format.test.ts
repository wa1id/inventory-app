import { ago, longDate, plural, sentenceList } from '@/i18n/format';

describe('plural', () => {
  it('picks the form by count', () => {
    expect(plural(1, 'item', 'items')).toBe('1 item');
    expect(plural(0, 'item', 'items')).toBe('0 items');
    expect(plural(3, 'item', 'items')).toBe('3 items');
  });
});

describe('sentenceList', () => {
  it('joins like a sentence, without a serial comma', () => {
    expect(sentenceList([])).toBe('');
    expect(sentenceList(['a'])).toBe('a');
    expect(sentenceList(['a', 'b'])).toBe('a and b');
    expect(sentenceList(['a', 'b', 'c'])).toBe('a, b and c');
  });
});

describe('ago', () => {
  const now = Date.UTC(2026, 9, 2, 12);
  const minute = 60_000;
  const hour = 60 * minute;
  const day = 24 * hour;

  it.each([
    [0, 'just now'],
    [59_000, 'just now'],
    [minute, '1 minute ago'],
    [5 * minute, '5 minutes ago'],
    [hour, '1 hour ago'],
    [3 * hour, '3 hours ago'],
    [day, 'yesterday'],
    [47 * hour, 'yesterday'],
    [2 * day, '2 days ago'],
    [29 * day, '29 days ago'],
    [30 * day, '1 month ago'],
    [64 * day, '2 months ago'],
    [365 * day, '1 year ago'],
    [800 * day, '2 years ago'],
  ])('%p ms ago reads %p', (elapsed, expected) => {
    expect(ago(now - elapsed, now)).toBe(expected);
  });

  it('reads a time from a phone with a fast clock as just now', () => {
    expect(ago(now + 5 * minute, now)).toBe('just now');
  });
});

describe('longDate', () => {
  it('formats en-GB with the month spelled out', () => {
    expect(longDate(Date.UTC(2026, 8, 2, 12))).toBe('2 September 2026');
  });
});
