import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { randomFillSync } from 'node:crypto';

import { configureRandomBytes } from '../../src/core/id.ts';

import { createApp } from '../src/app.ts';
import { CONTRACT_VERSION, HOUSEHOLD_NAME } from '../src/contract.ts';
import { openControlStore } from '../src/control.ts';

configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

const ORIGIN = 'https://inventory.wystudio.be';

async function setup() {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-pair-'));
  const control = await openControlStore(join(dir, 'control.db'));
  const app = createApp({ control, publicOrigin: ORIGIN });
  return { dir, control, app };
}

test('first open of control.db prints a bootstrap secret once', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-pair-'));
  try {
    const first = await openControlStore(join(dir, 'control.db'));
    assert.ok(first.bootstrapSecretToPrint);
    assert.match(first.bootstrapSecretToPrint, /^[0-9A-HJKMNP-TV-Z-]{20,}$/);
    await first.close();

    const second = await openControlStore(join(dir, 'control.db'));
    assert.equal(second.bootstrapSecretToPrint, null);
    await second.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('pairing with the bootstrap secret issues a device token', async () => {
  const { dir, control, app } = await setup();
  try {
    const secret = control.bootstrapSecretToPrint;
    assert.ok(secret);

    const response = await app.request('/v1/pair', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ bootstrapSecret: secret, deviceName: 'Pixel' }),
    });
    assert.equal(response.status, 200);
    const body = (await response.json()) as Record<string, unknown>;
    assert.equal(body.origin, ORIGIN);
    assert.equal(body.householdName, HOUSEHOLD_NAME);
    assert.equal(body.contractVersion, CONTRACT_VERSION);
    assert.equal(typeof body.token, 'string');
    assert.equal(typeof body.deviceId, 'string');
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('pairing rejects a wrong secret', async () => {
  const { dir, control, app } = await setup();
  try {
    const response = await app.request('/v1/pair', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        bootstrapSecret: 'AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-A',
        deviceName: 'Pixel',
      }),
    });
    assert.equal(response.status, 401);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('session and device list require a bearer token', async () => {
  const { dir, control, app } = await setup();
  try {
    assert.equal((await app.request('/v1/session')).status, 401);
    assert.equal((await app.request('/v1/devices')).status, 401);

    const secret = control.bootstrapSecretToPrint!;
    const paired = await app.request('/v1/pair', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ bootstrapSecret: secret.toLowerCase(), deviceName: ' Pixel ' }),
    });
    const { token, deviceId } = (await paired.json()) as { token: string; deviceId: string };

    const session = await app.request('/v1/session', {
      headers: { Authorization: `Bearer ${token}` },
    });
    assert.equal(session.status, 200);
    const sessionBody = (await session.json()) as Record<string, unknown>;
    assert.equal(sessionBody.deviceId, deviceId);
    assert.equal(sessionBody.deviceName, 'Pixel');

    const list = await app.request('/v1/devices', {
      headers: { Authorization: `Bearer ${token}` },
    });
    const listBody = (await list.json()) as { devices: { id: string }[] };
    assert.equal(listBody.devices.length, 1);
    assert.equal(listBody.devices[0]?.id, deviceId);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('any paired device may revoke any other', async () => {
  const { dir, control, app } = await setup();
  try {
    const secret = control.bootstrapSecretToPrint!;
    async function pair(name: string) {
      const response = await app.request('/v1/pair', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ bootstrapSecret: secret, deviceName: name }),
      });
      return (await response.json()) as { token: string; deviceId: string };
    }

    const a = await pair('Phone A');
    const b = await pair('Phone B');

    const revoked = await app.request(`/v1/devices/${b.deviceId}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${a.token}` },
    });
    assert.equal(revoked.status, 204);

    assert.equal(
      (await app.request('/v1/session', { headers: { Authorization: `Bearer ${b.token}` } }))
        .status,
      401,
    );
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('health stays unauthenticated and leak-free', async () => {
  const { dir, control, app } = await setup();
  try {
    const response = await app.request('/v1/health');
    const body = (await response.json()) as Record<string, unknown>;
    assert.deepEqual(Object.keys(body).sort(), ['contractVersion', 'ok']);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
