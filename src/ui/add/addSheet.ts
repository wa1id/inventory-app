import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { Container, Space } from '@/db/types';
import { strings } from '@/i18n/strings';
import type { StoredImage } from '@/services/capture/imageStore';
import { spellCode } from '@/ui/a11y';
import type { ItemFormValues } from '@/ui/components/ItemForm';
import type { PlaceOption } from '@/ui/components/PlacePicker';
import type { SuggestionState } from '@/ui/components/SuggestionBanner';

/*
 * The Add sheet's logic that needs no screen (spec §5.9): where its state
 * starts, which places it offers, and how it names the place it saves to.
 * Pure, so it is tested in Node.
 */

/** The photo of the item being added: already stored on this phone, not yet anyone's. */
export interface AddPhoto {
  uri: string;
  thumbUri?: string;
  width?: number;
  height?: number;
  byteSize?: number;
}

/** `/item/new` route params, all optional (spec §5.9 entry points). */
export interface AddParams {
  containerId?: string;
  name?: string;
  photoUri?: string;
  photoThumbUri?: string;
  photoWidth?: string;
  photoHeight?: string;
  photoBytes?: string;
}

/** Route params arrive as strings; anything unusable becomes undefined. */
export function toPositiveInt(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

/** The photo single-mode capture stored before opening the sheet (params unchanged). */
export function photoFromParams(params: AddParams): AddPhoto | null {
  if (!params.photoUri) return null;
  return {
    uri: params.photoUri,
    thumbUri: params.photoThumbUri || undefined,
    width: toPositiveInt(params.photoWidth),
    height: toPositiveInt(params.photoHeight),
    byteSize: toPositiveInt(params.photoBytes),
  };
}

/** The photo the camera handed back through `openForResult`. */
export function photoFromStored(stored: StoredImage): AddPhoto {
  return {
    uri: stored.uri,
    thumbUri: stored.thumbUri,
    width: stored.width,
    height: stored.height,
    byteSize: stored.byteSize ?? undefined,
  };
}

/**
 * Both files of a photo. Removing only `uri` left every thumbnail behind
 * (entities §15.6).
 */
export function photoFiles(photo: AddPhoto | null): (string | null)[] {
  return photo ? [photo.uri, photo.thumbUri ?? null] : [];
}

/** Whether Category, Tags or Notes hold anything (they open "More details"). */
export function hasDetails(values: ItemFormValues): boolean {
  return [values.category, values.tags, values.notes].some((value) => value.trim() !== '');
}

/**
 * Whether the sheet holds anything worth keeping or asking about: typing,
 * a quantity other than the default, or a photo. The place alone is not:
 * picking one and closing loses nothing.
 */
export function formHasContent(
  values: ItemFormValues,
  photo: AddPhoto | null,
  empty: ItemFormValues,
): boolean {
  return (
    photo !== null ||
    values.name.trim() !== '' ||
    hasDetails(values) ||
    values.quantity.trim() !== empty.quantity
  );
}

/** A draft as the sheet restores it (`addDraft.ts` keeps it between openings). */
export interface AddDraftState {
  values: ItemFormValues;
  /** `DROP_ZONE_CONTAINER_ID` for the drop zone. */
  placeId: string;
  /** The container picked in the place step, for when it is not in the sheet's own list. */
  picked: PlaceOption | null;
  photo: AddPhoto | null;
  suggestion: SuggestionState;
  showMore: boolean;
}

export interface AddInitialState extends AddDraftState {
  /** The state came from a draft: say so, and offer to clear it. */
  restored: boolean;
  /** Recognition has to be started on arrival (a fresh photo, or one cut off). */
  recognize: boolean;
}

/**
 * Where the sheet starts. Params win: a container, a name from search or a
 * photo from the camera each mean a new item. Only a plain open (the tab
 * bar's Add) restores a draft; one cut off while recognising starts again.
 */
export function initialAddState(
  params: AddParams,
  draft: AddDraftState | null,
  empty: ItemFormValues,
): AddInitialState {
  const opened = Boolean(params.containerId || params.name || params.photoUri);

  if (!opened && draft) {
    const cutOff =
      draft.suggestion.status === 'running' || draft.suggestion.status === 'refreshing';
    const recognize = cutOff && draft.photo !== null;
    return {
      ...draft,
      suggestion: recognize
        ? { status: 'running' }
        : cutOff
          ? { status: 'idle' }
          : draft.suggestion,
      restored: true,
      recognize,
    };
  }

  const photo = photoFromParams(params);
  return {
    values: { ...empty, name: params.name?.trim() ?? '' },
    placeId: params.containerId || DROP_ZONE_CONTAINER_ID,
    picked: null,
    photo,
    suggestion: photo ? { status: 'running' } : { status: 'idle' },
    showMore: false,
    restored: false,
    recognize: photo !== null,
  };
}

/** Containers joined with their spaces, as the place picker offers them. */
export function joinPlaceOptions(
  containers: readonly (Container & { spaceName: string; itemCount: number })[],
  spaces: readonly Pick<Space, 'id' | 'color' | 'icon'>[],
): PlaceOption[] {
  const spaceById = new Map(spaces.map((entry) => [entry.id, entry]));
  return containers.map((container) => ({
    id: container.id,
    name: container.name,
    shortCode: container.shortCode,
    visualType: container.visualType,
    spaceId: container.spaceId,
    spaceName: container.spaceName,
    spaceColor: spaceById.get(container.spaceId)?.color ?? '',
    spaceIcon: spaceById.get(container.spaceId)?.icon ?? '',
    itemCount: container.itemCount,
  }));
}

/** Recent places shown under "Where it goes"; the picker shows more. */
export const MAX_RECENT_WHERE = 3;

export type WhereEntry =
  | { kind: 'dropZone' }
  | { kind: 'container'; option: PlaceOption; source: 'param' | 'recent' | 'picked' };

export interface WhereInput {
  /** The container the sheet was opened for, once its details are known. */
  param: PlaceOption | null;
  recentIds: readonly string[];
  options: ReadonlyMap<string, PlaceOption>;
  /** The place the item will be saved in. */
  selectedId: string;
  /** The last container picked in the place step (it may be newer than `options`). */
  picked: PlaceOption | null;
  maxRecent?: number;
}

/**
 * The short list under "Where it goes": the container the sheet was opened
 * for, the drop zone, then this phone's recent places that still exist. A
 * place picked from the full list that is not among them goes on top and
 * stays there, so what is selected is always visible.
 */
export function whereEntries({
  param,
  recentIds,
  options,
  selectedId,
  picked,
  maxRecent = MAX_RECENT_WHERE,
}: WhereInput): WhereEntry[] {
  const entries: WhereEntry[] = [];
  if (param) entries.push({ kind: 'container', option: param, source: 'param' });
  entries.push({ kind: 'dropZone' });

  let recent = 0;
  for (const id of recentIds) {
    if (recent >= maxRecent) break;
    if (id === param?.id || id === DROP_ZONE_CONTAINER_ID) continue;
    const option = options.get(id);
    if (!option) continue;
    entries.push({ kind: 'container', option, source: 'recent' });
    recent += 1;
  }

  // The selected place first, then one picked earlier and since swapped for
  // another, so a choice does not vanish from under the finger.
  const listed = new Set(entries.map(entryId));
  const extras: PlaceOption[] = [];
  const selected =
    selectedId === DROP_ZONE_CONTAINER_ID
      ? null
      : (options.get(selectedId) ?? (picked?.id === selectedId ? picked : null));
  if (selected && !listed.has(selected.id)) extras.push(selected);
  if (picked && !listed.has(picked.id) && picked.id !== selected?.id) {
    extras.push(options.get(picked.id) ?? picked);
  }
  entries.unshift(
    ...extras.map((option): WhereEntry => ({ kind: 'container', option, source: 'picked' })),
  );
  return entries;
}

/** The container id an entry saves to. */
export function entryId(entry: WhereEntry): string {
  return entry.kind === 'dropZone' ? DROP_ZONE_CONTAINER_ID : entry.option.id;
}

export interface ResolvedPlace {
  /** Where the item is saved. */
  id: string;
  /** Its details, or null for the drop zone and while they load. */
  option: PlaceOption | null;
}

/**
 * The place a save goes to. A container that the loaded list says no longer
 * exists (deleted on another phone) falls back to the drop zone, which the
 * sheet then shows as selected: what is on screen is where it goes.
 */
export function resolvePlace(
  selectedId: string,
  options: ReadonlyMap<string, PlaceOption> | null,
  picked: PlaceOption | null,
): ResolvedPlace {
  if (selectedId === DROP_ZONE_CONTAINER_ID) return { id: selectedId, option: null };
  const option = options?.get(selectedId) ?? (picked?.id === selectedId ? picked : null);
  if (option) return { id: selectedId, option };
  // Not loaded yet (or the list failed): keep the id, the save still knows where.
  if (!options) return { id: selectedId, option: null };
  return { id: DROP_ZONE_CONTAINER_ID, option: null };
}

/** A container as written on screen: its name, or the code on its label. */
export function containerTitle(option: Pick<PlaceOption, 'name' | 'shortCode'>): string {
  return option.name ?? option.shortCode;
}

/** The primary button's spoken label names where the item will go. */
export function saveA11yLabel(place: ResolvedPlace): string {
  if (place.id === DROP_ZONE_CONTAINER_ID) return strings.add.saveA11yDropZone;
  if (!place.option) return strings.add.save;
  const container = place.option.name ?? strings.a11y.labelCode(spellCode(place.option.shortCode));
  return strings.add.saveA11y(container, place.option.spaceName);
}

/** The toast after a save: "Saved in Drawer by the oven (Kitchen)." */
export function savedMessage(place: ResolvedPlace): string {
  if (place.id === DROP_ZONE_CONTAINER_ID) return strings.add.savedInDropZone;
  if (!place.option) return strings.add.saved;
  return strings.add.savedIn(containerTitle(place.option), place.option.spaceName);
}
