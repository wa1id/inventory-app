import { Hono } from 'hono';

import { CONTRACT_VERSION } from './contract.ts';

/**
 * HTTP surface for the household API.
 *
 * Health is unauthenticated and must stay `{ ok, contractVersion }` — no
 * household name, no schema revision, nothing that would help a scanner.
 */
export function createApp(): Hono {
  const app = new Hono();

  app.get('/v1/health', (c) =>
    c.json({
      ok: true,
      contractVersion: CONTRACT_VERSION,
    }),
  );

  return app;
}
