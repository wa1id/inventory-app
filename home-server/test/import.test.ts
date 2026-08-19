import assert from 'node:assert/strict';
import { randomFillSync } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { configureRandomBytes } from '../../src/core/id.ts';
import { initializeRepositories } from '../../src/db/repositories.ts';
import { openNodeDatabase } from '../../src/db/nodeDatabase.ts';
import { collectHouseholdDump } from '../../src/services/household/collectDump.ts';

import { createApp } from '../src/app.ts';
import { openControlStore } from '../src/control.ts';
import { createRevisionHub } from '../src/hub.ts';
import { applyHouseholdDump } from '../src/importer.ts';
import { createMemoryPhotoStore } from '../src/photos.ts';

configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

test('import upserts phone rows by id and keeps them after a second run', async () => {
  const source = await initializeRepositories(openNodeDatabase());
  const target = await initializeRepositories(openNodeDatabase());
  const space = await source.spaces.create({ name: 'Garage', icon: '🚗', color: '#5B8DEF' });
  const container = await source.containers.create({
    spaceId: space.id,
    visualType: 'box',
    name: 'Tools',
  });
  const item = await source.items.create({
    containerId: container.id,
    name: 'Drill',
    tags: ['power'],
  });

  const dump = await collectHouseholdDump(source.db);
  assert.ok(dump.items.some((row) => row.id === item.id));

  await applyHouseholdDump(target.db, dump);
  await applyHouseholdDump(target.db, dump);

  const copied = await target.items.getById(item.id);
  assert.equal(copied?.name, 'Drill');
  assert.equal(copied?.containerId, container.id);
  assert.deepEqual(copied?.tags, ['power']);
});

test('POST /v1/import then PUT /v1/photos/:id stores bytes under the phone id', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-import-'));
  const control = await openControlStore(join(dir, 'control.db'));
  const repos = await initializeRepositories(openNodeDatabase(join(dir, 'inventory.db')));
  const photos = createMemoryPhotoStore();
  const app = createApp({
    control,
    publicOrigin: 'https://inventory.wystudio.be',
    repos,
    hub: createRevisionHub(),
    photos,
  });
  try {
    const pair = await app.request('/v1/pair', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        bootstrapSecret: control.bootstrapSecretToPrint,
        deviceName: 'Phone',
      }),
    });
    const { token } = (await pair.json()) as { token: string };
    const auth = { Authorization: `Bearer ${token}` };

    const source = await initializeRepositories(openNodeDatabase());
    const space = await source.spaces.create({ name: 'Loft', icon: '🏠', color: '#111111' });
    const container = await source.containers.create({ spaceId: space.id, visualType: 'box' });
    const item = await source.items.create({
      containerId: container.id,
      name: 'Lamp',
      photo: { id: '11111111-2222-4333-8444-555555555555', uri: 'file:///photos/lamp.webp' },
    });
    const dump = await collectHouseholdDump(source.db);

    const imported = await app.request('/v1/import', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify(dump),
    });
    assert.equal(imported.status, 200);
    const summary = (await imported.json()) as { items: number };
    assert.equal(summary.items, dump.items.length);

    const stored = await repos.items.getById(item.id);
    assert.equal(stored?.name, 'Lamp');
    assert.equal(stored?.photoId, '11111111-2222-4333-8444-555555555555');

    const pixel = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      'base64',
    );
    const uploaded = await app.request('/v1/photos/11111111-2222-4333-8444-555555555555', {
      method: 'PUT',
      headers: { ...auth, 'content-type': 'image/png' },
      body: pixel,
    });
    assert.equal(uploaded.status, 201);
    assert.equal((await photos.get('11111111-2222-4333-8444-555555555555', 'full')) !== null, true);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
