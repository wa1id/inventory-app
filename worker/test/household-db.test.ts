import assert from 'node:assert/strict';
import { test } from 'node:test';

import { householdDbKey } from '../src/contract.ts';
import worker from '../src/index.ts';
import { makeEnv } from './fakeR2.ts';

const SNAPSHOT = '2026-08-21T01-00-00Z';
const SECRET = 'household-photo-secret';

function request(
  path: string,
  options: {
    method?: string;
    secret?: string;
    body?: BodyInit;
    headers?: Record<string, string>;
  } = {},
): Request {
  const headers = new Headers(options.headers);
  if (options.secret !== undefined) headers.set('authorization', `Bearer ${options.secret}`);
  return new Request(`https://sync.example${path}`, {
    method: options.method ?? 'GET',
    headers,
    body: options.body,
  });
}

test('household DB snapshots need the Worker secret and reject BOOTSTRAP.txt', async () => {
  const env = makeEnv({ HOUSEHOLD_PHOTO_SECRET: SECRET, SYNC_SHARED_SECRET: 'app-key' });
  const bytes = new Uint8Array([1, 2, 3, 4]);

  const missing = await worker.fetch(
    request(`/v1/household/db/${SNAPSHOT}/inventory.db`, {
      method: 'PUT',
      body: bytes as BodyInit,
    }),
    env,
  );
  assert.equal(missing.status, 401);

  const bootstrap = await worker.fetch(
    request(`/v1/household/db/${SNAPSHOT}/BOOTSTRAP.txt`, {
      method: 'PUT',
      secret: SECRET,
      body: bytes as BodyInit,
    }),
    env,
  );
  assert.equal(bootstrap.status, 400);
  assert.equal(env.BUCKET.objects.size, 0);

  const put = await worker.fetch(
    request(`/v1/household/db/${SNAPSHOT}/inventory.db`, {
      method: 'PUT',
      secret: SECRET,
      body: bytes as BodyInit,
    }),
    env,
  );
  assert.equal(put.status, 201);
  assert.equal(env.BUCKET.objects.has(householdDbKey(SNAPSHOT, 'inventory.db')), true);

  const got = await worker.fetch(
    request(`/v1/household/db/${SNAPSHOT}/inventory.db`, { secret: SECRET }),
    env,
  );
  assert.equal(got.status, 200);
  assert.deepEqual(new Uint8Array(await got.arrayBuffer()), bytes);
});

test('household DB list and delete stay under household/primary/db/', async () => {
  const env = makeEnv({ HOUSEHOLD_PHOTO_SECRET: SECRET });
  const inventory = new Uint8Array([1, 2]);
  const control = new Uint8Array([3, 4, 5]);

  await worker.fetch(
    request(`/v1/household/db/${SNAPSHOT}/inventory.db`, {
      method: 'PUT',
      secret: SECRET,
      body: inventory as BodyInit,
    }),
    env,
  );
  await worker.fetch(
    request(`/v1/household/db/${SNAPSHOT}/control.db`, {
      method: 'PUT',
      secret: SECRET,
      body: control as BodyInit,
    }),
    env,
  );

  const listed = await worker.fetch(request('/v1/household/db', { secret: SECRET }), env);
  assert.equal(listed.status, 200);
  const body = (await listed.json()) as {
    snapshots: { id: string; files: string[]; bytes: number }[];
  };
  assert.equal(body.snapshots.length, 1);
  assert.equal(body.snapshots[0]?.id, SNAPSHOT);
  assert.deepEqual(body.snapshots[0]?.files, ['control.db', 'inventory.db']);
  assert.equal(body.snapshots[0]?.bytes, 5);

  const deleted = await worker.fetch(
    request(`/v1/household/db/${SNAPSHOT}`, { method: 'DELETE', secret: SECRET }),
    env,
  );
  assert.equal(deleted.status, 204);
  for (const key of env.BUCKET.objects.keys()) {
    assert.equal(key.startsWith('household/primary/db/'), false);
    assert.equal(key.startsWith('photos/'), false);
  }
});
