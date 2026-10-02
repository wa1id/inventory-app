import { compactAlphanumeric } from '@/core/tokenize';
import type { Container, Space } from '@/db/types';
import { strings } from '@/i18n/strings';

/** A container as the place picker offers it, joined with its space. */
export interface PlaceOption {
  id: string;
  name: string | null;
  shortCode: string;
  visualType: string;
  spaceId: string;
  spaceName: string;
  spaceColor: string;
  spaceIcon: string;
  itemCount: number;
}

/** What a container option can be found by. */
export interface PlaceMatchFields {
  name: string | null;
  shortCode: string;
  spaceName: string;
  visualType: string;
}

/**
 * Lower case with accents folded and everything but letters and digits (of
 * any script) removed, so "DRW-7K2M", "drw 7k2m" and "drw7k2m" are the same
 * text, and so are "Küche" and "kuche". The same folding as Home search.
 */
export const compact = compactAlphanumeric;

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

/** One container as the picker offers it; a space not (yet) known gives no colour or icon. */
export function toPlaceOption(
  container: Pick<Container, 'id' | 'name' | 'shortCode' | 'visualType' | 'spaceId'> & {
    spaceName: string;
    itemCount: number;
  },
  space: Pick<Space, 'color' | 'icon'> | undefined,
): PlaceOption {
  return {
    id: container.id,
    name: container.name,
    shortCode: container.shortCode,
    visualType: container.visualType,
    spaceId: container.spaceId,
    spaceName: container.spaceName,
    spaceColor: space?.color ?? '',
    spaceIcon: space?.icon ?? '',
    itemCount: container.itemCount,
  };
}

/** Containers joined with their spaces, as the place picker offers them. */
export function joinPlaceOptions(
  containers: readonly (Container & { spaceName: string; itemCount: number })[],
  spaces: readonly Pick<Space, 'id' | 'color' | 'icon'>[],
): PlaceOption[] {
  const spaceById = new Map(spaces.map((entry) => [entry.id, entry]));
  return containers.map((container) => toPlaceOption(container, spaceById.get(container.spaceId)));
}
