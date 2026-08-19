import assert from 'node:assert/strict';
import { randomFillSync } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { configureRandomBytes } from '../../src/core/id.ts';
import { initializeRepositories } from '../../src/db/repositories.ts';
import { openNodeDatabase } from '../../src/db/nodeDatabase.ts';

import { createApp } from '../src/app.ts';
import { openControlStore } from '../src/control.ts';
import { createRevisionHub } from '../src/hub.ts';
import { createMemoryPhotoStore, preparePhoto } from '../src/photos.ts';

configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

const PIXEL = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

test('preparePhoto writes webp full and thumb into the store', async () => {
  const store = createMemoryPhotoStore();
  const prepared = await preparePhoto(PIXEL, store);
  assert.ok(prepared.id);
  assert.equal((await store.get(prepared.id, 'full')) !== null, true);
  assert.equal((await store.get(prepared.id, 'thumb')) !== null, true);
  assert.match(prepared.uri, /^r2:household\/primary\/photos\//);
});

test('POST /v1/items with a photo stores bytes off-disk and GET streams them', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-photo-'));
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
        deviceName: 'Cam',
      }),
    });
    const { token } = (await pair.json()) as { token: string };
    const auth = { Authorization: `Bearer ${token}` };

    const space = (await (
      await app.request('/v1/spaces', {
        method: 'POST',
        headers: { ...auth, 'content-type': 'application/json' },
        body: JSON.stringify({ name: 'Garage', icon: '🚗', color: '#5B8DEF' }),
      })
    ).json()) as { id: string };
    const container = (await (
      await app.request('/v1/containers', {
        method: 'POST',
        headers: { ...auth, 'content-type': 'application/json' },
        body: JSON.stringify({ spaceId: space.id, visualType: 'box' }),
      })
    ).json()) as { id: string };

    const form = new FormData();
    form.set('containerId', container.id);
    form.set('name', 'Cable');
    form.set('photo', new File([PIXEL], 'cable.png', { type: 'image/png' }));

    const created = await app.request('/v1/items', {
      method: 'POST',
      headers: auth,
      body: form,
    });
    assert.equal(created.status, 201);
    const item = (await created.json()) as { id: string };
    const stored = await repos.items.getById(item.id);
    assert.ok(stored?.photoId);

    const photo = await app.request(`/v1/photos/${stored.photoId}`, { headers: auth });
    assert.equal(photo.status, 200);
    assert.equal(photo.headers.get('content-type'), 'image/webp');
    const bytes = new Uint8Array(await photo.arrayBuffer());
    assert.ok(bytes.byteLength > 0);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
