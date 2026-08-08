import { normalizeForCodeMatch, toLikePattern, tokenizeQuery } from '@/core/tokenize';
import { DROP_ZONE_CONTAINER_ID, splitTagNames } from '@/db/constants';
import type { ItemWithContext, SqlDatabase, SqlParams } from '@/db/types';

/**
 * Why an item showed up in results.
 *
 * `location` means the item itself matched nothing — the query matched its
 * space or container — so the UI can label it rather than look like a bad hit.
 */
export type ItemMatchKind = 'direct' | 'location';

export interface ItemSearchResult extends ItemWithContext {
  matchKind: ItemMatchKind;
}

export interface LocationSearchResult {
  kind: 'space' | 'container';
  id: string;
  title: string;
  subtitle: string;
  spaceId: string;
  itemCount: number;
}

export interface SearchResults {
  terms: string[];
  locations: LocationSearchResult[];
  items: ItemSearchResult[];
}

/** Caps result size so a one-letter query cannot try to render 10k rows. */
const ITEM_RESULT_LIMIT = 200;
const LOCATION_RESULT_LIMIT = 30;

/**
 * Conditions that make a term match the item's *own* fields (name, category,
 * tags) as opposed to its location.
 */
function itemFieldCondition(): string {
  return `(
    i.search_text LIKE ? ESCAPE '\\'
    OR EXISTS (
      SELECT 1 FROM item_tags it
        JOIN tags t ON t.id = it.tag_id
       WHERE it.item_id = i.id AND t.normalized_name LIKE ? ESCAPE '\\'
    )
  )`;
}

function locationFieldCondition(): string {
  return `(
    LOWER(s.name) LIKE ? ESCAPE '\\'
    OR LOWER(COALESCE(c.name, '')) LIKE ? ESCAPE '\\'
    OR REPLACE(LOWER(c.short_code), '-', '') LIKE ? ESCAPE '\\'
  )`;
}

export function createSearchRepository(db: SqlDatabase) {
  return {
    /**
     * Keyword search across the local inventory.
     *
     * All terms must match (AND), but each term may match through the item or
     * through its location, which is what makes "kitchen screwdriver" find a
     * screwdriver stored in the Kitchen space.
     */
    async search(rawQuery: string): Promise<SearchResults> {
      const terms = tokenizeQuery(rawQuery);
      if (terms.length === 0) {
        return { terms, locations: [], items: [] };
      }

      const itemWhere: string[] = [];
      const itemParams: SqlParams = [];
      const directParams: SqlParams = [];

      for (const term of terms) {
        const like = toLikePattern(term);
        const codeLike = toLikePattern(normalizeForCodeMatch(term));

        itemWhere.push(`(${itemFieldCondition()} OR ${locationFieldCondition()})`);
        itemParams.push(like, like, like, like, codeLike);
        directParams.push(like, like);
      }

      // `direct_match` is 1 only when every term matched the item's own fields.
      const directExpr = terms.map(() => itemFieldCondition()).join(' AND ');

      const itemRows = await db.getAllAsync<ItemSearchRow>(
        `SELECT i.*,
                (SELECT p.uri FROM item_photos p WHERE p.item_id = i.id
                  ORDER BY p.created_at ASC LIMIT 1) AS photo_uri,
                (SELECT p.thumb_uri FROM item_photos p WHERE p.item_id = i.id
                  ORDER BY p.created_at ASC LIMIT 1) AS photo_thumb_uri,
                (SELECT GROUP_CONCAT(t.name, char(31)) FROM item_tags it
                   JOIN tags t ON t.id = it.tag_id WHERE it.item_id = i.id) AS tag_names,
                c.space_id AS space_id,
                s.name AS space_name,
                s.icon AS space_icon,
                s.color AS space_color,
                c.name AS container_name,
                c.short_code AS container_short_code,
                CASE WHEN ${directExpr} THEN 1 ELSE 0 END AS direct_match
           FROM items i
           JOIN containers c ON c.id = i.container_id
           JOIN spaces s ON s.id = c.space_id
          WHERE ${itemWhere.join(' AND ')}
          ORDER BY direct_match DESC, i.name COLLATE NOCASE ASC
          LIMIT ${ITEM_RESULT_LIMIT}`,
        [...directParams, ...itemParams],
      );

      const [spaceRows, containerRows] = await Promise.all([
        this.searchSpaces(terms),
        this.searchContainers(terms),
      ]);

      return {
        terms,
        locations: [...spaceRows, ...containerRows].slice(0, LOCATION_RESULT_LIMIT),
        items: itemRows.map(toItemSearchResult),
      };
    },

    async searchSpaces(terms: string[]): Promise<LocationSearchResult[]> {
      const where: string[] = [];
      const params: SqlParams = [];

      for (const term of terms) {
        where.push(`LOWER(s.name) LIKE ? ESCAPE '\\'`);
        params.push(toLikePattern(term));
      }

      const rows = await db.getAllAsync<{
        id: string;
        name: string;
        container_count: number;
        item_count: number;
      }>(
        `SELECT s.id, s.name,
                (SELECT COUNT(*) FROM containers c WHERE c.space_id = s.id) AS container_count,
                (SELECT COUNT(*) FROM items i JOIN containers c ON c.id = i.container_id
                  WHERE c.space_id = s.id) AS item_count
           FROM spaces s
          WHERE s.kind = 'normal' AND ${where.join(' AND ')}
          ORDER BY s.name COLLATE NOCASE ASC
          LIMIT ${LOCATION_RESULT_LIMIT}`,
        params,
      );

      return rows.map((row) => ({
        kind: 'space' as const,
        id: row.id,
        title: row.name,
        subtitle: `${row.container_count} container${row.container_count === 1 ? '' : 's'} · ${
          row.item_count
        } item${row.item_count === 1 ? '' : 's'}`,
        spaceId: row.id,
        itemCount: row.item_count,
      }));
    },

    async searchContainers(terms: string[]): Promise<LocationSearchResult[]> {
      const where: string[] = [];
      const params: SqlParams = [];

      for (const term of terms) {
        where.push(
          `(LOWER(COALESCE(c.name, '')) LIKE ? ESCAPE '\\'
            OR REPLACE(LOWER(c.short_code), '-', '') LIKE ? ESCAPE '\\')`,
        );
        params.push(toLikePattern(term), toLikePattern(normalizeForCodeMatch(term)));
      }

      const rows = await db.getAllAsync<{
        id: string;
        name: string | null;
        short_code: string;
        space_id: string;
        space_name: string;
        item_count: number;
      }>(
        `SELECT c.id, c.name, c.short_code, c.space_id, s.name AS space_name,
                (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count
           FROM containers c
           JOIN spaces s ON s.id = c.space_id
          WHERE c.kind = 'normal' AND ${where.join(' AND ')}
          ORDER BY s.name COLLATE NOCASE ASC, c.short_code ASC
          LIMIT ${LOCATION_RESULT_LIMIT}`,
        params,
      );

      return rows.map((row) => ({
        kind: 'container' as const,
        id: row.id,
        title: row.name ?? row.short_code,
        subtitle: `${row.space_name} · ${row.short_code} · ${row.item_count} item${
          row.item_count === 1 ? '' : 's'
        }`,
        spaceId: row.space_id,
        itemCount: row.item_count,
      }));
    },
  };
}

interface ItemSearchRow {
  id: string;
  container_id: string;
  name: string;
  category: string | null;
  quantity: number;
  notes: string | null;
  created_at: number;
  updated_at: number;
  photo_uri: string | null;
  photo_thumb_uri: string | null;
  tag_names: string | null;
  space_id: string;
  space_name: string;
  space_icon: string;
  space_color: string;
  container_name: string | null;
  container_short_code: string;
  direct_match: number;
}

function toItemSearchResult(row: ItemSearchRow): ItemSearchResult {
  return {
    id: row.id,
    containerId: row.container_id,
    name: row.name,
    category: row.category,
    quantity: row.quantity,
    notes: row.notes,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    photoUri: row.photo_uri,
    photoThumbUri: row.photo_thumb_uri,
    tags: splitTagNames(row.tag_names),
    spaceId: row.space_id,
    spaceName: row.space_name,
    spaceIcon: row.space_icon,
    spaceColor: row.space_color,
    containerName: row.container_name,
    containerShortCode: row.container_short_code,
    matchKind: row.direct_match === 1 ? 'direct' : 'location',
  };
}

/** `Space > Container` path shown on every item result. */
export function formatLocationPath(item: ItemWithContext): string {
  // The drop zone is a single holding area, not a space containing a container
  // that happens to share its name.
  if (item.containerId === DROP_ZONE_CONTAINER_ID) return item.spaceName;
  return `${item.spaceName} > ${item.containerName ?? item.containerShortCode}`;
}

export type SearchRepository = ReturnType<typeof createSearchRepository>;
