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

configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

async function setup() {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-rest-'));
  const control = await openControlStore(join(dir, 'control.db'));
  const repos = await initializeRepositories(openNodeDatabase(join(dir, 'inventory.db')));
  const hub = createRevisionHub();
  const app = createApp({
    control,
    publicOrigin: 'https://inventory.wystudio.be',
    repos,
    hub,
  });
  const pair = await app.request('/v1/pair', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      bootstrapSecret: control.bootstrapSecretToPrint,
      deviceName: 'Test',
    }),
  });
  const { token } = (await pair.json()) as { token: string };
  const auth = { Authorization: `Bearer ${token}` };
  return { dir, control, repos, app, auth, hub };
}

test('status requires a token and reports schema plus revision', async () => {
  const { dir, control, app, auth, hub } = await setup();
  try {
    assert.equal((await app.request('/v1/status')).status, 401);
    const response = await app.request('/v1/status', { headers: auth });
    assert.equal(response.status, 200);
    const body = (await response.json()) as Record<string, unknown>;
    assert.equal(body.schemaVersion, 6);
    assert.equal(body.revision, hub.revision);
    assert.equal(body.householdName, 'Home');
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('spaces, containers, items, search, and PATCH round-trip', async () => {
  const { dir, control, app, auth } = await setup();
  try {
    const createdSpace = await app.request('/v1/spaces', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Garage', icon: '🚗', color: '#5B8DEF' }),
    });
    assert.equal(createdSpace.status, 201);
    const space = (await createdSpace.json()) as { id: string };

    const createdContainer = await app.request('/v1/containers', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ spaceId: space.id, visualType: 'box', name: 'Tools' }),
    });
    assert.equal(createdContainer.status, 201);
    const container = (await createdContainer.json()) as { id: string; shortCode: string };

    const createdItem = await app.request('/v1/items', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({
        containerId: container.id,
        name: 'Drill',
        category: 'Tools',
        tags: ['power'],
      }),
    });
    assert.equal(createdItem.status, 201);
    const item = (await createdItem.json()) as { id: string };

    const patched = await app.request(`/v1/items/${item.id}`, {
      method: 'PATCH',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ quantity: 2 }),
    });
    assert.equal(patched.status, 200);
    const updated = (await patched.json()) as { quantity: number };
    assert.equal(updated.quantity, 2);

    const search = await app.request('/v1/search?q=drill', { headers: auth });
    const results = (await search.json()) as { items: { id: string }[] };
    assert.equal(results.items[0]?.id, item.id);

    const qr = await app.request(`/v1/containers/${container.id}/qr`, {
      method: 'POST',
      headers: auth,
    });
    assert.equal(qr.status, 201);

    const listed = await app.request('/v1/spaces', { headers: auth });
    const listBody = (await listed.json()) as { spaces: { id: string; itemCount: number }[] };
    assert.equal(listBody.spaces[0]?.itemCount, 1);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('PATCH item with a stale updatedAt is a conflict', async () => {
  const { dir, control, app, auth } = await setup();
  try {
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
    const created = await app.request('/v1/items', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ containerId: container.id, name: 'Drill' }),
    });
    const item = (await created.json()) as { id: string; updatedAt: number };

    const first = await app.request(`/v1/items/${item.id}`, {
      method: 'PATCH',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Once', updatedAt: item.updatedAt }),
    });
    assert.equal(first.status, 200);
    const once = (await first.json()) as { updatedAt: number };

    const stale = await app.request(`/v1/items/${item.id}`, {
      method: 'PATCH',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Twice', updatedAt: 1 }),
    });
    assert.equal(stale.status, 409);
    const body = (await stale.json()) as { error: string; updatedAt: number };
    assert.equal(body.error, 'conflict');
    assert.equal(body.updatedAt, once.updatedAt);

    const stored = (await (
      await app.request(`/v1/items/${item.id}`, { headers: auth })
    ).json()) as { name: string };
    assert.equal(stored.name, 'Once');
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
