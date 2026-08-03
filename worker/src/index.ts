import { authenticate } from './auth.ts';
import {
  MAX_ACCOUNT_BYTES,
  MAX_BACKUP_BYTES,
  MAX_PHOTO_BYTES,
  SYNC_CONTRACT_VERSION,
  backupKey,
  backupPrefix,
  isValidBackupId,
  isValidPhotoId,
  photoKey,
} from './contract.ts';
import type { BackupListResponse, BackupSummary, UsageResponse } from './contract.ts';
import { applyUsageDelta, checkQuota, existingSize, pruneBackups, readUsage } from './storage.ts';

/**
 * Photo and backup storage for the Inventory app.
 *
 * Every object lives under a prefix derived from the caller's recovery code, so
 * account isolation is a property of the key, not of a lookup that could be
 * skipped. There is no route that takes an account id as input — the only way
 * to name a prefix is to hold the code that hashes to it.
 */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      // Never surface an internal message: it can carry a key or a stack.
      console.error('unhandled_error', error instanceof Error ? error.name : 'unknown');
      return json({ error: 'Storage is temporarily unavailable.' }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, '');

  if (path === '/v1/health') {
    return json({ ok: true, contractVersion: SYNC_CONTRACT_VERSION });
  }

  const auth = await authenticate(request, env);
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  const accountId = auth.account.id;

  const photoMatch = /^\/v1\/photos\/([^/]+)$/.exec(path);
  if (photoMatch) {
    const photoId = decodeURIComponent(photoMatch[1] as string);
    if (!isValidPhotoId(photoId)) return json({ error: 'Invalid photo id.' }, 400);
    return handlePhoto(request, env, accountId, photoId);
  }

  if (path === '/v1/backups') {
    if (request.method === 'PUT') return putBackup(request, env, accountId);
    if (request.method === 'GET') return listBackups(env, accountId);
    return json({ error: 'Method not allowed.' }, 405);
  }

  const backupMatch = /^\/v1\/backups\/([^/]+)$/.exec(path);
  if (backupMatch && request.method === 'GET') {
    return getBackup(env, accountId, decodeURIComponent(backupMatch[1] as string));
  }

  if (path === '/v1/usage' && request.method === 'GET') {
    const usage = await readUsage(env, accountId);
    return json({
      contractVersion: SYNC_CONTRACT_VERSION,
      bytes: usage.bytes,
      objects: usage.objects,
      limitBytes: MAX_ACCOUNT_BYTES,
    } satisfies UsageResponse);
  }

  return json({ error: 'Not found.' }, 404);
}

async function handlePhoto(
  request: Request,
  env: Env,
  accountId: string,
  photoId: string,
): Promise<Response> {
  const key = photoKey(accountId, photoId);

  if (request.method === 'GET') {
    const object = await env.BUCKET.get(key);
    if (!object) return json({ error: 'Not found.' }, 404);
    return new Response(object.body, {
      headers: {
        // Objects stored before photos moved to WebP carry no recorded type;
        // JPEG is what those bytes actually are.
        'content-type': object.httpMetadata?.contentType ?? 'image/jpeg',
        'content-length': String(object.size),
        etag: object.httpEtag,
        'cache-control': 'private, max-age=31536000, immutable',
      },
    });
  }

  if (request.method === 'PUT') {
    const body = await readBody(request, MAX_PHOTO_BYTES);
    if (!body.ok) return json({ error: body.error }, body.status);

    // Re-uploading an existing photo replaces it, so quota must account for the
    // bytes being freed or a retry would count the photo twice.
    const replacing = await existingSize(env, key);
    const quota = await checkQuota(env, accountId, body.bytes.byteLength, replacing);
    if (!quota.ok) return json({ error: quota.error }, 507);

    await env.BUCKET.put(key, body.bytes, {
      httpMetadata: { contentType: photoContentType(request) },
    });
    await applyUsageDelta(env, accountId, body.bytes.byteLength - replacing, replacing > 0 ? 0 : 1);

    return json({ id: photoId, size: body.bytes.byteLength }, 201);
  }

  if (request.method === 'DELETE') {
    const replacing = await existingSize(env, key);
    await env.BUCKET.delete(key);
    if (replacing > 0) await applyUsageDelta(env, accountId, -replacing, -1);
    // 204 whether or not it existed: deleting an already-deleted photo is the
    // caller getting what it wanted, and the app retries cleanup best-effort.
    return new Response(null, { status: 204 });
  }

  return json({ error: 'Method not allowed.' }, 405);
}

async function putBackup(request: Request, env: Env, accountId: string): Promise<Response> {
  const body = await readBody(request, MAX_BACKUP_BYTES);
  if (!body.ok) return json({ error: body.error }, body.status);

  const schemaVersion = Number(request.headers.get('x-snapshot-schema-version') ?? '0');
  if (!Number.isInteger(schemaVersion) || schemaVersion < 1) {
    return json({ error: 'Missing or invalid schema version.' }, 400);
  }

  const quota = await checkQuota(env, accountId, body.bytes.byteLength, 0);
  if (!quota.ok) return json({ error: quota.error }, 507);

  /*
   * The snapshot id is server time, not the client's.
   *
   * A phone with a wrong clock would otherwise write a snapshot dated 1970,
   * which retention would immediately prune as the oldest — the newest backup
   * deleting itself on arrival. Server time makes ordering a property of the
   * service rather than of whatever the device believes.
   */
  const capturedAt = Date.now();
  const key = backupKey(accountId, String(capturedAt));

  // An end-to-end checksum when the client can produce one: R2 rejects the put
  // if the bytes it received do not hash to what the client says it sent.
  const declared = request.headers.get('x-snapshot-sha256')?.trim().toLowerCase();
  const options: R2PutOptions = {
    httpMetadata: { contentType: 'application/vnd.sqlite3' },
    customMetadata: { schemaVersion: String(schemaVersion) },
  };
  if (declared && /^[0-9a-f]{64}$/.test(declared)) options.sha256 = declared;

  try {
    await env.BUCKET.put(key, body.bytes, options);
  } catch (error) {
    // The checksum mismatch path: the upload was corrupted in transit.
    console.error('backup_put_failed', error instanceof Error ? error.name : 'unknown');
    return json({ error: 'Snapshot failed its integrity check.' }, 422);
  }

  await applyUsageDelta(env, accountId, body.bytes.byteLength, 1);
  await pruneBackups(env, accountId);

  return json(
    {
      id: String(capturedAt),
      size: body.bytes.byteLength,
      capturedAt,
      schemaVersion,
    } satisfies BackupSummary,
    201,
  );
}

async function listBackups(env: Env, accountId: string): Promise<Response> {
  const prefix = backupPrefix(accountId);
  const backups: BackupSummary[] = [];

  let cursor: string | undefined;
  do {
    const page = await env.BUCKET.list({
      prefix,
      cursor,
      limit: 1000,
      include: ['customMetadata'],
    });
    for (const object of page.objects) {
      const id = object.key.slice(prefix.length).replace(/\.db$/, '');
      if (!isValidBackupId(id)) continue;
      backups.push({
        id,
        size: object.size,
        capturedAt: Number(id),
        schemaVersion: Number(object.customMetadata?.schemaVersion ?? 0),
      });
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);

  backups.sort((a, b) => b.capturedAt - a.capturedAt);

  return json({ contractVersion: SYNC_CONTRACT_VERSION, backups } satisfies BackupListResponse);
}

async function getBackup(env: Env, accountId: string, backupId: string): Promise<Response> {
  let key: string;

  if (backupId === 'latest') {
    const listed = await listBackups(env, accountId);
    const { backups } = (await listed.json()) as BackupListResponse;
    const newest = backups[0];
    if (!newest) return json({ error: 'No backups yet.' }, 404);
    key = backupKey(accountId, newest.id);
  } else {
    if (!isValidBackupId(backupId)) return json({ error: 'Invalid backup id.' }, 400);
    key = backupKey(accountId, backupId);
  }

  const object = await env.BUCKET.get(key);
  if (!object) return json({ error: 'Not found.' }, 404);

  return new Response(object.body, {
    headers: {
      'content-type': 'application/vnd.sqlite3',
      'content-length': String(object.size),
      etag: object.httpEtag,
      'x-snapshot-schema-version': object.customMetadata?.schemaVersion ?? '0',
      'x-snapshot-captured-at': key.slice(backupPrefix(accountId).length).replace(/\.db$/, ''),
    },
  });
}

/**
 * The image type the client says it is sending, restricted to an allowlist.
 *
 * Taken from the request rather than assumed, because the app's encoder has
 * changed once already and will again. Restricted rather than echoed, because
 * a caller-supplied content type is served straight back to whoever fetches
 * the object — echoing it unchecked would let one be stored that a browser
 * renders as something other than an image.
 */
const ALLOWED_PHOTO_TYPES = new Set(['image/jpeg', 'image/webp', 'image/png']);

function photoContentType(request: Request): string {
  const declared = request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase();
  return declared && ALLOWED_PHOTO_TYPES.has(declared) ? declared : 'image/jpeg';
}

type BodyResult = { ok: true; bytes: Uint8Array } | { ok: false; status: number; error: string };

/**
 * Reads and size-checks a request body.
 *
 * `content-length` is checked first so an oversized upload is refused before it
 * is streamed, but the buffered length is checked again afterwards — the header
 * is caller-supplied and a lie there would otherwise be the way past the limit.
 */
async function readBody(request: Request, limit: number): Promise<BodyResult> {
  const declared = Number(request.headers.get('content-length') ?? 'NaN');
  if (Number.isFinite(declared) && declared > limit) {
    return { ok: false, status: 413, error: 'Upload is too large.' };
  }

  const buffer = await request.arrayBuffer();
  if (buffer.byteLength === 0) {
    return { ok: false, status: 400, error: 'Empty upload.' };
  }
  if (buffer.byteLength > limit) {
    return { ok: false, status: 413, error: 'Upload is too large.' };
  }

  return { ok: true, bytes: new Uint8Array(buffer) };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}
