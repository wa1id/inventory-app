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
import {
  createMemoryPhotoStore,
  createWorkerPhotoStore,
  photoStoreFromEnv,
  preparePhoto,
} from '../src/photos.ts';

configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

const PIXEL = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

test('photoStoreFromEnv needs HOUSEHOLD_PHOTO_SECRET, not R2 S3 keys', () => {
  assert.equal(photoStoreFromEnv({}), null);
  assert.equal(
    photoStoreFromEnv({ R2_ACCESS_KEY_ID: 'akid', R2_SECRET_ACCESS_KEY: 'secret' }),
    null,
  );
  assert.ok(photoStoreFromEnv({ HOUSEHOLD_PHOTO_SECRET: 'box-secret' }));
});

test('worker photo store PUT/GET round-trips through inventory-sync', async () => {
  const objects = new Map<string, { bytes: Uint8Array; type: string }>();
  const store = createWorkerPhotoStore({
    origin: 'https://sync.example',
    secret: 'box-secret',
    fetch: async (input, init) => {
      const url = new URL(String(input));
      const authorization = new Headers(init?.headers).get('authorization');
      assert.equal(authorization, 'Bearer box-secret');
      const body = init?.body;
      if (init?.method === 'PUT') {
        const bytes =
          body instanceof Uint8Array
            ? body
            : Buffer.isBuffer(body)
              ? new Uint8Array(body)
              : new Uint8Array();
        objects.set(url.pathname + url.search, {
          bytes,
          type: new Headers(init.headers).get('content-type') ?? 'application/octet-stream',
        });
        return new Response(null, { status: 201 });
      }
      const stored = objects.get(url.pathname + url.search);
      if (!stored) return new Response(JSON.stringify({ error: 'Not found.' }), { status: 404 });
      return new Response(Buffer.from(stored.bytes), { headers: { 'content-type': stored.type } });
    },
  });

  const payload = new Uint8Array([1, 2, 3, 4]);
  await store.put('11111111-2222-4333-8444-555555555555', 'full', payload, 'image/webp');
  const got = await store.get('11111111-2222-4333-8444-555555555555', 'full');
  assert.deepEqual(got?.bytes, payload);
  assert.equal(got?.contentType, 'image/webp');
  assert.equal(await store.get('11111111-2222-4333-8444-555555555555', 'thumb'), null);
});

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

test('PUT photo then POST /v1/items JSON attaches the uploaded id', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-photo-json-'));
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

    const photoId = '11111111-2222-4333-8444-555555555555';
    const uploaded = await app.request(`/v1/photos/${photoId}`, {
      method: 'PUT',
      headers: { ...auth, 'content-type': 'application/octet-stream' },
      body: PIXEL,
    });
    assert.equal(uploaded.status, 201);
    const prepared = (await uploaded.json()) as {
      id: string;
      uri: string;
      thumbUri: string;
      width: number;
      height: number;
      byteSize: number;
    };

    const created = await app.request('/v1/items', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({
        containerId: container.id,
        name: 'Cable',
        photo: prepared,
      }),
    });
    assert.equal(created.status, 201);
    const item = (await created.json()) as { id: string; photoId: string };
    assert.equal(item.photoId, photoId);

    const missing = await app.request('/v1/items', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({
        containerId: container.id,
        name: 'Ghost',
        photo: { id: '99999999-2222-4333-8444-555555555555' },
      }),
    });
    assert.equal(missing.status, 400);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
