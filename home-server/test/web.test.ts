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
  await repos.items.create({ containerId: container.id, name: 'Cordless drill' });
  const app = createApp({
    control,
    publicOrigin: 'https://inventory.wystudio.be',
    repos,
    hub: createRevisionHub(),
    webPassword,
  });
  return { dir, control, app };
}

test('lookup page is absent until a web password is configured', async () => {
  const { dir, control, app } = await setup(null);
  try {
    assert.equal((await app.request('/')).status, 404);
    assert.equal((await app.request('/v1/web/login', { method: 'POST' })).status, 404);
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
    assert.match(await page.text(), /Look something up/);

    const denied = await app.request('/v1/web/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ password: 'nope' }),
    });
    assert.equal(denied.status, 401);
    assert.equal((await app.request('/v1/search?q=drill')).status, 401);

    const login = await app.request('/v1/web/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ password: PASSWORD }),
    });
    assert.equal(login.status, 200);
    const cookie = cookieFrom(login);

    const me = await app.request('/v1/web/me', { headers: { cookie } });
    assert.equal(me.status, 200);

    const found = await app.request('/v1/search?q=drill', { headers: { cookie } });
    assert.equal(found.status, 200);
    const body = (await found.json()) as { items: { name: string }[] };
    assert.equal(body.items[0]?.name, 'Cordless drill');

    const recent = await app.request('/v1/items?recent=1', { headers: { cookie } });
    assert.equal(recent.status, 200);
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
