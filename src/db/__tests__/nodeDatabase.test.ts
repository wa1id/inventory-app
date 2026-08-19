import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { openNodeDatabase } from '@/db/nodeDatabase';
import { initializeRepositories } from '@/db/repositories';

describe('file-backed node database', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'inventory-db-'));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('reopens a file and still has the rows', async () => {
    const path = join(dir, 'inventory.db');
    const first = await initializeRepositories(openNodeDatabase(path));
    const space = await first.spaces.create({ name: 'Garage', icon: 'car', color: '#5B8DEF' });
    await first.db.closeAsync();

    const second = await initializeRepositories(openNodeDatabase(path));
    const fetched = await second.spaces.getById(space.id);
    expect(fetched?.name).toBe('Garage');
    await second.db.closeAsync();
  });

  it('round-trips an in-memory snapshot', async () => {
    const db = openNodeDatabase();
    const repos = await initializeRepositories(db);
    const space = await repos.spaces.create({ name: 'Loft', icon: 'home', color: '#E4572E' });
    const snapshot = await db.snapshotAsync?.();
    if (!snapshot || !db.restoreAsync) {
      throw new Error('in-memory adapter must implement snapshot and restore');
    }

    await repos.spaces.update(space.id, { name: 'Attic' });
    await db.restoreAsync(snapshot);
    expect((await repos.spaces.getById(space.id))?.name).toBe('Loft');
    await db.closeAsync();
  });

  it('round-trips a snapshot through restore', async () => {
    const path = join(dir, 'inventory.db');
    const db = openNodeDatabase(path);
    const repos = await initializeRepositories(db);
    const space = await repos.spaces.create({ name: 'Loft', icon: 'home', color: '#E4572E' });

    const snapshot = await db.snapshotAsync?.();
    expect(snapshot).toBeInstanceOf(Uint8Array);
    if (!snapshot || !db.restoreAsync) {
      throw new Error('file-backed adapter must implement snapshot and restore');
    }

    await repos.spaces.update(space.id, { name: 'Attic' });
    expect((await repos.spaces.getById(space.id))?.name).toBe('Attic');

    await db.restoreAsync(snapshot);
    const restored = await initializeRepositories(db);
    expect((await restored.spaces.getById(space.id))?.name).toBe('Loft');
    await db.closeAsync();
  });
});
