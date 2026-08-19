import { AwsClient } from 'aws4fetch';
import sharp from 'sharp';

import { newId } from '../../src/core/id.ts';

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
  const id = newId();
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

export function createR2PhotoStore(env: {
  accountId: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket?: string;
}): PhotoStore {
  const bucket = env.bucket ?? 'inventory-app';
  const endpoint = `https://${env.accountId}.r2.cloudflarestorage.com`;
  const client = new AwsClient({
    accessKeyId: env.accessKeyId,
    secretAccessKey: env.secretAccessKey,
    service: 's3',
    region: 'auto',
  });

  return {
    async put(id, kind, bytes, contentType) {
      const key = r2ObjectKey(id, kind);
      const response = await client.fetch(`${endpoint}/${bucket}/${key}`, {
        method: 'PUT',
        headers: { 'content-type': contentType },
        body: Buffer.from(bytes),
      });
      if (!response.ok) {
        throw new Error(`R2 put failed (${response.status})`);
      }
    },
    async get(id, kind) {
      const key = r2ObjectKey(id, kind);
      const response = await client.fetch(`${endpoint}/${bucket}/${key}`);
      if (response.status === 404) return null;
      if (!response.ok) throw new Error(`R2 get failed (${response.status})`);
      const bytes = new Uint8Array(await response.arrayBuffer());
      const contentType = response.headers.get('content-type') ?? 'image/webp';
      return { bytes, contentType };
    },
  };
}

export function photoStoreFromEnv(env: NodeJS.ProcessEnv = process.env): PhotoStore | null {
  const accountId = env.R2_ACCOUNT_ID;
  const accessKeyId = env.R2_ACCESS_KEY_ID;
  const secretAccessKey = env.R2_SECRET_ACCESS_KEY;
  if (!accountId || !accessKeyId || !secretAccessKey) return null;
  return createR2PhotoStore({
    accountId,
    accessKeyId,
    secretAccessKey,
    bucket: env.R2_BUCKET,
  });
}
