import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createApp } from '../src/app.ts';
import { CONTRACT_VERSION } from '../src/contract.ts';

test('GET /v1/health reports only ok and contractVersion', async () => {
  const app = createApp();
  const response = await app.request('/v1/health');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type')?.startsWith('application/json'), true);

  const body = (await response.json()) as Record<string, unknown>;
  assert.deepEqual(Object.keys(body).sort(), ['contractVersion', 'ok']);
  assert.equal(body.ok, true);
  assert.equal(body.contractVersion, CONTRACT_VERSION);
});

test('unknown routes are 404', async () => {
  const app = createApp();
  const response = await app.request('/v1/status');
  assert.equal(response.status, 404);
});
