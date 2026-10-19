/**
 * Records the home server's real answers for every endpoint the app calls, so the
 * Swift HouseholdClient is tested against home-server/src, not against a guess.
 *
 * It drives `createApp` (home-server/src/app.ts) over a fresh SQLite household,
 * sending each request exactly as the RN client builds it, and writes
 * Tests/InventoryNetworkTests/Fixtures/household-contract.json. Ids and clocks are
 * seeded; the device tokens and the household code (from node:crypto) are
 * replaced by fixed placeholders.
 *
 * To regenerate, in a worktree:
 *
 *   ln -s /home/walid/inventory-app/home-server/node_modules home-server/node_modules
 *   cd home-server && node --import tsx \
 *     ../native-ios/Packages/InventoryKit/Tests/InventoryNetworkTests/Fixtures/generator/household-contract.mts
 */
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

import { configureRandomBytes } from '../../../../../../../src/core/id.ts';
import { initializeRepositories } from '../../../../../../../src/db/repositories.ts';
import { openNodeDatabase } from '../../../../../../../src/db/nodeDatabase.ts';
import { collectHouseholdDump } from '../../../../../../../src/services/household/collectDump.ts';
import { emptyDump } from '../../../../../../../src/services/household/dump.ts';
import { createApp } from '../../../../../../../home-server/src/app.ts';
import { openControlStore } from '../../../../../../../home-server/src/control.ts';
import { createRevisionHub } from '../../../../../../../home-server/src/hub.ts';
import { createMemoryPhotoStore } from '../../../../../../../home-server/src/photos.ts';

const OUT = join(dirname(process.argv[1] ?? '.'), '..', 'household-contract.json');
const ORIGIN = 'https://inventory.wystudio.be';
const TOKEN = '0123456789abcdef'.repeat(4);
const OTHER_TOKEN = 'fedcba9876543210'.repeat(4);
const CODE = 'MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S';

/** A 1×1 PNG, as home-server/test/photos.test.ts uses. */
const PIXEL = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

function lcg(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state;
  };
}

const next = lcg(20261019);
configureRandomBytes((count) => {
  const bytes = new Uint8Array(count);
  for (let i = 0; i < count; i += 1) bytes[i] = next() >>> 24;
  return bytes;
});

// Short codes come from Math.random (src/core/shortCode.ts).
const nextFloat = lcg(7);
Math.random = () => nextFloat() / 0x100000000;

let clock = 1_767_225_600_000;
Date.now = () => (clock += 1000);

interface Exchange {
  request: { method: string; path: string; headers: Record<string, string>; json: string | null; base64: string | null };
  response: { status: number; contentType: string | null; cacheControl: string | null; text: string | null; base64: string | null };
}

async function main(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-contract-'));
  const control = await openControlStore(join(dir, 'control.db'));
  const repos = await initializeRepositories(openNodeDatabase(join(dir, 'inventory.db')));
  const app = createApp({
    control,
    publicOrigin: ORIGIN,
    repos,
    hub: createRevisionHub(),
    photos: createMemoryPhotoStore(),
  });
  const secret = control.bootstrapSecretToPrint ?? '';
  const exchanges: Record<string, Exchange> = {};
  const ids: Record<string, string | number> = {};

  /** Sends a request the way householdFetch builds it, and records both sides. */
  async function record(
    name: string,
    method: string,
    path: string,
    options: { token?: string; json?: unknown; bytes?: Uint8Array } = {},
  ): Promise<any> {
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (options.json !== undefined) headers['Content-Type'] = 'application/json';
    if (options.bytes) headers['Content-Type'] = 'application/octet-stream';
    if (options.token) headers.Authorization = `Bearer ${options.token}`;
    const body = options.bytes ?? (options.json !== undefined ? JSON.stringify(options.json) : undefined);
    const response = await app.request(path, { method, headers, body });
    const buffer = Buffer.from(await response.arrayBuffer());
    const contentType = response.headers.get('content-type');
    const isText = !contentType || /json|text/.test(contentType);
    exchanges[name] = {
      request: {
        method,
        path,
        headers,
        json: options.json !== undefined ? JSON.stringify(options.json) : null,
        base64: options.bytes ? Buffer.from(options.bytes).toString('base64') : null,
      },
      response: {
        status: response.status,
        contentType,
        cacheControl: response.headers.get('cache-control'),
        text: isText ? buffer.toString('utf8') : null,
        base64: isText ? null : buffer.toString('base64'),
      },
    };
    if (!isText || buffer.length === 0) return null;
    try {
      return JSON.parse(buffer.toString('utf8'));
    } catch {
      return null;
    }
  }

  try {
    await record('health', 'GET', '/v1/health');

    // The RN client sends the name as typed; the server trims it.
    const paired = await record('pair', 'POST', '/v1/pair', {
      json: { bootstrapSecret: secret, deviceName: '  Kitchen iPhone  ' },
    });
    const token = paired.token as string;
    ids.deviceId = paired.deviceId;
    await record('pairRefused', 'POST', '/v1/pair', {
      json: { bootstrapSecret: 'AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-A', deviceName: 'Pixel' },
    });
    const other = await record('pairLowercase', 'POST', '/v1/pair', {
      json: { bootstrapSecret: secret.toLowerCase(), deviceName: 'Anna’s iPhone' },
    });
    const otherToken = other.token as string;
    ids.otherDeviceId = other.deviceId;

    await record('devices', 'GET', '/v1/devices', { token });
    await record('devicesUnauthorized', 'GET', '/v1/devices', { token: 'f'.repeat(64) });

    const garage = await record('createSpace', 'POST', '/v1/spaces', {
      token,
      json: { name: 'Garage', icon: '🧰', color: '#7A9E7E' },
    });
    ids.spaceId = garage.id;
    await record('createSpaceInvalid', 'POST', '/v1/spaces', { token, json: { name: '', icon: 'x', color: 'y' } });
    const attic = await record('createSecondSpace', 'POST', '/v1/spaces', {
      token,
      json: { name: 'Attic', icon: '📦', color: '#B07A5B' },
    });
    ids.secondSpaceId = attic.id;
    await record('getSpace', 'GET', `/v1/spaces/${garage.id}`, { token });
    await record('getSpaceMissing', 'GET', '/v1/spaces/nope', { token });
    await record('updateSpace', 'PATCH', `/v1/spaces/${garage.id}`, { token, json: { name: 'Big garage' } });
    await record('updateSpaceMissing', 'PATCH', '/v1/spaces/nope', { token, json: { name: 'x' } });
    await record('updateDropZoneSpace', 'PATCH', '/v1/spaces/drop-zone-space', { token, json: { name: 'x' } });

    const chest = await record('createContainer', 'POST', '/v1/containers', {
      token,
      json: { spaceId: garage.id, visualType: 'box', name: 'Tool chest' },
    });
    ids.containerId = chest.id;
    const drawer = await record('createContainerUnnamed', 'POST', '/v1/containers', {
      token,
      json: { spaceId: garage.id, visualType: 'drawer' },
    });
    ids.secondContainerId = drawer.id;
    await record('getContainer', 'GET', `/v1/containers/${chest.id}`, { token });
    await record('getContainerMissing', 'GET', '/v1/containers/nope', { token });
    await record('updateContainerClearName', 'PATCH', `/v1/containers/${chest.id}`, { token, json: { name: null } });
    await record('updateContainerMove', 'PATCH', `/v1/containers/${drawer.id}`, {
      token,
      json: { name: 'Bits', visualType: 'bin', spaceId: attic.id },
    });

    const uploadId = '1b4e28ba-2fa1-4d2b-883f-0016d3cca427';
    ids.uploadPhotoId = uploadId;
    const prepared = await record('uploadPhoto', 'PUT', `/v1/photos/${uploadId}`, { token, bytes: PIXEL });
    await record('uploadPhotoInvalidId', 'PUT', '/v1/photos/not-a-uuid', { token, bytes: PIXEL });
    await record('uploadPhotoEmpty', 'PUT', `/v1/photos/${uploadId}`, { token, bytes: new Uint8Array(0) });

    const drill = await record('createItem', 'POST', '/v1/items', {
      token,
      json: {
        containerId: chest.id,
        name: 'Cordless Drill',
        category: 'Power Tools',
        quantity: 2,
        tags: ['dewalt', '18v'],
        photo: prepared,
      },
    });
    ids.itemId = drill.id;
    ids.itemUpdatedAt = drill.updatedAt;
    const unnamed = await record('createItemUnnamed', 'POST', '/v1/items', { token, json: { containerId: 'drop-zone' } });
    ids.unnamedItemId = unnamed.id;
    await record('createItemBlankName', 'POST', '/v1/items', { token, json: { containerId: chest.id, name: '   ' } });
    await record('createItemMissingPhoto', 'POST', '/v1/items', {
      token,
      json: {
        containerId: chest.id,
        name: 'Ghost',
        photo: { id: '00000000-0000-4000-8000-000000000000', uri: 'r2:household/primary/photos/x.webp' },
      },
    });

    await record('getItem', 'GET', `/v1/items/${drill.id}`, { token });
    await record('getItemMissing', 'GET', '/v1/items/nope', { token });
    await record('listSpaces', 'GET', '/v1/spaces', { token });
    await record('listContainersBySpace', 'GET', `/v1/containers?spaceId=${encodeURIComponent(garage.id)}`, { token });
    await record('listAllContainers', 'GET', '/v1/containers', { token });
    await record('listItemsByContainer', 'GET', `/v1/items?containerId=${encodeURIComponent(chest.id)}`, { token });
    await record('listUnsorted', 'GET', '/v1/items?unsorted=1', { token });
    await record('listRecent', 'GET', `/v1/items?recent=1&limit=${encodeURIComponent(String(40))}`, { token });

    const updated = await record('updateItem', 'PATCH', `/v1/items/${drill.id}`, {
      token,
      json: {
        name: 'Hammer drill',
        category: null,
        quantity: 3,
        notes: 'Left shelf',
        tags: ['bosch'],
        updatedAt: drill.updatedAt,
      },
    });
    ids.updatedAt = updated.updatedAt;
    await record('updateItemConflict', 'PATCH', `/v1/items/${drill.id}`, {
      token,
      json: { name: 'Stale', updatedAt: drill.updatedAt },
    });
    await record('updateItemQuantityZero', 'PATCH', `/v1/items/${drill.id}`, { token, json: { quantity: 0 } });
    await record('updateItemMove', 'PATCH', `/v1/items/${unnamed.id}`, { token, json: { containerId: drawer.id } });
    await record('updateItemMissing', 'PATCH', '/v1/items/nope', { token, json: { name: 'x' } });

    await record('search', 'GET', `/v1/search?q=${encodeURIComponent('drill')}`, { token });
    await record('searchLocation', 'GET', `/v1/search?q=${encodeURIComponent('Big garage')}`, { token });
    await record('searchEmpty', 'GET', `/v1/search?q=${encodeURIComponent('')}`, { token });

    const label = await record('createLabel', 'POST', `/v1/containers/${chest.id}/qr`, { token });
    ids.labelToken = label.token;
    await record('scanBound', 'POST', '/v1/qr/scan', { token, json: { raw: `inventory://c/${label.token}` } });
    await record('scanUnknown', 'POST', '/v1/qr/scan', { token, json: { raw: 'ab'.repeat(16) } });
    await record('scanInvalid', 'POST', '/v1/qr/scan', { token, json: { raw: 'hello' } });
    const printed = 'cd'.repeat(16);
    ids.printedToken = printed;
    await record('bindLabel', 'POST', '/v1/qr/bind', { token, json: { token: printed, containerId: drawer.id } });
    await record('bindLabelDropZone', 'POST', '/v1/qr/bind', {
      token,
      json: { token: 'ef'.repeat(16), containerId: 'drop-zone' },
    });
    await record('unbindLabel', 'DELETE', `/v1/containers/${chest.id}/qr`, { token });
    await record('unbindLabelMissing', 'DELETE', `/v1/containers/${chest.id}/qr`, { token });

    await record('getPhotoThumb', 'GET', `/v1/photos/${encodeURIComponent(uploadId)}?thumb=1`, { token });
    await record('getPhotoFull', 'GET', `/v1/photos/${encodeURIComponent(uploadId)}`, { token });
    await record('getPhotoMissing', 'GET', `/v1/photos/${encodeURIComponent('00000000-0000-4000-8000-000000000000')}`, {
      token,
    });

    await record('deleteItem', 'DELETE', `/v1/items/${drill.id}`, { token });
    await record('deleteItemMissing', 'DELETE', `/v1/items/${drill.id}`, { token });
    await record('deleteContainer', 'DELETE', `/v1/containers/${drawer.id}`, { token });
    await record('deleteContainerMissing', 'DELETE', `/v1/containers/${drawer.id}`, { token });
    await record('deleteSpace', 'DELETE', `/v1/spaces/${attic.id}`, { token });
    await record('deleteSpaceMissing', 'DELETE', `/v1/spaces/${attic.id}`, { token });

    // A phone's own inventory, collected exactly as importHousehold.ts does.
    const local = await initializeRepositories(openNodeDatabase(':memory:'));
    const shelf = await local.spaces.create({ name: 'Shed', icon: '🪴', color: '#6B8E23' });
    const crate = await local.containers.create({ spaceId: shelf.id, visualType: 'crate', name: 'Seeds' });
    await local.items.create({
      containerId: crate.id,
      name: 'Tomato seeds',
      quantity: 0,
      tags: ['garden'],
      photo: { uri: 'file:///photos/seeds.webp', width: 1, height: 1, byteSize: PIXEL.length },
    });
    const dump = await collectHouseholdDump(local.db);
    // Migration 3 seeds the drop zone with SQLite's own clock; pin it so the fixture is stable.
    for (const row of [...dump.spaces, ...dump.containers]) {
      if (row.kind === 'system') {
        row.createdAt = 1_767_225_600_000;
        row.updatedAt = 1_767_225_600_000;
      }
    }
    ids.importPhotoId = dump.photos[0]?.id ?? '';
    await record('import', 'POST', '/v1/import', { token, json: dump });
    await record('importPhoto', 'PUT', `/v1/photos/${encodeURIComponent(String(ids.importPhotoId))}`, {
      token,
      bytes: PIXEL,
    });

    await record('revokeDevice', 'DELETE', `/v1/devices/${encodeURIComponent(String(ids.otherDeviceId))}`, { token });
    await record('revokeDeviceMissing', 'DELETE', `/v1/devices/${encodeURIComponent(String(ids.otherDeviceId))}`, {
      token,
    });
    await record('revokedTokenRefused', 'GET', '/v1/spaces', { token: otherToken });
    await record('unknownRoute', 'GET', '/v1/nope', { token });

    // A photo row whose dimensions are NULL, as DumpPhoto allows: JSON.stringify sends
    // explicit nulls, which the importer binds as SQL NULL. Leaving the keys out instead
    // (what a synthesized Swift Encodable does with nil) binds `undefined`, which
    // node:sqlite refuses, failing the whole import (importer.ts:174-176).
    const nullPhotoId = '2c5f0a8e-7d1b-4e3a-9f6c-0b8d7e6a5f41';
    ids.nullPhotoId = nullPhotoId;
    const nullPhoto = {
      id: nullPhotoId,
      itemId: dump.items[0]?.id ?? '',
      width: null,
      height: null,
      byteSize: null,
      createdAt: 1_767_225_600_000,
    };
    await record('importNullPhotoFields', 'POST', '/v1/import', {
      token,
      json: { ...emptyDump(), photos: [nullPhoto] },
    });
    const { width: _w, height: _h, byteSize: _b, ...omitted } = nullPhoto;
    await record('importOmittedPhotoFields', 'POST', '/v1/import', {
      token,
      json: { ...emptyDump(), photos: [omitted] },
    });

    let text = JSON.stringify({ origin: ORIGIN, token: TOKEN, ids, exchanges }, null, 1);
    text = text.split(token).join(TOKEN).split(otherToken).join(OTHER_TOKEN);
    text = text.split(secret.toLowerCase()).join(CODE.toLowerCase()).split(secret).join(CODE);
    writeFileSync(OUT, `${text}\n`);
    console.log(`wrote ${Object.keys(exchanges).length} exchanges to ${OUT}`);
  } finally {
    await control.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
