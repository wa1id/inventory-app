/**
 * English formatting rules that copy needs at runtime.
 *
 * Kept apart from `strings.ts` because a language is more than its strings:
 * plurals, list joining and relative times follow grammar, so adding a
 * language means a strings change plus a change here.
 */

/** `plural(3, 'item', 'items')` → "3 items". */
export function plural(count: number, one: string, other: string): string {
  return `${count} ${count === 1 ? one : other}`;
}

/** "a", "a and b", "a, b and c" (no serial comma, en-GB). */
export function sentenceList(parts: readonly string[]): string {
  if (parts.length <= 1) return parts[0] ?? '';
  return `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`;
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

function unitsAgo(count: number, unit: string): string {
  return `${count} ${unit}${count === 1 ? '' : 's'} ago`;
}

/**
 * How long ago, in words: "just now", "5 minutes ago", "yesterday", "2 months ago".
 *
 * Hand-written because Hermes does not guarantee `Intl.RelativeTimeFormat`.
 * A time in the future (clock skew between phones) reads as "just now".
 */
export function ago(ms: number, now: number = Date.now()): string {
  const diff = Math.max(0, now - ms);
  if (diff < MINUTE) return 'just now';
  if (diff < HOUR) return unitsAgo(Math.floor(diff / MINUTE), 'minute');
  if (diff < DAY) return unitsAgo(Math.floor(diff / HOUR), 'hour');
  if (diff < 2 * DAY) return 'yesterday';
  const days = Math.floor(diff / DAY);
  if (days < 30) return unitsAgo(days, 'day');
  if (days < 365) return unitsAgo(Math.floor(days / 30), 'month');
  return unitsAgo(Math.floor(days / 365), 'year');
}

const LONG_DATE = new Intl.DateTimeFormat('en-GB', {
  day: 'numeric',
  month: 'long',
  year: 'numeric',
});

/** "2 September 2026". */
export function longDate(ms: number): string {
  return LONG_DATE.format(ms);
}
