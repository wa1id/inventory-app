import type { ItemDraft, UpdateItemInput } from '@/repositories/items';
import type { RecognitionFailureReason, RecognitionResult } from '@/services/ai/contract';

export interface StoredPhoto {
  uri: string;
  thumbUri: string;
  width: number;
  height: number;
  byteSize: number | null;
}

export interface FastCaptureDeps {
  storePhoto: (uri: string) => Promise<StoredPhoto>;
  createItem: (draft: ItemDraft) => Promise<{ id: string; updatedAt?: number }>;
  updateItem: (id: string, input: UpdateItemInput) => Promise<unknown>;
  recognize: (uri: string) => Promise<RecognitionResult>;
}

export type FastCaptureOutcome =
  | { status: 'recognized'; itemId: string; name: string }
  | { status: 'unrecognized'; itemId: string; reason: RecognitionFailureReason };

export interface FastCaptureInput {
  containerId: string;
  photoUri: string;
  deps: FastCaptureDeps;
}

/**
 * Captures one item without interrupting the person holding the camera.
 *
 * The item is written to the database *before* recognition is attempted, which
 * is the whole point: the shutter can fire again immediately, and a crash or a
 * killed app mid-session loses nothing but a name. Recognition then enriches
 * the row in place.
 *
 * That ordering also means a failed recognition is not an error — it leaves a
 * real, photographed item that simply needs naming later, which is what issue
 * #26's capture-now-organize-later promise requires.
 *
 * The row is created with no name rather than an invented one. A placeholder
 * title would be indistinguishable from something the user wrote, and a screen
 * of identical "Unnamed item" rows tells them nothing about which is which —
 * an absent name is a fact the UI can present honestly and act on.
 *
 * Rejects only if the photo or the row could not be written; recognition
 * problems always resolve to an `unrecognized` outcome.
 */
export async function captureFastItem({
  containerId,
  photoUri,
  deps,
}: FastCaptureInput): Promise<FastCaptureOutcome> {
  const stored = await deps.storePhoto(photoUri);
  const item = await deps.createItem({
    containerId,
    // No name: recognition has not run yet, and inventing one would be a lie
    // the user then has to clear before typing the real thing.
    photo: {
      uri: stored.uri,
      thumbUri: stored.thumbUri,
      width: stored.width,
      height: stored.height,
      // The store reports an unknown size as null; the draft omits it instead.
      byteSize: stored.byteSize ?? undefined,
    },
  });

  let result: RecognitionResult;
  try {
    result = await deps.recognize(stored.uri);
  } catch {
    // `recognizeItem` is contractually total, but a dependency swapped in by a
    // caller need not be — never let that strand the placeholder name.
    result = { status: 'failed', reason: 'server_error' };
  }

  if (result.status !== 'success') {
    // Nothing to write: the row already reflects reality — a photographed item
    // that still needs a name.
    return { status: 'unrecognized', itemId: item.id, reason: result.reason };
  }

  const { suggestion } = result;
  const name = suggestion.name?.trim();

  if (!name) {
    // Recognition succeeded on everything but the name; keep the rest.
    await deps.updateItem(item.id, {
      category: suggestion.category,
      tags: suggestion.tags,
      expectedUpdatedAt: item.updatedAt,
    });
    return { status: 'unrecognized', itemId: item.id, reason: 'unrecognized' };
  }

  await deps.updateItem(item.id, {
    name,
    category: suggestion.category,
    tags: suggestion.tags,
    expectedUpdatedAt: item.updatedAt,
  });

  return { status: 'recognized', itemId: item.id, name };
}
