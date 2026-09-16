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
import { passwordMatches, WEB_COOKIE } from '../src/web.ts';

configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

const PASSWORD = 'test-web-password';

function cookieFrom(response: Response): string {
  const raw = response.headers.get('set-cookie') ?? '';
  const match = new RegExp(`${WEB_COOKIE}=([^;]+)`).exec(raw);
  assert.ok(match?.[1], 'login must set a session cookie');
  return `${WEB_COOKIE}=${match[1]}`;
}

async function setup(webPassword: string | null = PASSWORD) {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-web-'));
  const control = await openControlStore(join(dir, 'control.db'));
  const repos = await initializeRepositories(openNodeDatabase(join(dir, 'inventory.db')));
  const space = await repos.spaces.create({ name: 'Garage', icon: '🚗', color: '#5B8DEF' });
  const container = await repos.containers.create({
    spaceId: space.id,
    visualType: 'box',
    name: 'Tools',
  });
  const item = await repos.items.create({ containerId: container.id, name: 'Cordless drill' });
  const app = createApp({
    control,
    publicOrigin: 'https://inventory.wystudio.be',
    repos,
    hub: createRevisionHub(),
    webPassword,
  });
  return { dir, control, app, repos, space, container, item };
}

async function login(app: ReturnType<typeof createApp>): Promise<string> {
  const response = await app.request('/v1/web/login', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ password: PASSWORD }),
  });
  assert.equal(response.status, 200);
  return cookieFrom(response);
}

test('lookup page is absent until a web password is configured', async () => {
  const { dir, control, app } = await setup(null);
  try {
    assert.equal((await app.request('/')).status, 404);
    assert.equal((await app.request('/v1/web/login', { method: 'POST' })).status, 404);
    assert.equal((await app.request('/app.js')).status, 404);
    assert.equal((await app.request('/item/anything')).status, 404);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('password login unlocks search and rejects a wrong password', async () => {
  const { dir, control, app } = await setup();
  try {
    const page = await app.request('/');
    assert.equal(page.status, 200);
    const html = await page.text();
    assert.match(html, /Look something up/);
    assert.match(html, /Adding still happens on the phone/);
    assert.match(html, /id="space-view"/);
    assert.match(html, /id="container-view"/);
    assert.match(html, /id="edit-form"/);
    assert.match(html, /novalidate/);
    assert.match(html, /id="edit-quantity"/);
    assert.match(html, /min="0"/);
    assert.match(html, /id="edit-qty-dec"/);
    assert.match(html, /id="edit-qty-inc"/);
    assert.match(html, /id="move-panel"/);

    const denied = await app.request('/v1/web/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ password: 'nope' }),
    });
    assert.equal(denied.status, 401);
    assert.equal((await app.request('/v1/search?q=drill')).status, 401);

    const cookie = await login(app);

    const me = await app.request('/v1/web/me', { headers: { cookie } });
    assert.equal(me.status, 200);

    const found = await app.request('/v1/search?q=drill', { headers: { cookie } });
    assert.equal(found.status, 200);
    const body = (await found.json()) as { items: { name: string }[]; locations: unknown[] };
    assert.equal(body.items[0]?.name, 'Cordless drill');
    assert.ok(Array.isArray(body.locations));

    const recent = await app.request('/v1/items?recent=1', { headers: { cookie } });
    assert.equal(recent.status, 200);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('desk page assets and browse routes are served with the lookup page', async () => {
  const { dir, control, app } = await setup();
  try {
    const css = await app.request('/app.css');
    assert.equal(css.status, 200);
    assert.match(css.headers.get('content-type') ?? '', /text\/css/);
    assert.match(await css.text(), /--tape/);

    const js = await app.request('/app.js');
    assert.equal(js.status, 200);
    assert.match(js.headers.get('content-type') ?? '', /javascript/);
    const jsText = await js.text();
    assert.match(jsText, /parseRoute/);
    assert.match(jsText, /stepSavedQuantity/);
    assert.match(jsText, /data-qty-item/);

    for (const path of ['/item/anything', '/space/anything', '/container/anything']) {
      const page = await app.request(path);
      assert.equal(page.status, 200, path);
      assert.match(await page.text(), /Look something up/);
    }
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('web session can browse and patch items', async () => {
  const { dir, control, app, repos, space, item } = await setup();
  try {
    const cookie = await login(app);
    const headers = { cookie, 'content-type': 'application/json' };

    const spaces = await app.request('/v1/spaces', { headers: { cookie } });
    assert.equal(spaces.status, 200);
    const spaceList = (await spaces.json()) as { spaces: { name: string }[] };
    assert.equal(spaceList.spaces[0]?.name, 'Garage');

    const containers = await app.request('/v1/containers', { headers: { cookie } });
    assert.equal(containers.status, 200);
    const containerList = (await containers.json()) as { containers: { name: string | null }[] };
    assert.equal(containerList.containers[0]?.name, 'Tools');

    const placeSearch = await app.request('/v1/search?q=Garage', { headers: { cookie } });
    assert.equal(placeSearch.status, 200);
    const hits = (await placeSearch.json()) as { locations: { kind: string; title: string }[] };
    assert.ok(hits.locations.some((row) => row.kind === 'space' && row.title === 'Garage'));

    const current = await repos.items.getById(item.id);
    assert.ok(current);

    const renamed = await app.request(`/v1/items/${item.id}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ name: 'Impact drill', updatedAt: current.updatedAt }),
    });
    assert.equal(renamed.status, 200);
    const afterName = (await renamed.json()) as { name: string; updatedAt: number };
    assert.equal(afterName.name, 'Impact drill');

    const emptied = await app.request(`/v1/items/${item.id}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ quantity: 0, updatedAt: afterName.updatedAt }),
    });
    assert.equal(emptied.status, 200);
    const afterQty = (await emptied.json()) as { quantity: number; updatedAt: number };
    assert.equal(afterQty.quantity, 0);

    const shelf = await repos.containers.create({
      spaceId: space.id,
      visualType: 'shelf',
      name: 'Wall shelf',
    });
    const moved = await app.request(`/v1/items/${item.id}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({
        containerId: shelf.id,
        updatedAt: afterQty.updatedAt,
      }),
    });
    assert.equal(moved.status, 200);
    const afterMove = (await moved.json()) as { containerId: string };
    assert.equal(afterMove.containerId, shelf.id);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('passwordMatches is length-safe and case-sensitive', () => {
  assert.equal(passwordMatches('abc', 'abc'), true);
  assert.equal(passwordMatches('abc', 'ABC'), false);
  assert.equal(passwordMatches('abc', 'ab'), false);
});
