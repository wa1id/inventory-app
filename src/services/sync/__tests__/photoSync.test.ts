import { migrate } from '@/db/migrations';
import { createRepositories } from '@/db/repositories';
import type { Repositories } from '@/db/repositories';
import { openNodeDatabase } from '@/db/testing/nodeDatabase';
import type { SqlDatabase } from '@/db/types';
import type { SyncClient } from '@/services/sync/client';
import type { SyncFailureReason } from '@/services/sync/contract';
import {
  processPhotoDeletions,
  rehydrateMissingPhotos,
  syncPhotos,
  uploadPendingPhotos,
} from '@/services/sync/photoSync';

/** Files that "exist on disk", keyed by uri. */
const mockFiles = new Map<string, Uint8Array>();

jest.mock('@/services/capture/imageStore', () => ({
  readStoredPhoto: async (uri: string) => mockFiles.get(uri) ?? null,
  writeStoredPhoto: (photoId: string, bytes: Uint8Array) => {
    const uri = `file:///documents/item-photos/${photoId}.jpg`;
    mockFiles.set(uri, bytes);
    return { uri, width: 0, height: 0, byteSize: bytes.byteLength };
  },
}));

interface FakeClient extends SyncClient {
  remote: Map<string, Uint8Array>;
  uploads: string[];
  deletes: string[];
  downloads: string[];
}

function fakeClient(failWith?: SyncFailureReason): FakeClient {
  const remote = new Map<string, Uint8Array>();
  const uploads: string[] = [];
  const deletes: string[] = [];
  const downloads: string[] = [];

  return {
    configured: true,
    remote,
    uploads,
    deletes,
    downloads,

    async uploadPhoto(photoId: string, bytes: Uint8Array) {
      if (failWith) return { status: 'failed', reason: failWith };
      uploads.push(photoId);
      remote.set(photoId, bytes);
      return { status: 'success', value: undefined };
    },
    async downloadPhoto(photoId: string) {
      downloads.push(photoId);
      const bytes = remote.get(photoId);
      if (!bytes) return { status: 'failed', reason: 'not_found' };
      return { status: 'success', value: bytes };
    },
    async deletePhoto(photoId: string) {
      if (failWith) return { status: 'failed', reason: failWith };
      deletes.push(photoId);
      remote.delete(photoId);
      return { status: 'success', value: undefined };
    },
  } as unknown as FakeClient;
}

async function seed(): Promise<{ db: SqlDatabase; repos: Repositories; itemId: string }> {
  const db = openNodeDatabase();
  await migrate(db);
  const repos = createRepositories(db);

  const space = await repos.spaces.create({ name: 'Garage', icon: 'car', color: '#5B8DEF' });
  const container = await repos.containers.create({ spaceId: space.id, visualType: 'box' });
  const item = await repos.items.create({ containerId: container.id, name: 'Drill', quantity: 1 });

  return { db, repos, itemId: item.id };
}

async function addPhoto(db: SqlDatabase, itemId: string, photoId: string, synced = false) {
  const uri = `file:///documents/item-photos/${photoId}.jpg`;
  mockFiles.set(uri, new Uint8Array([1, 2, 3]));
  await db.runAsync(
    `INSERT INTO item_photos (id, item_id, uri, byte_size, created_at, remote_synced_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [photoId, itemId, uri, 3, Date.now(), synced ? Date.now() : null],
  );
  return uri;
}

beforeEach(() => {
  mockFiles.clear();
});

describe('uploadPendingPhotos', () => {
  it('uploads unsynced photos and marks them synced', async () => {
    const { db, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-a');
    await addPhoto(db, itemId, 'photo-b');
    const client = fakeClient();

    const result = await uploadPendingPhotos(db, client);

    expect(result).toEqual({ uploaded: 2, interrupted: false });
    expect(client.uploads.sort()).toEqual(['photo-a', 'photo-b']);

    const remaining = await db.getAllAsync(
      'SELECT id FROM item_photos WHERE remote_synced_at IS NULL',
    );
    expect(remaining).toEqual([]);
  });

  it('does not re-upload a photo already synced', async () => {
    const { db, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-a', true);
    const client = fakeClient();

    await uploadPendingPhotos(db, client);

    expect(client.uploads).toEqual([]);
  });

  it('drops a row whose local file has vanished rather than retrying forever', async () => {
    const { db, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-gone');
    mockFiles.clear();
    const client = fakeClient();

    const result = await uploadPendingPhotos(db, client);

    expect(result.uploaded).toBe(0);
    const rows = await db.getAllAsync('SELECT id FROM item_photos');
    expect(rows).toEqual([]);
  });

  it('stops the pass when the service is unreachable, leaving work pending', async () => {
    const { db, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-a');
    await addPhoto(db, itemId, 'photo-b');

    const result = await uploadPendingPhotos(db, fakeClient('offline'));

    expect(result).toEqual({ uploaded: 0, interrupted: true });
    // Still pending, so the next pass picks them up.
    const pending = await db.getAllAsync(
      'SELECT id FROM item_photos WHERE remote_synced_at IS NULL',
    );
    expect(pending).toHaveLength(2);
  });
});

describe('deletion tombstones', () => {
  it('records a tombstone when a synced photo is deleted by cascade', async () => {
    const { db, repos, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-a', true);

    // Deleting the item cascades to item_photos — the case no repository
    // deletes a photo row for explicitly.
    await repos.items.delete(itemId);

    const tombstones = await db.getAllAsync<{ photo_id: string }>(
      'SELECT photo_id FROM sync_deletions',
    );
    expect(tombstones).toEqual([{ photo_id: 'photo-a' }]);
  });

  it('records no tombstone for a photo that was never uploaded', async () => {
    const { db, repos, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-a');

    await repos.items.delete(itemId);

    expect(await db.getAllAsync('SELECT photo_id FROM sync_deletions')).toEqual([]);
  });

  it('deletes remotely and clears the tombstone', async () => {
    const { db, repos, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-a', true);
    const client = fakeClient();
    client.remote.set('photo-a', new Uint8Array([1]));
    await repos.items.delete(itemId);

    const result = await processPhotoDeletions(db, client);

    expect(result).toEqual({ deleted: 1, interrupted: false });
    expect(client.remote.has('photo-a')).toBe(false);
    expect(await db.getAllAsync('SELECT photo_id FROM sync_deletions')).toEqual([]);
  });

  it('keeps the tombstone when the delete could not be confirmed', async () => {
    const { db, repos, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-a', true);
    await repos.items.delete(itemId);

    const result = await processPhotoDeletions(db, fakeClient('offline'));

    expect(result.interrupted).toBe(true);
    // A photo the user deleted must not stay stored just because the network
    // was down at the wrong moment.
    expect(await db.getAllAsync('SELECT photo_id FROM sync_deletions')).toHaveLength(1);
  });
});

describe('rehydrateMissingPhotos', () => {
  it('pulls back files that a restore left behind, re-pointing the row', async () => {
    const { db, itemId } = await seed();
    const originalUri = await addPhoto(db, itemId, 'photo-a', true);
    const client = fakeClient();
    client.remote.set('photo-a', new Uint8Array([7, 7, 7, 7]));

    // A restored database on a fresh install: the row survives, the file does
    // not, and on iOS the recorded uri points into a container that is gone.
    mockFiles.clear();

    const result = await rehydrateMissingPhotos(db, client);

    expect(result).toEqual({ restored: 1, interrupted: false });
    const [row] = await db.getAllAsync<{ uri: string; byte_size: number }>(
      'SELECT uri, byte_size FROM item_photos',
    );
    expect(row?.byte_size).toBe(4);
    expect(mockFiles.get(row?.uri ?? '')).toEqual(new Uint8Array([7, 7, 7, 7]));
    expect(row?.uri).toBe(originalUri);
  });

  it('leaves photos alone when the local file is present', async () => {
    const { db, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-a', true);
    const client = fakeClient();

    const result = await rehydrateMissingPhotos(db, client);

    expect(result.restored).toBe(0);
    expect(client.downloads).toEqual([]);
  });

  it('skips a photo missing remotely instead of stalling the pass', async () => {
    const { db, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-gone', true);
    await addPhoto(db, itemId, 'photo-here', true);
    const client = fakeClient();
    client.remote.set('photo-here', new Uint8Array([5]));
    mockFiles.clear();

    const result = await rehydrateMissingPhotos(db, client);

    expect(result).toEqual({ restored: 1, interrupted: false });
  });
});

describe('syncPhotos', () => {
  it('reports a complete pass across all three directions', async () => {
    const { db, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-new');
    const client = fakeClient();

    const outcome = await syncPhotos(db, client);

    expect(outcome).toEqual({ uploaded: 1, deleted: 0, restored: 0, interrupted: false });
  });

  it('reports interruption when any direction could not finish', async () => {
    const { db, itemId } = await seed();
    await addPhoto(db, itemId, 'photo-new');

    const outcome = await syncPhotos(db, fakeClient('offline'));

    expect(outcome.interrupted).toBe(true);
  });
});
