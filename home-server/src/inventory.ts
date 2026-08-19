import type { Hono, MiddlewareHandler } from 'hono';
import { streamSSE } from 'hono/streaming';

import type { Repositories } from '../../src/db/repositories.ts';
import { LATEST_SCHEMA_VERSION } from '../../src/db/migrations.ts';
import { CONTRACT_VERSION, HOUSEHOLD_NAME } from './contract.ts';
import type { ControlStore, Device } from './control.ts';
import type { RevisionHub } from './hub.ts';

type Variables = { device: Device };

interface InventoryDeps {
  repos: Repositories;
  control: ControlStore;
  hub: RevisionHub;
}

export function registerInventory(
  app: Hono<{ Variables: Variables }>,
  deps: InventoryDeps,
  requireDevice: MiddlewareHandler<{ Variables: Variables }>,
): void {
  const { repos, hub } = deps;

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
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
    const containerId = asString(body.containerId);
    if (!containerId) return c.json({ error: 'invalid_body' }, 400);
    try {
      const item = await write(() =>
        repos.items.create({
          containerId,
          name: asString(body.name) ?? undefined,
          category: asString(body.category),
          quantity: asNumber(body.quantity) ?? undefined,
          notes: asString(body.notes),
          tags: Array.isArray(body.tags)
            ? body.tags.filter((tag): tag is string => typeof tag === 'string')
            : undefined,
        }),
      );
      return c.json(item, 201);
    } catch (error) {
      return c.json({ error: messageOf(error) }, 400);
    }
  });

  app.get('/v1/items/:id', requireDevice, async (c) => {
    const item = await repos.items.getById(c.req.param('id'));
    if (!item) return c.json({ error: 'not_found' }, 404);
    return c.json(item);
  });

  app.patch('/v1/items/:id', requireDevice, async (c) => {
    const body = await readJson(c);
    if (!body) return c.json({ error: 'invalid_json' }, 400);
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
      }),
    );
    if (!updated) return c.json({ error: 'not_found' }, 404);
    return c.json(updated);
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

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : 'invalid_body';
}
