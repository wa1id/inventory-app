import type { SqlDatabase } from '@/db/types';
import { logEvent } from '@/services/telemetry';

import { householdFetch, householdRequest, type HouseholdSession } from './client';
import { collectHouseholdDump, localPhotoUris } from './collectDump';

export interface ImportResult {
  items: number;
  photos: number;
  photosUploaded: number;
  photosMissing: number;
}

/**
 * Pushes this phone's inventory onto the household server, keeping ids.
 *
 * Photo bytes come from disk first, then the old inventory-sync Worker if
 * Backup is enabled and the file is gone.
 */
export async function importLocalInventory(options: {
  session: HouseholdSession;
  db: SqlDatabase;
  fetchImpl?: typeof fetch;
  readPhoto?: (uri: string) => Promise<Uint8Array | null>;
}): Promise<ImportResult> {
  const dump = await collectHouseholdDump(options.db);
  const uris = await localPhotoUris(options.db);
  const readPhoto =
    options.readPhoto ?? (await import('@/services/capture/imageStore')).readStoredPhoto;

  const body = await householdRequest({
    origin: options.session.origin,
    token: options.session.token,
    path: '/v1/import',
    method: 'POST',
    json: dump,
    fetchImpl: options.fetchImpl,
    timeoutMs: 60_000,
  });

  const sync = await loadSyncClient();

  let photosUploaded = 0;
  let photosMissing = 0;

  for (const photo of dump.photos) {
    const localUri = uris.get(photo.id);
    let bytes: Uint8Array | null = localUri ? await readPhoto(localUri) : null;
    if (!bytes && sync) {
      const downloaded = await sync.downloadPhoto(photo.id);
      if (downloaded.status === 'success') bytes = downloaded.value;
    }
    if (!bytes) {
      photosMissing += 1;
      continue;
    }

    const response = await householdFetch({
      origin: options.session.origin,
      token: options.session.token,
      path: `/v1/photos/${encodeURIComponent(photo.id)}`,
      method: 'PUT',
      bytes,
      fetchImpl: options.fetchImpl,
      timeoutMs: 60_000,
    });
    if (!response.ok) {
      photosMissing += 1;
      continue;
    }
    photosUploaded += 1;
  }

  logEvent('household_imported', { itemCount: dump.items.length });

  return {
    items: typeof body.items === 'number' ? body.items : dump.items.length,
    photos: dump.photos.length,
    photosUploaded,
    photosMissing,
  };
}

async function loadSyncClient() {
  try {
    const { loadAccount } = await import('@/services/account/identity');
    const account = await loadAccount();
    if (!account) return null;
    const { createSyncClient } = await import('@/services/sync/client');
    return createSyncClient({ recoveryCode: account.recoveryCode });
  } catch {
    return null;
  }
}
