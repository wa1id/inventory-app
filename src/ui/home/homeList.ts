import type { ItemWithContext } from '@/db/types';
import { strings } from '@/i18n/strings';
import type { ItemSearchResult, LocationSearchResult, SearchResults } from '@/repositories/search';

/*
 * What Home's one list shows, worked out without React Native so it can be
 * tested in Node. The screen renders each entry; the order, the sections and
 * which rows share a bordered sheet are decided here.
 */

/** Where a row sits in its bordered sheet (`sheetCell(index, count)`). */
export interface SheetPosition {
  index: number;
  count: number;
}

/** "Do we still have it?" for a name kept in more than one place. */
export interface NameTotal {
  /** The name as the first matching item spells it. */
  name: string;
  /** Added up over every item with that name. */
  quantity: number;
  /** Different containers those items are in. */
  places: number;
}

/** What stands in for a list that cannot be shown. */
export type HomeStatus = 'loading' | 'error' | 'empty' | 'searching' | 'searchFailed' | 'noResults';

export type HomeEntry =
  | { kind: 'field'; key: 'field' }
  | { kind: 'notice'; key: 'notice' }
  | { kind: 'refreshFailed'; key: 'refresh-failed' }
  | { kind: 'dropZone'; key: 'drop-zone' }
  | { kind: 'summary'; key: 'summary'; text: string }
  | { kind: 'title'; key: string; title: string; count: number; first: boolean }
  | { kind: 'totals'; key: 'totals'; totals: NameTotal[] }
  | { kind: 'item'; key: string; item: ItemWithContext; position: SheetPosition }
  | { kind: 'place'; key: string; hit: LocationSearchResult; position: SheetPosition }
  | { kind: 'more'; key: 'recent-more' }
  | { kind: 'status'; key: 'status'; status: HomeStatus };

/** The search field: always the first entry, and the list's one sticky row. */
export const FIELD_ENTRY: HomeEntry = { kind: 'field', key: 'field' };

/** How many recent items Home asks for first, and after "Show more" (§7.5 R9). */
export const RECENT_FIRST = 12;
export const RECENT_MORE = 40;

/**
 * The household at a glance: "5 spaces, 13 containers and 45 items."
 *
 * Space counts leave out the drop zone (a system space), so its items are
 * added on top; its container is not counted, as on the desk.
 */
export function householdCounts(
  spaces: readonly { containerCount: number; itemCount: number }[],
  dropZoneCount: number,
): { spaces: number; containers: number; items: number } {
  let containers = 0;
  let items = dropZoneCount;
  for (const space of spaces) {
    containers += space.containerCount;
    items += space.itemCount;
  }
  return { spaces: spaces.length, containers, items };
}

/**
 * One total per name that is kept in two or more containers: the answer to
 * "do we still have AA batteries?" when they sit in two boxes. Names match
 * trimmed and case-insensitively; unnamed items are never totalled. Two items
 * of the same name in one container add nothing the rows do not already say,
 * and "in 1 places" would read wrong, so they need a second container.
 */
export function nameTotals(
  items: readonly Pick<ItemWithContext, 'name' | 'quantity' | 'containerId'>[],
): NameTotal[] {
  const groups = new Map<string, { name: string; quantity: number; containers: Set<string> }>();
  for (const item of items) {
    const name = item.name.trim();
    if (!name) continue;
    const key = name.toLowerCase();
    const group = groups.get(key);
    if (group) {
      group.quantity += item.quantity;
      group.containers.add(item.containerId);
    } else {
      groups.set(key, { name, quantity: item.quantity, containers: new Set([item.containerId]) });
    }
  }
  return [...groups.values()]
    .filter((group) => group.containers.size > 1)
    .map((group) => ({
      name: group.name,
      quantity: group.quantity,
      places: group.containers.size,
    }));
}

function itemEntries(
  items: readonly ItemWithContext[],
  keyPrefix: string,
): Extract<HomeEntry, { kind: 'item' }>[] {
  return items.map((item, index) => ({
    kind: 'item',
    key: `${keyPrefix}-${item.id}`,
    item,
    position: { index, count: items.length },
  }));
}

export type IdleBody =
  | { kind: 'list'; recent: readonly ItemWithContext[]; canShowMore: boolean }
  | { kind: 'status'; status: 'loading' | 'error' | 'empty' };

export interface IdleInput {
  /** The "This phone keeps its own inventory" notice. */
  notice: boolean;
  /** A refresh failed for a reason the connection banner does not explain. */
  refreshFailed: boolean;
  dropZoneCount: number;
  body: IdleBody;
}

/**
 * Home with nothing typed: the unpaired notice, the drop-zone card, then
 * Recently added (drop-zone items included, so "somewhere" adds show up).
 */
export function idleEntries({
  notice,
  refreshFailed,
  dropZoneCount,
  body,
}: IdleInput): HomeEntry[] {
  const entries: HomeEntry[] = [];
  if (refreshFailed) entries.push({ kind: 'refreshFailed', key: 'refresh-failed' });
  if (notice) entries.push({ kind: 'notice', key: 'notice' });
  if (dropZoneCount > 0) entries.push({ kind: 'dropZone', key: 'drop-zone' });

  if (body.kind === 'status') {
    entries.push({ kind: 'status', key: 'status', status: body.status });
    return entries;
  }
  // No items at all is the empty state's job; an empty section says nothing.
  if (body.recent.length === 0) return entries;

  entries.push({
    kind: 'title',
    key: 'title-recent',
    title: strings.home.recent,
    count: body.recent.length,
    first: entries.length === 0,
  });
  entries.push(...itemEntries(body.recent, 'recent'));
  if (body.canShowMore) entries.push({ kind: 'more', key: 'recent-more' });
  return entries;
}

/** Item hits split into the item's own matches and those matched by where they are. */
export function splitMatches(items: readonly ItemSearchResult[]): {
  direct: ItemSearchResult[];
  location: ItemSearchResult[];
} {
  return {
    direct: items.filter((item) => item.matchKind === 'direct'),
    location: items.filter((item) => item.matchKind === 'location'),
  };
}

/**
 * Search results in the desk's order, because the item is the answer: the
 * items that matched, then the spaces and containers that matched, then the
 * items kept in those places (#14).
 */
export function resultEntries(results: SearchResults, refreshFailed: boolean): HomeEntry[] {
  const { direct, location } = splitMatches(results.items);
  const places = results.locations;

  if (direct.length + location.length + places.length === 0) {
    return [{ kind: 'status', key: 'status', status: 'noResults' }];
  }

  const entries: HomeEntry[] = [];
  if (refreshFailed) entries.push({ kind: 'refreshFailed', key: 'refresh-failed' });
  entries.push({
    kind: 'summary',
    key: 'summary',
    text: strings.search.summary(results.items.length, places.length),
  });

  let first = true;
  if (direct.length > 0) {
    entries.push({
      kind: 'title',
      key: 'title-items',
      title: strings.search.items,
      count: direct.length,
      first,
    });
    first = false;
    const totals = nameTotals(direct);
    if (totals.length > 0) entries.push({ kind: 'totals', key: 'totals', totals });
    entries.push(...itemEntries(direct, 'item'));
  }
  if (places.length > 0) {
    entries.push({
      kind: 'title',
      key: 'title-places',
      title: strings.search.places,
      count: places.length,
      first,
    });
    first = false;
    entries.push(
      ...places.map((hit, index): HomeEntry => ({
        kind: 'place',
        key: `place-${hit.kind}-${hit.id}`,
        hit,
        position: { index, count: places.length },
      })),
    );
  }
  if (location.length > 0) {
    entries.push({
      kind: 'title',
      key: 'title-kept',
      title: strings.search.keptInThose,
      count: location.length,
      first,
    });
    entries.push(...itemEntries(location, 'kept'));
  }
  return entries;
}
