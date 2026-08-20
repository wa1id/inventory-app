import type { Hono, MiddlewareHandler } from 'hono';
import { streamSSE } from 'hono/streaming';

import { ConflictError } from '../../src/core/conflict.ts';
import type { Repositories } from '../../src/db/repositories.ts';
import { LATEST_SCHEMA_VERSION } from '../../src/db/migrations.ts';
import type { HouseholdDump } from '../../src/services/household/dump.ts';
import { CONTRACT_VERSION, HOUSEHOLD_NAME } from './contract.ts';
import type { ControlStore, Device } from './control.ts';
import type { RevisionHub } from './hub.ts';
import { applyHouseholdDump } from './importer.ts';
import {
  preparePhoto,
  preparePhotoWithId,
  r2ObjectKey,
  type PhotoStore,
  type PreparedPhoto,
} from './photos.ts';

type Variables = { device: Device };

interface InventoryDeps {
  repos: Repositories;
  control: ControlStore;
  hub: RevisionHub;
  photos: PhotoStore | null;
}

export function registerInventory(
  app: Hono<{ Variables: Variables }>,
  deps: InventoryDeps,
  requireDevice: MiddlewareHandler<{ Variables: Variables }>,
): void {
  const { repos, hub, photos } = deps;

  const write = async <T>(work: () => Promise<T>): Promise<T> => {
    const result = await work();
    hub.bump();
    return result;
  };

  app.get('/v1/status', requireDevice, async (c) => {
    const devices = await deps.control.listDevices();
    return c.json({
      householdName: HOUSEHOLD_NAME,
      contractVersion: CONTRACT_VERSION,
      schemaVersion: LATEST_SCHEMA_VERSION,
      revision: hub.revision,
      deviceCount: devices.length,
    });
  });

  app.get('/v1/events', requireDevice, (c) =>
    streamSSE(c, async (stream) => {
      await stream.writeSSE({
        event: 'change',
        data: JSON.stringify({ revision: hub.revision }),
      });
      const unsubscribe = hub.subscribe(async (revision) => {
        await stream.writeSSE({
          event: 'change',
          data: JSON.stringify({ revision }),
        });
      });
      try {
        while (true) {
          await stream.sleep(15_000);
          await stream.writeSSE({ event: 'ping', data: '' });
        }
      } finally {
        unsubscribe();
      }
    }),
  );

  app.get('/v1/spaces', requireDevice, async (c) => {
    return c.json({ spaces: await repos.spaces.listWithCounts() });
  });

  app.post('/v1/spaces', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    const name = asString(body.name);
    const icon = asString(body.icon);
    const color = asString(body.color);
    if (!name || !icon || !color) return c.json({ error: 'invalid_body' }, 400);
    try {
      const space = await write(() => repos.spaces.create({ name, icon, color }));
      return c.json(space, 201);
    } catch (error) {
      return c.json({ error: messageOf(error) }, 400);
    }
  });

  app.get('/v1/spaces/:id', requireDevice, async (c) => {
    const space = await repos.spaces.getById(c.req.param('id'));
    if (!space) return c.json({ error: 'not_found' }, 404);
    return c.json(space);
  });

  app.patch('/v1/spaces/:id', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    const patch: { name?: string; icon?: string; color?: string } = {};
    if ('name' in body) patch.name = asString(body.name) ?? undefined;
    if ('icon' in body) patch.icon = asString(body.icon) ?? undefined;
    if ('color' in body) patch.color = asString(body.color) ?? undefined;
    const updated = await write(() => repos.spaces.update(c.req.param('id'), patch));
    if (!updated) return c.json({ error: 'not_found' }, 404);
    return c.json(updated);
  });

  app.delete('/v1/spaces/:id', requireDevice, async (c) => {
    const result = await write(() => repos.spaces.delete(c.req.param('id')));
    if (!result.deleted) return c.json({ error: 'not_found' }, 404);
    return c.json(result);
  });

  app.get('/v1/containers', requireDevice, async (c) => {
    const spaceId = c.req.query('spaceId');
    if (spaceId) {
      return c.json({ containers: await repos.containers.listBySpace(spaceId) });
    }
    return c.json({ containers: await repos.containers.listAllWithSpace() });
  });

  app.post('/v1/containers', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    const spaceId = asString(body.spaceId);
    const visualType = asString(body.visualType);
    if (!spaceId || !visualType) return c.json({ error: 'invalid_body' }, 400);
    try {
      const container = await write(() =>
        repos.containers.create({
          spaceId,
          visualType: visualType as never,
          name: asString(body.name),
        }),
      );
      return c.json(container, 201);
    } catch (error) {
      return c.json({ error: messageOf(error) }, 400);
    }
  });

  app.get('/v1/containers/:id', requireDevice, async (c) => {
    const container = await repos.containers.getWithCounts(c.req.param('id'));
    if (!container) return c.json({ error: 'not_found' }, 404);
    return c.json(container);
  });

  app.patch('/v1/containers/:id', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    const updated = await write(() =>
      repos.containers.update(c.req.param('id'), {
        name: 'name' in body ? asString(body.name) : undefined,
        visualType: asString(body.visualType) as never,
        spaceId: asString(body.spaceId) ?? undefined,
      }),
    );
    if (!updated) return c.json({ error: 'not_found' }, 404);
    return c.json(updated);
  });

  app.delete('/v1/containers/:id', requireDevice, async (c) => {
    const result = await write(() => repos.containers.delete(c.req.param('id')));
    if (!result.deleted) return c.json({ error: 'not_found' }, 404);
    return c.json(result);
  });

  app.get('/v1/items', requireDevice, async (c) => {
    const containerId = c.req.query('containerId');
    if (containerId === 'drop-zone' || c.req.query('unsorted') === '1') {
      return c.json({ items: await repos.items.listUnsorted() });
    }
    if (!containerId) return c.json({ error: 'containerId_required' }, 400);
    return c.json({ items: await repos.items.listByContainer(containerId) });
  });

  app.post('/v1/items', requireDevice, async (c) => {
    const contentType = c.req.header('content-type') ?? '';
    let body: Record<string, unknown>;
    let photoBytes: Uint8Array | null = null;

    if (contentType.includes('multipart/form-data')) {
      const parsed = await c.req.parseBody();
      body = Object.fromEntries(
        Object.entries(parsed).filter(([, value]) => typeof value === 'string'),
      );
      const file = parsed.photo;
      if (file instanceof File) {
        photoBytes = new Uint8Array(await file.arrayBuffer());
      }
    } else {
      const json = await readJson(c);
      if (!json) return c.json({ error: 'invalid_json' }, 400);
      body = json;
    }

    const containerId = asString(body.containerId);
    if (!containerId) return c.json({ error: 'invalid_body' }, 400);

    const photoRef = 'photo' in body && body.photo != null ? asPhotoRef(body.photo) : null;
    if ('photo' in body && body.photo != null && !photoRef) {
      return c.json({ error: 'invalid_photo' }, 400);
    }

    if ((photoBytes || photoRef) && !photos) {
      return c.json({ error: 'photos_not_configured' }, 503);
    }

    try {
      let prepared: PreparedPhoto | null =
        photoBytes && photos ? await preparePhoto(photoBytes, photos) : null;
      if (!prepared && photoRef && photos) {
        prepared = await resolveUploadedPhoto(photoRef, photos);
        if (!prepared) return c.json({ error: 'photo_missing' }, 400);
      }
      const item = await write(() =>
        repos.items.create({
          containerId,
          name: asString(body.name) ?? undefined,
          category: asString(body.category),
          quantity: asNumber(body.quantity) ?? undefined,
          notes: asString(body.notes),
          tags: Array.isArray(body.tags)
            ? body.tags.filter((tag): tag is string => typeof tag === 'string')
            : typeof body.tags === 'string'
              ? body.tags
                  .split(',')
                  .map((tag) => tag.trim())
                  .filter(Boolean)
              : undefined,
          photo: prepared
            ? {
                id: prepared.id,
                uri: prepared.uri,
                thumbUri: prepared.thumbUri,
                width: prepared.width,
                height: prepared.height,
                byteSize: prepared.byteSize,
              }
            : undefined,
        }),
      );
      const full = await repos.items.getById(item.id);
      return c.json(full ?? item, 201);
    } catch (error) {
      return c.json({ error: messageOf(error) }, 400);
    }
  });

  app.get('/v1/photos/:id', requireDevice, async (c) => {
    if (!photos) return c.json({ error: 'photos_not_configured' }, 503);
    const kind = c.req.query('thumb') === '1' ? 'thumb' : 'full';
    const object = await photos.get(c.req.param('id'), kind);
    if (!object) return c.json({ error: 'not_found' }, 404);
    return c.body(Buffer.from(object.bytes), 200, { 'content-type': object.contentType });
  });

  app.get('/v1/items/:id', requireDevice, async (c) => {
    const item = await repos.items.getById(c.req.param('id'));
    if (!item) return c.json({ error: 'not_found' }, 404);
    return c.json(item);
  });

  app.patch('/v1/items/:id', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    try {
      const updated = await write(() =>
        repos.items.update(c.req.param('id'), {
          containerId: asString(body.containerId) ?? undefined,
          name: 'name' in body ? (asString(body.name) ?? undefined) : undefined,
          category: 'category' in body ? asString(body.category) : undefined,
          quantity: asNumber(body.quantity) ?? undefined,
          notes: 'notes' in body ? asString(body.notes) : undefined,
          tags: Array.isArray(body.tags)
            ? body.tags.filter((tag): tag is string => typeof tag === 'string')
            : undefined,
          expectedUpdatedAt: asNumber(body.updatedAt) ?? undefined,
        }),
      );
      if (!updated) return c.json({ error: 'not_found' }, 404);
      return c.json(updated);
    } catch (error) {
      if (error instanceof ConflictError) {
        return c.json({ error: 'conflict', updatedAt: error.updatedAt }, 409);
      }
      return c.json({ error: messageOf(error) }, 400);
    }
  });

  app.delete('/v1/items/:id', requireDevice, async (c) => {
    const result = await write(() => repos.items.delete(c.req.param('id')));
    if (!result.deleted) return c.json({ error: 'not_found' }, 404);
    return c.json(result);
  });

  app.get('/v1/search', requireDevice, async (c) => {
    const q = c.req.query('q') ?? '';
    return c.json(await repos.search.search(q));
  });

  app.post('/v1/containers/:id/qr', requireDevice, async (c) => {
    try {
      const binding = await write(() => repos.qr.createAndBind(c.req.param('id')));
      return c.json(binding, 201);
    } catch (error) {
      return c.json({ error: messageOf(error) }, 400);
    }
  });

  app.post('/v1/qr/bind', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    const token = asString(body.token);
    const containerId = asString(body.containerId);
    if (!token || !containerId) return c.json({ error: 'invalid_body' }, 400);
    try {
      const binding = await write(() => repos.qr.bind(token, containerId));
      return c.json(binding);
    } catch (error) {
      return c.json({ error: messageOf(error) }, 400);
    }
  });

  app.post('/v1/qr/scan', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    const raw = asString(body.raw) ?? asString(body.token);
    if (!raw) return c.json({ error: 'invalid_body' }, 400);
    return c.json(await repos.qr.resolveScan(raw));
  });

  app.delete('/v1/containers/:id/qr', requireDevice, async (c) => {
    const unbound = await write(() => repos.qr.unbind(c.req.param('id')));
    if (!unbound) return c.json({ error: 'not_found' }, 404);
    return c.body(null, 204);
  });

  app.post('/v1/import', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    try {
      const dump = asDump(body);
      await write(() => applyHouseholdDump(repos.db, dump));
      return c.json({
        ok: true,
        spaces: dump.spaces.length,
        containers: dump.containers.length,
        items: dump.items.length,
        photos: dump.photos.length,
      });
    } catch (error) {
      return c.json({ error: messageOf(error) }, 400);
    }
  });

  app.put('/v1/photos/:id', requireDevice, async (c) => {
    if (!photos) return c.json({ error: 'photos_not_configured' }, 503);
    const id = c.req.param('id');
    if (!isPhotoId(id)) {
      return c.json({ error: 'invalid_id' }, 400);
    }
    const bytes = new Uint8Array(await c.req.arrayBuffer());
    if (bytes.byteLength === 0) return c.json({ error: 'empty_upload' }, 400);
    try {
      const prepared = await preparePhotoWithId(id, bytes, photos);
      return c.json(prepared, 201);
    } catch (error) {
      return c.json({ error: messageOf(error) }, 400);
    }
  });
}

async function readJson(c: {
  req: { json: () => Promise<unknown> };
}): Promise<Record<string, unknown> | null> {
  try {
    const body = await c.req.json();
    if (typeof body !== 'object' || body === null) return null;
    return body as Record<string, unknown>;
  } catch {
    return null;
  }
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

const PHOTO_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isPhotoId(value: string): boolean {
  return PHOTO_ID_RE.test(value);
}

interface PhotoRef {
  id: string;
  uri: string | null;
  thumbUri: string | null;
  width: number | null;
  height: number | null;
  byteSize: number | null;
}

function asPhotoRef(value: unknown): PhotoRef | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const photo = value as Record<string, unknown>;
  const id = asString(photo.id);
  if (!id || !isPhotoId(id)) return null;
  return {
    id,
    uri: asString(photo.uri),
    thumbUri: asString(photo.thumbUri),
    width: asNumber(photo.width),
    height: asNumber(photo.height),
    byteSize: asNumber(photo.byteSize),
  };
}

async function resolveUploadedPhoto(
  ref: PhotoRef,
  photos: PhotoStore,
): Promise<PreparedPhoto | null> {
  const stored = await photos.get(ref.id, 'full');
  if (!stored) return null;
  return {
    id: ref.id,
    uri: ref.uri ?? `r2:${r2ObjectKey(ref.id, 'full')}`,
    thumbUri: ref.thumbUri ?? `r2:${r2ObjectKey(ref.id, 'thumb')}`,
    width: ref.width ?? 0,
    height: ref.height ?? 0,
    byteSize: ref.byteSize ?? stored.bytes.byteLength,
  };
}

function asNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : 'invalid_body';
}

function asDump(body: Record<string, unknown>): HouseholdDump {
  return {
    spaces: asArray(body.spaces),
    containers: asArray(body.containers),
    items: asArray(body.items),
    tags: asArray(body.tags),
    itemTags: asArray(body.itemTags),
    qrBindings: asArray(body.qrBindings),
    photos: asArray(body.photos),
  };
}

function asArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : [];
}
