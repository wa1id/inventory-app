import { strings } from '@/i18n/strings';

/** What a container option can be found by. */
export interface PlaceMatchFields {
  name: string | null;
  shortCode: string;
  spaceName: string;
  visualType: string;
}

/**
 * Lower case with everything but letters and digits removed, so "DRW-7K2M",
 * "drw 7k2m" and "drw7k2m" are the same text (desk `compact`).
 */
export function compact(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '');
}

/** The typed filter as compacted terms; blank terms (stray punctuation) are dropped. */
export function placeTerms(query: string): string[] {
  return query
    .split(/\s+/)
    .map(compact)
    .filter((term) => term.length > 0);
}

/**
 * Whether a container option matches every term of the filter.
 *
 * Each term is looked for in the name, the label code, the space and the type
 * name run together, so "drw7k" finds DRW-7K2M and "garage drill" finds the
 * drill box in the garage. Pure, so it is tested in Node.
 */
export function matchesPlace(option: PlaceMatchFields, terms: readonly string[]): boolean {
  if (terms.length === 0) return true;
  const typeName = strings.entities.typeNames[option.visualType] ?? '';
  const haystack = compact(
    `${option.name ?? ''} ${option.shortCode} ${option.spaceName} ${typeName}`,
  );
  return terms.every((term) => haystack.includes(term));
}

/** The options that match `query`, in their original order. */
export function filterPlaces<T extends PlaceMatchFields>(
  options: readonly T[],
  query: string,
): T[] {
  const terms = placeTerms(query);
  return options.filter((option) => matchesPlace(option, terms));
}
