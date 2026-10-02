import { deleteStoredPhotos } from '@/services/capture/imageStore';
import { photoFiles, type AddDraftState } from '@/ui/add/addSheet';

/**
 * What the Add sheet held when it was swiped away (spec §5.9 "Drafts").
 *
 * One draft, in memory: a sheet closed by a swipe or Back keeps what was
 * typed, the place and the photo, and the next plain open of Add within half
 * an hour brings them back. Only the header's Cancel throws a draft away (after
 * asking). The draft also owns its photo until the item is saved, so a photo
 * taken for an item nobody saved is deleted rather than left on the phone
 * (entities §15.6, capture §13.8). Lost when the app restarts, which is fine
 * for half an hour's typing.
 */

export interface AddDraft extends AddDraftState {
  savedAt: number;
}

/** A draft older than this is thrown away on the next open, photo and all. */
export const DRAFT_TTL_MS = 30 * 60 * 1000;

/** `owner` is the sheet that last wrote it: only that sheet may clear it. */
let slot: { owner: string; draft: AddDraft } | null = null;

export function isDraftFresh(draft: AddDraft, now: number): boolean {
  return now - draft.savedAt <= DRAFT_TTL_MS;
}

/**
 * The draft a plain open of Add restores, if it is fresh. No side effects,
 * so a sheet can read it while rendering its first frame.
 */
export function restorableDraft(now: number): AddDraft | null {
  return slot && isDraftFresh(slot.draft, now) ? slot.draft : null;
}

/** Throws away a draft older than half an hour, and its photo. */
export function discardStaleDraft(now: number): void {
  if (!slot || isDraftFresh(slot.draft, now)) return;
  deleteStoredPhotos(photoFiles(slot.draft.photo));
  slot = null;
}

/**
 * Keeps what `owner` holds now as the draft, replacing any other. A replaced
 * draft's photo is deleted unless the new draft carries the same one (a
 * restored draft keeps its photo). `null`, when the sheet holds nothing worth
 * keeping, clears the draft only if this sheet wrote it, so opening Add for a
 * container and closing it straight away leaves an earlier draft alone.
 */
export function keepDraft(owner: string, draft: AddDraft | null): void {
  if (!draft) {
    if (slot?.owner === owner) slot = null;
    return;
  }
  if (slot && slot.draft.photo?.uri !== draft.photo?.uri) {
    deleteStoredPhotos(photoFiles(slot.draft.photo));
  }
  slot = { owner, draft };
}

/**
 * Forgets this sheet's draft without touching its photo: after a save the
 * item owns the photo, and after a discard the sheet has deleted it itself.
 */
export function clearDraft(owner: string): void {
  if (slot?.owner === owner) slot = null;
}
