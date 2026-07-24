import { rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

import { LATEST_SCHEMA_VERSION, MIGRATIONS, migrate } from '@/db/migrations';
import { createRepositories, initializeRepositories } from '@/db/repositories';
import type { Repositories } from '@/db/repositories';
import { openNodeDatabase } from '@/db/testing/nodeDatabase';
import type { SqlDatabase } from '@/db/types';

async function freshRepos(): Promise<Repositories> {
  return initializeRepositories(openNodeDatabase());
}

async function seedSpaceAndContainer(repos: Repositories) {
  const space = await repos.spaces.create({ name: 'Garage', icon: 'car', color: '#5B8DEF' });
  const container = await repos.containers.create({ spaceId: space.id, visualType: 'box' });
  return { space, container };
}

describe('migrations', () => {
  it('brings a new database to the latest schema version', async () => {
    const db = openNodeDatabase();
    const version = await migrate(db);
    expect(version).toBe(LATEST_SCHEMA_VERSION);
  });

  it('is idempotent when run twice', async () => {
    const db = openNodeDatabase();
    await migrate(db);
    await expect(migrate(db)).resolves.toBe(LATEST_SCHEMA_VERSION);
  });

  it('upgrades a database stopped at an older version without losing data', async () => {
    const db = openNodeDatabase();

    // Simulate an install that only ever saw migration 1.
    const [first] = MIGRATIONS;
    await migrate(db, first ? [first] : []);

    const repos = createRepositories(db);
    const { container } = await seedSpaceAndContainer(repos);
    await db.runAsync(
      `INSERT INTO items (id, container_id, name, quantity, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
      ['legacy-item', container.id, 'Legacy Drill', 1, Date.now(), Date.now()],
    );

    const version = await migrate(db);

    expect(version).toBe(LATEST_SCHEMA_VERSION);
    // Migration 2 must backfill search_text for rows written before it existed.
    const row = await db.getFirstAsync<{ search_text: string }>(
      'SELECT search_text FROM items WHERE id = ?',
      ['legacy-item'],
    );
    expect(row?.search_text).toBe('legacy drill');
  });

  it('declares versions matching their position', () => {
    MIGRATIONS.forEach((migration, index) => {
      expect(migration.version).toBe(index + 1);
    });
  });
});

describe('spaces', () => {
  it('creates, reads back, and updates without changing identity', async () => {
    const repos = await freshRepos();
    const created = await repos.spaces.create({ name: '  Attic  ', icon: 'box', color: '#E4572E' });

    expect(created.name).toBe('Attic');

    const renamed = await repos.spaces.update(created.id, { name: 'Loft', color: '#2E9E4F' });

    expect(renamed?.id).toBe(created.id);
    expect(renamed?.name).toBe('Loft');
    expect(renamed?.createdAt).toBe(created.createdAt);

    const fetched = await repos.spaces.getById(created.id);
    expect(fetched?.name).toBe('Loft');
  });

  it('reports container and item counts on the dashboard query', async () => {
    const repos = await freshRepos();
    const { space, container } = await seedSpaceAndContainer(repos);
    await repos.items.create({ containerId: container.id, name: 'Hammer' });
    await repos.items.create({ containerId: container.id, name: 'Wrench' });

    const [dashboard] = await repos.spaces.listWithCounts();

    expect(dashboard?.id).toBe(space.id);
    expect(dashboard?.containerCount).toBe(1);
    expect(dashboard?.itemCount).toBe(2);
  });

  it('describes deletion impact before deleting', async () => {
    const repos = await freshRepos();
    const { space, container } = await seedSpaceAndContainer(repos);
    await repos.items.create({
      containerId: container.id,
      name: 'Drill',
      photo: { uri: 'file:///photos/drill.jpg' },
    });
    await repos.qr.createAndBind(container.id);

    const impact = await repos.spaces.deletionImpact(space.id);

    expect(impact).toEqual({
      containerCount: 1,
      itemCount: 1,
      photoCount: 1,
      qrBindingCount: 1,
    });
  });

  it('cascades deletion to containers, items, photos, and QR bindings', async () => {
    const repos = await freshRepos();
    const { space, container } = await seedSpaceAndContainer(repos);
    await repos.items.create({
      containerId: container.id,
      name: 'Drill',
      photo: { uri: 'file:///photos/drill.jpg' },
    });
    await repos.qr.createAndBind(container.id);

    const result = await repos.spaces.delete(space.id);

    expect(result.deleted).toBe(true);
    expect(result.orphanedPhotoUris).toEqual(['file:///photos/drill.jpg']);
    await expectCount(repos.db, 'containers', 0);
    await expectCount(repos.db, 'items', 0);
    await expectCount(repos.db, 'item_photos', 0);
    await expectCount(repos.db, 'qr_bindings', 0);
  });
});

describe('containers', () => {
  it('assigns a unique, human-friendly short code', async () => {
    const repos = await freshRepos();
    const space = await repos.spaces.create({ name: 'Shed', icon: 'box', color: '#5B8DEF' });

    const first = await repos.containers.create({ spaceId: space.id, visualType: 'box' });
    const second = await repos.containers.create({ spaceId: space.id, visualType: 'drawer' });

    expect(first.shortCode).toMatch(/^BOX-[A-Z0-9]{4}$/);
    expect(second.shortCode).toMatch(/^DRW-[A-Z0-9]{4}$/);
    expect(first.shortCode).not.toBe(second.shortCode);
  });

  it('stores a blank name as null rather than an empty string', async () => {
    const repos = await freshRepos();
    const space = await repos.spaces.create({ name: 'Shed', icon: 'box', color: '#5B8DEF' });

    const container = await repos.containers.create({
      spaceId: space.id,
      visualType: 'box',
      name: '   ',
    });

    expect(container.name).toBeNull();
  });

  it('refuses to attach a container to a space that does not exist', async () => {
    const repos = await freshRepos();

    await expect(
      repos.containers.create({ spaceId: 'no-such-space', visualType: 'box' }),
    ).rejects.toThrow();
  });

  it('moves a container to another space', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);
    const target = await repos.spaces.create({ name: 'Basement', icon: 'box', color: '#2E9E4F' });

    const moved = await repos.containers.update(container.id, { spaceId: target.id });

    expect(moved?.spaceId).toBe(target.id);
    const inTarget = await repos.containers.listBySpace(target.id);
    expect(inTarget).toHaveLength(1);
  });

  it('keeps item counts current as items come and go', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);

    const item = await repos.items.create({ containerId: container.id, name: 'Saw' });
    expect((await repos.containers.getWithCounts(container.id))?.itemCount).toBe(1);

    await repos.items.delete(item.id);
    expect((await repos.containers.getWithCounts(container.id))?.itemCount).toBe(0);
  });
});

describe('items', () => {
  it('creates an item with photo and tags atomically', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);

    const item = await repos.items.create({
      containerId: container.id,
      name: 'Cordless Drill',
      category: 'Tools',
      quantity: 2,
      estimatedValue: 129.99,
      currency: 'EUR',
      notes: 'Charger in side pocket',
      tags: ['power tool', 'DeWalt', 'power tool'],
      photo: { uri: 'file:///photos/drill.jpg', width: 1024, height: 768, byteSize: 210_000 },
    });

    const stored = await repos.items.getById(item.id);

    expect(stored?.name).toBe('Cordless Drill');
    expect(stored?.quantity).toBe(2);
    expect(stored?.photoUri).toBe('file:///photos/drill.jpg');
    // Duplicate tag names collapse to one link.
    expect(stored?.tags.sort()).toEqual(['DeWalt', 'power tool']);
    expect(stored?.spaceName).toBe('Garage');
  });

  it('rejects a non-positive quantity', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);

    await expect(
      repos.items.create({ containerId: container.id, name: 'Nails', quantity: 0 }),
    ).rejects.toThrow(/at least 1/);
  });

  it('rejects an empty name', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);

    await expect(repos.items.create({ containerId: container.id, name: '   ' })).rejects.toThrow(
      /name is required/,
    );
  });

  it('rolls the whole draft back when part of it fails', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);

    // A CHECK violation inside the transaction must leave nothing behind.
    await expect(
      repos.db.withTransactionAsync(async () => {
        await repos.items.create({ containerId: container.id, name: 'Valid Item' });
        await repos.db.runAsync(
          `INSERT INTO items (id, container_id, name, quantity, created_at, updated_at, search_text)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
          ['bad', container.id, 'Bad Item', -5, Date.now(), Date.now(), 'bad item'],
        );
      }),
    ).rejects.toThrow();

    await expectCount(repos.db, 'items', 0);
  });

  it('updates fields and replaces tags without changing identity', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);
    const item = await repos.items.create({
      containerId: container.id,
      name: 'Drill',
      tags: ['old'],
    });

    const updated = await repos.items.update(item.id, { name: 'Impact Drill', tags: ['new'] });

    expect(updated?.id).toBe(item.id);
    expect(updated?.createdAt).toBe(item.createdAt);
    const stored = await repos.items.getById(item.id);
    expect(stored?.tags).toEqual(['new']);
  });

  it('removes photo and tag rows when an item is deleted', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);
    const item = await repos.items.create({
      containerId: container.id,
      name: 'Drill',
      tags: ['tools'],
      photo: { uri: 'file:///photos/drill.jpg' },
    });

    const result = await repos.items.delete(item.id);

    expect(result.deleted).toBe(true);
    expect(result.orphanedPhotoUris).toEqual(['file:///photos/drill.jpg']);
    await expectCount(repos.db, 'item_photos', 0);
    await expectCount(repos.db, 'item_tags', 0);
    // The tag vocabulary itself survives for reuse by other items.
    await expectCount(repos.db, 'tags', 1);
  });

  it('cannot be created in a container that does not exist', async () => {
    const repos = await freshRepos();

    await expect(repos.items.create({ containerId: 'nope', name: 'Ghost' })).rejects.toThrow();
  });
});

describe('qr bindings', () => {
  it('resolves a bound token to its container', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);
    const binding = await repos.qr.createAndBind(container.id);

    const outcome = await repos.qr.resolveScan(`inventory://c/${binding.token}`);

    expect(outcome.kind).toBe('bound');
    if (outcome.kind === 'bound') {
      expect(outcome.container.id).toBe(container.id);
    }
  });

  it('reports an unknown but well-formed token so it can be bound', async () => {
    const repos = await freshRepos();
    const outcome = await repos.qr.resolveScan('a'.repeat(32));
    expect(outcome.kind).toBe('unknown');
  });

  it('rejects codes that are not ours', async () => {
    const repos = await freshRepos();
    expect((await repos.qr.resolveScan('https://example.com')).kind).toBe('invalid');
    expect((await repos.qr.resolveScan('')).kind).toBe('invalid');
  });

  it('replaces the previous binding when a token is rebound', async () => {
    const repos = await freshRepos();
    const { space, container } = await seedSpaceAndContainer(repos);
    const other = await repos.containers.create({ spaceId: space.id, visualType: 'bin' });
    const binding = await repos.qr.createAndBind(container.id);

    await repos.qr.bind(binding.token, other.id);

    const outcome = await repos.qr.resolveScan(binding.token);
    expect(outcome.kind === 'bound' && outcome.container.id).toBe(other.id);
    // Exactly one binding survives — the label points at one container only.
    await expectCount(repos.db, 'qr_bindings', 1);
  });

  it('replaces a container previous token when a new one is bound to it', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);
    const first = await repos.qr.createAndBind(container.id);
    const second = await repos.qr.createAndBind(container.id);

    expect((await repos.qr.resolveScan(first.token)).kind).toBe('unknown');
    expect((await repos.qr.resolveScan(second.token)).kind).toBe('bound');
  });

  it('unbinding keeps the container and its items', async () => {
    const repos = await freshRepos();
    const { container } = await seedSpaceAndContainer(repos);
    await repos.items.create({ containerId: container.id, name: 'Drill' });
    await repos.qr.createAndBind(container.id);

    await repos.qr.unbind(container.id);

    expect(await repos.containers.getById(container.id)).not.toBeNull();
    await expectCount(repos.db, 'items', 1);
    await expectCount(repos.db, 'qr_bindings', 0);
  });
});

describe('data durability', () => {
  it('keeps inventory after closing and reopening the database file', async () => {
    const path = `${tmpdir()}/inventory-test-${Date.now()}.db`;

    const first = openNodeDatabase(path);
    const repos = await initializeRepositories(first);
    const { container } = await seedSpaceAndContainer(repos);
    await repos.items.create({ containerId: container.id, name: 'Survivor' });
    await first.closeAsync();

    // Simulates process death followed by a cold start.
    const second = openNodeDatabase(path);
    const reopened = await initializeRepositories(second);
    const items = await reopened.items.listByContainer(container.id);

    expect(items.map((item) => item.name)).toEqual(['Survivor']);
    await second.closeAsync();
    rmSync(path, { force: true });
  });
});

async function expectCount(db: SqlDatabase, table: string, expected: number): Promise<void> {
  const row = await db.getFirstAsync<{ count: number }>(`SELECT COUNT(*) AS count FROM ${table}`);
  expect(row?.count).toBe(expected);
}
