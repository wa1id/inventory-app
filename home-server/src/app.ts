import { Hono } from 'hono';
import { createMiddleware } from 'hono/factory';

import { CONTRACT_VERSION, HOUSEHOLD_NAME } from './contract.ts';
import type { ControlStore, Device } from './control.ts';

export interface AppDeps {
  control: ControlStore;
  publicOrigin: string;
}

type Variables = { device: Device };

/**
 * HTTP surface for the household API.
 *
 * Health is unauthenticated and must stay `{ ok, contractVersion }` — no
 * household name, no schema revision, nothing that would help a scanner.
 * Pairing is the other unauthenticated route; everything else needs a device
 * bearer token.
 */
export function createApp(deps: AppDeps): Hono<{ Variables: Variables }> {
  const app = new Hono<{ Variables: Variables }>();

  app.get('/v1/health', (c) =>
    c.json({
      ok: true,
      contractVersion: CONTRACT_VERSION,
    }),
  );

  app.post('/v1/pair', async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_json' }, 400);
    }
    if (typeof body !== 'object' || body === null) {
      return c.json({ error: 'invalid_json' }, 400);
    }
    const record = body as Record<string, unknown>;
    const bootstrapSecret = record.bootstrapSecret;
    const deviceName = record.deviceName;
    if (typeof bootstrapSecret !== 'string' || typeof deviceName !== 'string') {
      return c.json({ error: 'invalid_body' }, 400);
    }

    const paired = await deps.control.pair(bootstrapSecret, deviceName);
    if (!paired) return c.json({ error: 'unauthorized' }, 401);

    return c.json({
      deviceId: paired.deviceId,
      token: paired.token,
      origin: deps.publicOrigin,
      householdName: paired.householdName,
      contractVersion: CONTRACT_VERSION,
    });
  });

  const requireDevice = createMiddleware<{ Variables: Variables }>(async (c, next) => {
    const header = c.req.header('Authorization') ?? '';
    const match = /^Bearer\s+(\S+)$/i.exec(header);
    if (!match?.[1]) return c.json({ error: 'unauthorized' }, 401);

    const device = await deps.control.findDeviceByToken(match[1]);
    if (!device) return c.json({ error: 'unauthorized' }, 401);

    await deps.control.touch(device.id);
    c.set('device', device);
    await next();
  });

  app.get('/v1/session', requireDevice, (c) => {
    const device = c.get('device');
    return c.json({
      deviceId: device.id,
      deviceName: device.name,
      householdName: HOUSEHOLD_NAME,
      origin: deps.publicOrigin,
      contractVersion: CONTRACT_VERSION,
    });
  });

  app.get('/v1/devices', requireDevice, async (c) => {
    const devices = await deps.control.listDevices();
    return c.json({ devices });
  });

  app.delete('/v1/devices/:id', requireDevice, async (c) => {
    const id = c.req.param('id');
    const deleted = await deps.control.revoke(id);
    if (!deleted) return c.json({ error: 'not_found' }, 404);
    return c.body(null, 204);
  });

  return app;
}
