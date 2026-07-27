import type { ItemDraft, UpdateItemInput } from '@/repositories/items';
import type { RecognitionFailureReason, RecognitionResult } from '@/services/ai/contract';

export interface StoredPhoto {
  uri: string;
  width: number;
  height: number;
  byteSize: number | null;
}

export interface FastCaptureDeps {
  storePhoto: (uri: string) => Promise<StoredPhoto>;
  createItem: (draft: ItemDraft) => Promise<{ id: string }>;
  updateItem: (id: string, input: UpdateItemInput) => Promise<unknown>;
  recognize: (uri: string) => Promise<RecognitionResult>;
}

export interface FastCaptureNames {
  /** Stands in while recognition is still running. */
  pending: string;
  /** Replaces the placeholder when recognition gives us nothing usable. */
  fallback: string;
}

export type FastCaptureOutcome =
  | { status: 'recognized'; itemId: string; name: string }
  | { status: 'unrecognized'; itemId: string; reason: RecognitionFailureReason };

export interface FastCaptureInput {
  containerId: string;
  photoUri: string;
  deps: FastCaptureDeps;
  names: FastCaptureNames;
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
 * Rejects only if the photo or the row could not be written; recognition
 * problems always resolve to an `unrecognized` outcome.
 */
export async function captureFastItem({
  containerId,
  photoUri,
  deps,
  names,
}: FastCaptureInput): Promise<FastCaptureOutcome> {
  const stored = await deps.storePhoto(photoUri);
  const item = await deps.createItem({
    containerId,
    name: names.pending,
    photo: {
      uri: stored.uri,
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
    await deps.updateItem(item.id, { name: names.fallback });
    return { status: 'unrecognized', itemId: item.id, reason: result.reason };
  }

  const { suggestion } = result;
  const name = suggestion.name?.trim() || names.fallback;

  await deps.updateItem(item.id, {
    name,
    category: suggestion.category,
    tags: suggestion.tags,
    estimatedValue: suggestion.estimatedValue,
    currency: suggestion.currency,
  });

  return { status: 'recognized', itemId: item.id, name };
}
