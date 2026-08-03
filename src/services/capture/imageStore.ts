import { Directory, File, Paths } from 'expo-file-system';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import type { ImageRef } from 'expo-image-manipulator';

import { newId } from '@/core/id';
import {
  IMAGE_QUALITY,
  MAX_IMAGE_DIMENSION,
  THUMBNAIL_DIMENSION,
  THUMBNAIL_QUALITY,
  scaleToFit,
} from '@/services/capture/imageScaling';
import { logError, logEvent } from '@/services/telemetry';

/**
 * WebP rather than JPEG.
 *
 * Typically 25–35% smaller than JPEG at matched visual quality, which comes
 * straight off both the device footprint and the R2 bill. Supported on both
 * platforms in SDK 57 — Android encodes via `Bitmap.CompressFormat.WEBP` and
 * iOS via `SDImageWebPCoder` — and decodable by the OS on this app's minimum
 * target of iOS 16.4 and on every supported Android version.
 */
const IMAGE_FORMAT = SaveFormat.WEBP;
const IMAGE_EXTENSION = 'webp';

/** App-owned, backed-up storage — not the shared camera roll. */
const PHOTO_DIRECTORY_NAME = 'item-photos';

export interface StoredImage {
  uri: string;
  /** Small copy for list rows. Always written alongside the full image. */
  thumbUri: string;
  width: number;
  height: number;
  byteSize: number | null;
}

function photoDirectory(): Directory {
  const directory = new Directory(Paths.document, PHOTO_DIRECTORY_NAME);
  if (!directory.exists) {
    directory.create({ intermediates: true });
  }
  return directory;
}

function fullName(photoId: string): string {
  return `${photoId}.${IMAGE_EXTENSION}`;
}

function thumbName(photoId: string): string {
  return `${photoId}-thumb.${IMAGE_EXTENSION}`;
}

/**
 * Scales an already-decoded image to fit `maxEdge`, then encodes it.
 *
 * Both dimensions are passed explicitly rather than letting one be derived, so
 * the rounding is ours and the stored width and height match the file exactly.
 */
async function renderScaled(source: ImageRef, maxEdge: number, quality: number) {
  const context = ImageManipulator.manipulate(source);
  const target = scaleToFit(source.width, source.height, maxEdge);
  if (target) context.resize(target);

  const rendered = await context.renderAsync();
  return rendered.saveAsync({ compress: quality, format: IMAGE_FORMAT });
}

/**
 * Moves a rendered file out of the cache and into app storage.
 *
 * `saveAsync` writes to the cache directory, which the system may purge at any
 * time; inventory photos have to outlive that.
 */
function adopt(sourceUri: string, name: string): { uri: string; byteSize: number | null } {
  const destination = new File(photoDirectory(), name);
  if (destination.exists) destination.delete();

  const temporary = new File(sourceUri);
  // Read the size before moving: `move` retargets the handle it is called on,
  // which leaves the destination handle stale and reporting no size.
  const byteSize = temporary.size ?? null;
  temporary.move(destination);

  return { uri: destination.uri, byteSize };
}

/**
 * Normalizes a captured or imported photo and moves it into app storage.
 *
 * The source is decoded exactly once and both sizes are derived from that one
 * reference, so a thumbnail costs a rescale rather than a second decode of a
 * twelve-megapixel original.
 *
 * Decoding also bakes the EXIF orientation into the pixels. Without that step
 * the same photo appears upright on one platform and rotated on the other
 * (issue #6).
 */
export async function storeItemPhoto(sourceUri: string): Promise<StoredImage> {
  const startedAt = Date.now();

  try {
    const source = await ImageManipulator.manipulate(sourceUri).renderAsync();
    const photoId = newId();

    const full = await renderScaled(source, MAX_IMAGE_DIMENSION, IMAGE_QUALITY);
    const thumb = await renderScaled(source, THUMBNAIL_DIMENSION, THUMBNAIL_QUALITY);

    const storedFull = adopt(full.uri, fullName(photoId));
    const storedThumb = adopt(thumb.uri, thumbName(photoId));

    const stored: StoredImage = {
      uri: storedFull.uri,
      thumbUri: storedThumb.uri,
      width: full.width,
      height: full.height,
      byteSize: storedFull.byteSize,
    };

    logEvent('photo_stored', {
      durationMs: Date.now() - startedAt,
      byteSize: stored.byteSize,
    });

    return stored;
  } catch (error) {
    logError('photo_store_failed', {
      durationMs: Date.now() - startedAt,
      errorClass: error instanceof Error ? error.name : 'unknown',
    });
    throw new Error('That photo could not be processed. Try again or continue without a photo.');
  }
}

/** Reads a stored photo's bytes, or null when the file is gone. */
export async function readStoredPhoto(uri: string): Promise<Uint8Array | null> {
  try {
    const file = new File(uri);
    if (!file.exists) return null;
    return await file.bytes();
  } catch {
    return null;
  }
}

/**
 * Writes a photo's bytes back into app storage under a known id, and rebuilds
 * its thumbnail.
 *
 * The restore counterpart to `storeItemPhoto`. The id rather than a random
 * filename is what makes it idempotent: re-running a partial restore overwrites
 * the same files instead of accumulating a copy per attempt.
 *
 * The full image is written byte-for-byte — it was already normalized before it
 * was uploaded, and re-encoding it would only lose quality for nothing. The
 * thumbnail is regenerated rather than downloaded, which is why thumbnails are
 * never uploaded at all: re-deriving one locally costs a rescale, while storing
 * one per photo would add an object and its bytes to every account forever.
 */
export async function writeStoredPhoto(photoId: string, bytes: Uint8Array): Promise<StoredImage> {
  const destination = new File(photoDirectory(), fullName(photoId));
  if (destination.exists) destination.delete();
  destination.create();
  destination.write(bytes);

  const source = await ImageManipulator.manipulate(destination.uri).renderAsync();
  const thumb = await renderScaled(source, THUMBNAIL_DIMENSION, THUMBNAIL_QUALITY);
  const storedThumb = adopt(thumb.uri, thumbName(photoId));

  return {
    uri: destination.uri,
    thumbUri: storedThumb.uri,
    width: source.width,
    height: source.height,
    byteSize: destination.size ?? bytes.byteLength,
  };
}

/**
 * Deletes photo files whose database rows are already gone.
 *
 * Best-effort by design: the rows are the source of truth, so a file that
 * cannot be removed is wasted space, never a broken reference. Nulls are
 * accepted so callers can pass thumbnail columns straight from a query without
 * filtering — rows predating thumbnails have none.
 */
export function deleteStoredPhotos(uris: (string | null)[]): void {
  for (const uri of uris) {
    if (!uri) continue;
    try {
      const file = new File(uri);
      if (file.exists) file.delete();
    } catch {
      // Ignored deliberately — see above.
    }
  }
}

/** Free space check used to fail gracefully before writing a photo (issue #8). */
export function hasRoomForPhoto(estimatedBytes = 1_000_000): boolean {
  try {
    return Paths.availableDiskSpace > estimatedBytes * 2;
  } catch {
    return true;
  }
}
