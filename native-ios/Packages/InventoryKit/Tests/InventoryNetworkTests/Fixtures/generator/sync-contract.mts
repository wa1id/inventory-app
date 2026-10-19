/**
 * Records the sync Worker's real answers (worker/src/index.ts over the in-memory
 * R2 bucket from worker/test/fakeR2.ts) for every call SyncClient makes, sending
 * each request with the headers src/services/sync/client.ts sends.
 *
 * Writes Tests/InventoryNetworkTests/Fixtures/sync-contract.json. To regenerate, in a worktree:
 *
 *   ln -s /home/walid/inventory-app/worker/node_modules worker/node_modules
 *   cd worker && node --import tsx \
 *     ../native-ios/Packages/InventoryKit/Tests/InventoryNetworkTests/Fixtures/generator/sync-contract.mts
 */
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { deriveAccountId } from '../../../../../../../worker/src/auth.ts';
import { encodeBase32 } from '../../../../../../../worker/src/base32.ts';
import { MAX_ACCOUNT_BYTES, MAX_PHOTO_BYTES, usageKey } from '../../../../../../../worker/src/contract.ts';
import worker from '../../../../../../../worker/src/index.ts';
import { makeEnv } from '../../../../../../../worker/test/fakeR2.ts';

const OUT = join(dirname(process.argv[1] ?? '.'), '..', 'sync-contract.json');
const ORIGIN = 'https://sync.example';
const APP_KEY = 'app-key';
const PHOTO_ID = '11111111-2222-4333-8444-555555555555';
const OTHER_PHOTO_ID = '99999999-8888-4777-8666-555555555555';
/** A WebP header and some bytes, as the stored photos are. */
const WEBP = Buffer.concat([Buffer.from('RIFF'), Buffer.from([0x20, 0, 0, 0]), Buffer.from('WEBPVP8 fake photo bytes')]);
const SNAPSHOT = Buffer.from('SQLite format 3\u0000 fake snapshot');

let clock = 1_767_225_600_000;
Date.now = () => (clock += 1000);

interface Exchange {
  request: { method: string; path: string; headers: Record<string, string>; base64: string | null };
  response: { status: number; headers: Record<string, string>; text: string | null; base64: string | null };
}

function codeFor(fill: number): string {
  return encodeBase32(new Uint8Array(16).fill(fill));
}

async function main(): Promise<void> {
  const env = makeEnv({ SYNC_SHARED_SECRET: APP_KEY });
  const code = codeFor(1);
  const exchanges: Record<string, Exchange> = {};

  /** The headers `send()` puts on every call, then the per-call ones. */
  function clientHeaders(options: { code?: string | null; key?: string | null; extra?: Record<string, string> }) {
    const headers: Record<string, string> = {};
    const bearer = options.code === undefined ? code : options.code;
    if (bearer) headers.Authorization = `Bearer ${bearer}`;
    headers['X-Contract-Version'] = '1';
    const key = options.key === undefined ? APP_KEY : options.key;
    if (key) headers['x-inventory-key'] = key;
    return { ...headers, ...options.extra };
  }

  async function record(
    name: string,
    method: string,
    path: string,
    options: {
      code?: string | null;
      key?: string | null;
      extra?: Record<string, string>;
      body?: Buffer;
      recordBody?: boolean;
    } = {},
  ): Promise<Response> {
    const headers = clientHeaders(options);
    const response = await worker.fetch(
      new Request(`${ORIGIN}${path}`, { method, headers, body: options.body }),
      env,
    );
    const buffer = Buffer.from(await response.clone().arrayBuffer());
    const type = response.headers.get('content-type') ?? '';
    const isText = type.includes('json');
    const responseHeaders: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      responseHeaders[key] = value;
    });
    exchanges[name] = {
      request: {
        method,
        path,
        headers,
        base64: options.body && options.recordBody !== false ? options.body.toString('base64') : null,
      },
      response: {
        status: response.status,
        headers: responseHeaders,
        text: isText ? buffer.toString('utf8') : null,
        base64: isText || buffer.length === 0 ? null : buffer.toString('base64'),
      },
    };
    return response;
  }

  const sha = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex');

  await record('health', 'GET', '/v1/health', { code: null });
  await record('missingKey', 'GET', `/v1/photos/${PHOTO_ID}`, { key: null });
  await record('wrongKey', 'GET', `/v1/photos/${PHOTO_ID}`, { key: 'nope' });
  await record('missingCode', 'GET', `/v1/photos/${PHOTO_ID}`, { code: null });
  await record('shortCode', 'GET', `/v1/photos/${PHOTO_ID}`, { code: encodeBase32(new Uint8Array(4).fill(7)) });

  await record('uploadPhoto', 'PUT', `/v1/photos/${PHOTO_ID}`, {
    extra: { 'Content-Type': 'image/webp' },
    body: WEBP,
  });
  await record('downloadPhoto', 'GET', `/v1/photos/${PHOTO_ID}`);
  await record('downloadPhotoMissing', 'GET', `/v1/photos/${OTHER_PHOTO_ID}`);
  await record('uploadPhotoUppercaseId', 'PUT', '/v1/photos/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE', {
    extra: { 'Content-Type': 'image/webp' },
    body: WEBP,
  });
  await record('uploadPhotoEmpty', 'PUT', `/v1/photos/${OTHER_PHOTO_ID}`, {
    extra: { 'Content-Type': 'image/jpeg' },
    body: Buffer.alloc(0),
  });
  await record('uploadPhotoTooLarge', 'PUT', `/v1/photos/${OTHER_PHOTO_ID}`, {
    extra: { 'Content-Type': 'image/jpeg' },
    body: Buffer.alloc(MAX_PHOTO_BYTES + 1, 0xff),
    recordBody: false,
  });
  await record('deletePhoto', 'DELETE', `/v1/photos/${PHOTO_ID}`);
  await record('deletePhotoAgain', 'DELETE', `/v1/photos/${PHOTO_ID}`);
  await record('photoMethodNotAllowed', 'POST', `/v1/photos/${PHOTO_ID}`);

  await record('latestWithoutBackups', 'GET', '/v1/backups/latest');
  await record('listWithoutBackups', 'GET', '/v1/backups');
  await record('uploadBackup', 'PUT', '/v1/backups', {
    extra: {
      'Content-Type': 'application/vnd.sqlite3',
      'x-snapshot-schema-version': '7',
      'x-snapshot-sha256': sha(SNAPSHOT),
    },
    body: SNAPSHOT,
  });
  await record('uploadOlderBackup', 'PUT', '/v1/backups', {
    extra: { 'Content-Type': 'application/vnd.sqlite3', 'x-snapshot-schema-version': '6' },
    body: SNAPSHOT,
  });
  await record('uploadBackupWithoutSchema', 'PUT', '/v1/backups', {
    extra: { 'Content-Type': 'application/vnd.sqlite3' },
    body: SNAPSHOT,
  });
  await record('uploadBackupBadChecksum', 'PUT', '/v1/backups', {
    extra: {
      'Content-Type': 'application/vnd.sqlite3',
      'x-snapshot-schema-version': '7',
      'x-snapshot-sha256': '0'.repeat(64),
    },
    body: SNAPSHOT,
  });
  await record('listBackups', 'GET', '/v1/backups');
  await record('downloadLatest', 'GET', '/v1/backups/latest');
  const first = JSON.parse(exchanges.uploadBackup?.response.text ?? '{}') as { id: string };
  await record('downloadById', 'GET', `/v1/backups/${first.id}`);
  await record('downloadInvalidId', 'GET', '/v1/backups/yesterday');
  await record('downloadMissingId', 'GET', '/v1/backups/1000000000000');
  await record('backupsMethodNotAllowed', 'DELETE', '/v1/backups');
  await record('usage', 'GET', '/v1/usage');
  await record('unknownRoute', 'GET', '/v1/anything');

  // An account at its limit: the next photo is refused with 507.
  const full = codeFor(2);
  const accountId = await deriveAccountId(new Uint8Array(16).fill(2));
  await env.BUCKET.put(usageKey(accountId), JSON.stringify({ bytes: MAX_ACCOUNT_BYTES - 4, objects: 1 }));
  await record('quotaExceeded', 'PUT', `/v1/photos/${PHOTO_ID}`, {
    code: full,
    extra: { 'Content-Type': 'image/webp' },
    body: WEBP,
  });

  writeFileSync(OUT, `${JSON.stringify({ origin: ORIGIN, code, appKey: APP_KEY, photoId: PHOTO_ID, exchanges }, null, 1)}\n`);
  console.log(`wrote ${Object.keys(exchanges).length} exchanges to ${OUT}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
