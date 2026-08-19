import sharp from 'sharp';

import { newId } from '../../src/core/id.ts';

import { DEFAULT_PHOTO_WORKER_ORIGIN } from './contract.ts';

/** Match the app: long edge 1400, thumbs 320. See src/services/capture/imageScaling.ts. */
const MAX_EDGE = 1400;
const THUMB_EDGE = 320;

export type PhotoKind = 'full' | 'thumb';

export interface PhotoStore {
  put(id: string, kind: PhotoKind, bytes: Uint8Array, contentType: string): Promise<void>;
  get(id: string, kind: PhotoKind): Promise<{ bytes: Uint8Array; contentType: string } | null>;
}

export interface PreparedPhoto {
  id: string;
  uri: string;
  thumbUri: string;
  width: number;
  height: number;
  byteSize: number;
}

export function r2ObjectKey(id: string, kind: PhotoKind): string {
  const suffix = kind === 'thumb' ? '-thumb.webp' : '.webp';
  return `household/primary/photos/${id}${suffix}`;
}

export async function preparePhoto(input: Uint8Array, store: PhotoStore): Promise<PreparedPhoto> {
  return preparePhotoWithId(newId(), input, store);
}

/** Import path: keep the phone's photo id so item_photos rows still match. */
export async function preparePhotoWithId(
  id: string,
  input: Uint8Array,
  store: PhotoStore,
): Promise<PreparedPhoto> {
  const image = sharp(input).rotate();
  const full = await image
    .clone()
    .resize({
      width: MAX_EDGE,
      height: MAX_EDGE,
      fit: 'inside',
      withoutEnlargement: true,
    })
    .webp({ quality: 80 })
    .toBuffer({ resolveWithObject: true });

  const thumb = await image
    .clone()
    .resize({ width: THUMB_EDGE, height: THUMB_EDGE, fit: 'cover' })
    .webp({ quality: 70 })
    .toBuffer({ resolveWithObject: true });

  await store.put(id, 'full', full.data, 'image/webp');
  await store.put(id, 'thumb', thumb.data, 'image/webp');

  return {
    id,
    uri: `r2:${r2ObjectKey(id, 'full')}`,
    thumbUri: `r2:${r2ObjectKey(id, 'thumb')}`,
    width: full.info.width,
    height: full.info.height,
    byteSize: full.data.byteLength,
  };
}

export function createMemoryPhotoStore(): PhotoStore {
  const objects = new Map<string, { bytes: Uint8Array; contentType: string }>();
  return {
    async put(id, kind, bytes, contentType) {
      objects.set(`${id}:${kind}`, { bytes, contentType });
    },
    async get(id, kind) {
      return objects.get(`${id}:${kind}`) ?? null;
    },
  };
}

/**
 * Talks to inventory-sync, which already has the R2 bucket as a binding.
 *
 * The home server never holds R2 S3 keys. The Worker secret is only proof
 * that this process is the household box.
 */
export function createWorkerPhotoStore(env: {
  origin: string;
  secret: string;
  fetch?: typeof fetch;
}): PhotoStore {
  const origin = env.origin.replace(/\/+$/, '');
  const fetchImpl = env.fetch ?? fetch;

  function objectUrl(id: string, kind: PhotoKind): string {
    return `${origin}/v1/household/photos/${encodeURIComponent(id)}?kind=${kind}`;
  }

  return {
    async put(id, kind, bytes, contentType) {
      const response = await fetchImpl(objectUrl(id, kind), {
        method: 'PUT',
        headers: {
          authorization: `Bearer ${env.secret}`,
          'content-type': contentType,
        },
        body: Buffer.from(bytes),
      });
      if (!response.ok) {
        throw new Error(`Photo store put failed (${response.status})`);
      }
    },
    async get(id, kind) {
      const response = await fetchImpl(objectUrl(id, kind), {
        headers: { authorization: `Bearer ${env.secret}` },
      });
      if (response.status === 404) return null;
      if (!response.ok) throw new Error(`Photo store get failed (${response.status})`);
      const bytes = new Uint8Array(await response.arrayBuffer());
      const contentType = response.headers.get('content-type') ?? 'image/webp';
      return { bytes, contentType };
    },
  };
}

export function photoStoreFromEnv(env: NodeJS.ProcessEnv = process.env): PhotoStore | null {
  const secret = env.HOUSEHOLD_PHOTO_SECRET?.trim();
  if (!secret) return null;
  return createWorkerPhotoStore({
    origin: env.HOUSEHOLD_PHOTO_ORIGIN?.trim() || DEFAULT_PHOTO_WORKER_ORIGIN,
    secret,
  });
}
