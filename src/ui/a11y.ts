import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { strings } from '@/i18n/strings';

/**
 * Where something is, in the shape every location renderer needs. An
 * `ItemWithContext` already is one.
 */
export interface PlaceLike {
  containerId: string;
  containerName: string | null;
  containerShortCode: string;
  spaceId: string;
  spaceName: string;
  spaceColor: string;
}

/**
 * A container code spelled out for screen readers: 'DRW-7K2M' → 'D R W, 7 K 2 M'.
 *
 * Read as written, "DRW" comes out as "drew" and the code cannot be checked
 * against the label on the box.
 */
export function spellCode(code: string): string {
  return code
    .split('-')
    .map((group) => [...group.trim()].join(' '))
    .filter(Boolean)
    .join(', ');
}

/**
 * The spoken form of a location, for the label of whatever shows it:
 * "In Garage, Tool chest, label C A B, J 9 2 R", or for the drop zone
 * "In the drop zone, not filed yet" (never its internal code).
 */
export function whereSpoken(place: PlaceLike): string {
  if (place.containerId === DROP_ZONE_CONTAINER_ID) return strings.a11y.inDropZone;
  const spelled = spellCode(place.containerShortCode);
  return place.containerName
    ? strings.a11y.inPlace(place.spaceName, place.containerName, spelled)
    : strings.a11y.inSpace(place.spaceName, spelled);
}

/** "Quantity 12" or "None left". */
export function quantitySpoken(quantity: number): string {
  return quantity === 0 ? strings.rows.noneLeft : strings.rows.quantity(quantity);
}
