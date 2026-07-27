/**
 * Delimiter used by `GROUP_CONCAT(..., char(31))` when aggregating tag names
 * into a single column. U+001F (unit separator) is a control character, so it
 * can never appear inside a user-entered tag and cannot corrupt the split.
 */
export const TAG_DELIMITER = '';

/** SQL fragment producing the delimited tag list for one item. */
export const TAG_NAMES_SUBQUERY = `
  (SELECT GROUP_CONCAT(t.name, char(31))
     FROM item_tags it
     JOIN tags t ON t.id = it.tag_id
    WHERE it.item_id = i.id)
`;

export function splitTagNames(value: string | null): string[] {
  return value ? value.split(TAG_DELIMITER).filter(Boolean) : [];
}

/**
 * The holding area for things photographed before they have a home.
 *
 * A real row flagged `kind = 'system'` rather than a null container, so every
 * existing join and count keeps working; list queries filter it out by kind.
 */
export const DROP_ZONE_CONTAINER_ID = 'drop-zone';
export const DROP_ZONE_SPACE_ID = 'drop-zone-space';
