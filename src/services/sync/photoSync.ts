import type { SqlDatabase } from '@/db/types';
import {
  deleteStoredPhotos,
  readStoredPhoto,
  writeStoredPhoto,
} from '@/services/capture/imageStore';
import { logEvent } from '@/services/telemetry';

import type { SyncClient } from './client';

/**
 * Moving photos between this device and durable storage.
 *
 * The device stays authoritative for reading. A photo that is on disk is shown
 * from disk, always — an inventory app that needs a network to show you a
 * picture of your own garage is worse than one that never uploaded it. Remote
 * copies exist for one purpose: to still be there when the disk is not.
 *
 * Every pass is bounded and resumable. Nothing here holds a transaction open
 * across a network call, and each photo is marked synced only after its bytes
 * are confirmed stored, so an interrupted pass repeats work rather than losing
 * it.
 */
const BATCH_SIZE = 10;

interface PendingPhoto {
  id: string;
  uri: string;
  thumb_uri: string | null;
}

export interface PhotoSyncOutcome {
  uploaded: number;
  deleted: number;
  restored: number;
  /** True when a pass stopped early — offline, quota, or an unauthorized code. */
  interrupted: boolean;
}

/**
 * Uploads photos that have no confirmed remote copy.
 *
 * A photo whose local file has vanished is marked synced-with-nothing rather
 * than retried forever: the bytes are unrecoverable either way, and leaving it
 * pending would block every later photo behind a permanent failure.
 */
export async function uploadPendingPhotos(
  db: SqlDatabase,
  client: SyncClient,
  limit: number = BATCH_SIZE,
): Promise<{ uploaded: number; interrupted: boolean }> {
  const pending = await db.getAllAsync<PendingPhoto>(
    `SELECT id, uri, thumb_uri FROM item_photos
      WHERE remote_synced_at IS NULL
      ORDER BY created_at
      LIMIT ?`,
    [limit],
  );

  let uploaded = 0;

  for (const photo of pending) {
    const bytes = await readStoredPhoto(photo.uri);

    if (!bytes) {
      // The thumbnail is derived from bytes that no longer exist, so it goes
      // with the row rather than lingering as an unreferenced file.
      deleteStoredPhotos([photo.thumb_uri]);
      await db.runAsync('DELETE FROM item_photos WHERE id = ?', [photo.id]);
      continue;
    }

    const result = await client.uploadPhoto(photo.id, bytes);

    if (result.status === 'failed') {
      // Offline, out of quota, or a code the service rejects: every remaining
      // photo would fail the same way, so stop rather than burn the battery.
      return { uploaded, interrupted: true };
    }

    await db.runAsync('UPDATE item_photos SET remote_synced_at = ? WHERE id = ?', [
      Date.now(),
      photo.id,
    ]);
    uploaded += 1;
  }

  return { uploaded, interrupted: false };
}

/**
 * Deletes remote copies of photos that are gone locally.
 *
 * The tombstone row is removed only once the service confirms the delete, so an
 * interrupted pass retries instead of leaving a photo stored forever that the
 * user believes they deleted.
 */
export async function processPhotoDeletions(
  db: SqlDatabase,
  client: SyncClient,
  limit: number = BATCH_SIZE,
): Promise<{ deleted: number; interrupted: boolean }> {
  const tombstones = await db.getAllAsync<{ photo_id: string }>(
    'SELECT photo_id FROM sync_deletions ORDER BY deleted_at LIMIT ?',
    [limit],
  );

  let deleted = 0;

  for (const tombstone of tombstones) {
    const result = await client.deletePhoto(tombstone.photo_id);
    if (result.status === 'failed') {
      return { deleted, interrupted: true };
    }

    await db.runAsync('DELETE FROM sync_deletions WHERE photo_id = ?', [tombstone.photo_id]);
    deleted += 1;
  }

  return { deleted, interrupted: false };
}

/**
 * Pulls back photos whose rows survived a restore but whose files did not.
 *
 * This is the other half of restoring a snapshot: the database knows about
 * every photo again, but a freshly installed app has none of the files, and on
 * iOS the stored absolute URIs point into an app container that no longer
 * exists. Rows are re-pointed at the rewritten files as each one lands.
 */
export async function rehydrateMissingPhotos(
  db: SqlDatabase,
  client: SyncClient,
  limit: number = BATCH_SIZE,
): Promise<{ restored: number; interrupted: boolean }> {
  const candidates = await db.getAllAsync<PendingPhoto>(
    `SELECT id, uri, thumb_uri FROM item_photos
      WHERE remote_synced_at IS NOT NULL
      ORDER BY created_at DESC
      LIMIT ?`,
    [limit],
  );

  let restored = 0;

  for (const photo of candidates) {
    if (await readStoredPhoto(photo.uri)) continue;

    const result = await client.downloadPhoto(photo.id);
    if (result.status === 'failed') {
      // A photo missing remotely is not recoverable and not worth retrying;
      // anything else is transient and should stop the pass.
      if (result.reason === 'not_found') continue;
      return { restored, interrupted: true };
    }

    const stored = await writeStoredPhoto(photo.id, result.value);
    await db.runAsync('UPDATE item_photos SET uri = ?, thumb_uri = ?, byte_size = ? WHERE id = ?', [
      stored.uri,
      stored.thumbUri,
      stored.byteSize,
      photo.id,
    ]);
    restored += 1;
  }

  return { restored, interrupted: false };
}

/** One full pass: push what is new, clean up what is gone, pull back what is missing. */
export async function syncPhotos(db: SqlDatabase, client: SyncClient): Promise<PhotoSyncOutcome> {
  const startedAt = Date.now();

  const uploads = await uploadPendingPhotos(db, client);
  const deletions = await processPhotoDeletions(db, client);
  const restores = await rehydrateMissingPhotos(db, client);

  const outcome: PhotoSyncOutcome = {
    uploaded: uploads.uploaded,
    deleted: deletions.deleted,
    restored: restores.restored,
    interrupted: uploads.interrupted || deletions.interrupted || restores.interrupted,
  };

  logEvent('photo_sync_pass', {
    durationMs: Date.now() - startedAt,
    itemCount: outcome.uploaded + outcome.deleted + outcome.restored,
    outcome: outcome.interrupted ? 'interrupted' : 'complete',
  });

  return outcome;
}
