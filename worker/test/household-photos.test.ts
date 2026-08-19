import assert from 'node:assert/strict';
import { test } from 'node:test';

import { householdPhotoKey } from '../src/contract.ts';
import worker from '../src/index.ts';
import { makeEnv } from './fakeR2.ts';

const PHOTO_ID = '11111111-2222-4333-8444-555555555555';
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

test('household photos need the Worker secret, not a recovery code', async () => {
  const env = makeEnv({ HOUSEHOLD_PHOTO_SECRET: SECRET, SYNC_SHARED_SECRET: 'app-key' });
  const bytes = new Uint8Array([1, 2, 3, 4]);

  const missing = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}`, { method: 'PUT', body: bytes as BodyInit }),
    env,
  );
  assert.equal(missing.status, 401);

  const wrong = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}`, {
      method: 'PUT',
      secret: 'nope',
      body: bytes as BodyInit,
    }),
    env,
  );
  assert.equal(wrong.status, 401);

  const put = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}`, {
      method: 'PUT',
      secret: SECRET,
      body: bytes as BodyInit,
      headers: { 'content-type': 'image/webp' },
    }),
    env,
  );
  assert.equal(put.status, 201);
  assert.equal(env.BUCKET.objects.has(householdPhotoKey(PHOTO_ID, 'full')), true);

  const got = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}`, { secret: SECRET }),
    env,
  );
  assert.equal(got.status, 200);
  assert.equal(got.headers.get('content-type'), 'image/webp');
  assert.deepEqual(new Uint8Array(await got.arrayBuffer()), bytes);
});

test('household photos 503 when the Worker secret is unset', async () => {
  const env = makeEnv();
  const response = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}`, { secret: SECRET }),
    env,
  );
  assert.equal(response.status, 503);
});

test('household thumbs live next to the full object', async () => {
  const env = makeEnv({ HOUSEHOLD_PHOTO_SECRET: SECRET });
  const bytes = new Uint8Array([9, 8, 7]);

  const put = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}?kind=thumb`, {
      method: 'PUT',
      secret: SECRET,
      body: bytes as BodyInit,
      headers: { 'content-type': 'image/webp' },
    }),
    env,
  );
  assert.equal(put.status, 201);
  assert.equal(env.BUCKET.objects.has(householdPhotoKey(PHOTO_ID, 'thumb')), true);
  assert.equal(env.BUCKET.objects.has(householdPhotoKey(PHOTO_ID, 'full')), false);
});

test('household photos reject a bad id or kind without touching the bucket', async () => {
  const env = makeEnv({ HOUSEHOLD_PHOTO_SECRET: SECRET });
  const bytes = new Uint8Array([1]);

  const badId = await worker.fetch(
    request('/v1/household/photos/not-a-uuid', {
      method: 'PUT',
      secret: SECRET,
      body: bytes as BodyInit,
    }),
    env,
  );
  assert.equal(badId.status, 400);

  const badKind = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}?kind=original`, {
      method: 'PUT',
      secret: SECRET,
      body: bytes as BodyInit,
    }),
    env,
  );
  assert.equal(badKind.status, 400);
  assert.equal(env.BUCKET.objects.size, 0);
});

test('household photo delete is idempotent and does not share the account prefix', async () => {
  const env = makeEnv({ HOUSEHOLD_PHOTO_SECRET: SECRET });
  const bytes = new Uint8Array([1, 2]);

  await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}`, {
      method: 'PUT',
      secret: SECRET,
      body: bytes as BodyInit,
      headers: { 'content-type': 'image/webp' },
    }),
    env,
  );

  const deleted = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}`, { method: 'DELETE', secret: SECRET }),
    env,
  );
  assert.equal(deleted.status, 204);
  assert.equal(env.BUCKET.objects.has(householdPhotoKey(PHOTO_ID, 'full')), false);

  const again = await worker.fetch(
    request(`/v1/household/photos/${PHOTO_ID}`, { method: 'DELETE', secret: SECRET }),
    env,
  );
  assert.equal(again.status, 204);

  for (const key of env.BUCKET.objects.keys()) {
    assert.equal(key.startsWith('photos/'), false);
  }
});
