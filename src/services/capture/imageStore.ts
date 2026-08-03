import { Directory, File, Paths } from 'expo-file-system';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';

import { newId } from '@/core/id';
import { logError, logEvent } from '@/services/telemetry';

/**
 * Documented compression limits (issue #6).
 *
 * A 1600px long edge at 70% JPEG quality keeps a typical item photo well under
 * 400 KB, which matters because photos are the only thing in this app that
 * grows without bound.
 */
export const MAX_IMAGE_DIMENSION = 1600;
export const JPEG_QUALITY = 0.7;

/** App-owned, backed-up storage — not the shared camera roll. */
const PHOTO_DIRECTORY_NAME = 'item-photos';

export interface StoredImage {
  uri: string;
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

/**
 * Normalizes a captured or imported photo and moves it into app storage.
 *
 * `ImageManipulator` decodes and re-encodes the image, which bakes the EXIF
 * orientation into the pixels. Without that step the same photo appears
 * upright on one platform and rotated on the other (issue #6).
 */
export async function storeItemPhoto(sourceUri: string): Promise<StoredImage> {
  const startedAt = Date.now();

  try {
    const context = ImageManipulator.manipulate(sourceUri);
    context.resize({ width: MAX_IMAGE_DIMENSION });

    const rendered = await context.renderAsync();
    const saved = await rendered.saveAsync({
      compress: JPEG_QUALITY,
      format: SaveFormat.JPEG,
    });

    // saveAsync writes to the cache directory, which the system may purge.
    // Move it into document storage so inventory photos survive.
    const destination = new File(photoDirectory(), `${newId()}.jpg`);
    const temporary = new File(saved.uri);

    // Read the size before moving: `move` retargets the handle it is called on,
    // which leaves the destination handle stale and reporting no size.
    const byteSize = temporary.size ?? null;
    temporary.move(destination);

    const stored: StoredImage = {
      uri: destination.uri,
      width: saved.width,
      height: saved.height,
      byteSize,
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
 * Writes a photo's bytes back into app storage under a known id.
 *
 * The restore counterpart to `storeItemPhoto`. The id rather than a random
 * filename is what makes it idempotent: re-running a partial restore overwrites
 * the same file instead of accumulating a copy per attempt.
 *
 * No re-encoding here — these bytes were already normalized before they were
 * uploaded, and decoding them again would only lose quality.
 */
export function writeStoredPhoto(photoId: string, bytes: Uint8Array): StoredImage {
  const destination = new File(photoDirectory(), `${photoId}.jpg`);
  if (destination.exists) destination.delete();
  destination.create();
  destination.write(bytes);

  return {
    uri: destination.uri,
    width: 0,
    height: 0,
    byteSize: destination.size ?? bytes.byteLength,
  };
}

/**
 * Deletes photo files whose database rows are already gone.
 *
 * Best-effort by design: the rows are the source of truth, so a file that
 * cannot be removed is wasted space, never a broken reference.
 */
export function deleteStoredPhotos(uris: string[]): void {
  for (const uri of uris) {
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
