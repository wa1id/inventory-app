/**
 * Upper bound on query terms. Each term adds a set of OR'd LIKE comparisons to
 * the search SQL, so an absurdly long query cannot degrade into a slow scan.
 */
const MAX_TERMS = 12;

/** Combining diacritical marks, stripped so "cafe" matches "café". */
const COMBINING_MARKS = /[̀-ͯ]/g;

/**
 * Splits a raw search query into normalized, deduplicated terms.
 *
 * Terms are lowercased for case-insensitive matching and split on anything that
 * is not a letter, digit, or dash. Dashes survive tokenization because they
 * appear inside container short codes (`BOX-7K2M`); short-code matching then
 * strips them separately, so both `box-7k2m` and `box7k2m` find the container.
 */
export function tokenizeQuery(query: string): string[] {
  if (!query) return [];

  const terms = query
    .toLowerCase()
    .normalize('NFKD')
    .replace(COMBINING_MARKS, '')
    .split(/[^\p{Letter}\p{Number}-]+/u)
    .map((term) => term.replace(/^-+|-+$/g, ''))
    .filter((term) => term.length > 0);

  const unique: string[] = [];
  for (const term of terms) {
    if (!unique.includes(term)) unique.push(term);
    if (unique.length >= MAX_TERMS) break;
  }

  return unique;
}

/** Escapes LIKE wildcards so a literal `%` or `_` cannot widen a query. */
export function toLikePattern(term: string): string {
  const escaped = term.replace(/[\\%_]/g, (match) => `\\${match}`);
  return `%${escaped}%`;
}

/** Normalizes text the way container short codes are compared. */
export function normalizeForCodeMatch(value: string): string {
  return value.toLowerCase().replace(/[\s-]+/g, '');
}
