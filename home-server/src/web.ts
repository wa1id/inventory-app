import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import type { Hono } from 'hono';
import { deleteCookie, getCookie, setCookie } from 'hono/cookie';

import type { Device } from './control.ts';

export const WEB_COOKIE = 'household_web';
const WEB_TOKEN_BYTES = 32;
const SESSION_MS = 30 * 24 * 60 * 60 * 1000;

function sha256Hex(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function hashesEqual(leftHex: string, rightHex: string): boolean {
  const left = Buffer.from(leftHex, 'hex');
  const right = Buffer.from(rightHex, 'hex');
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

export function passwordMatches(provided: string, expected: string): boolean {
  return hashesEqual(sha256Hex(provided), sha256Hex(expected));
}

export interface WebSessions {
  issue(): string;
  has(token: string): boolean;
  revoke(token: string): void;
}

export function createWebSessions(): WebSessions {
  const sessions = new Map<string, number>();

  return {
    issue() {
      const token = randomBytes(WEB_TOKEN_BYTES).toString('hex');
      sessions.set(sha256Hex(token), Date.now() + SESSION_MS);
      return token;
    },
    has(token) {
      const expires = sessions.get(sha256Hex(token));
      if (expires === undefined) return false;
      if (expires < Date.now()) {
        sessions.delete(sha256Hex(token));
        return false;
      }
      return true;
    },
    revoke(token) {
      sessions.delete(sha256Hex(token));
    },
  };
}

function pageHtml(): string {
  const path = join(dirname(fileURLToPath(import.meta.url)), '../web/index.html');
  return readFileSync(path, 'utf8');
}

export function registerWebLookup(
  app: Hono<{ Variables: { device?: Device } }>,
  options: {
    password: string;
    publicOrigin: string;
    sessions?: WebSessions;
  },
): WebSessions {
  const sessions = options.sessions ?? createWebSessions();
  const html = pageHtml();
  const secure = options.publicOrigin.startsWith('https:');

  app.get('/', (c) => {
    c.header('cache-control', 'no-store');
    return c.html(html);
  });

  app.get('/v1/web/me', (c) => {
    const token = getCookie(c, WEB_COOKIE);
    if (!token || !sessions.has(token)) return c.json({ error: 'unauthorized' }, 401);
    return c.json({ ok: true, householdName: 'Home' });
  });

  app.post('/v1/web/login', async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_json' }, 400);
    }
    if (typeof body !== 'object' || body === null) {
      return c.json({ error: 'invalid_json' }, 400);
    }
    const password = (body as { password?: unknown }).password;
    if (typeof password !== 'string' || !passwordMatches(password, options.password)) {
      return c.json({ error: 'unauthorized' }, 401);
    }
    const token = sessions.issue();
    setCookie(c, WEB_COOKIE, token, {
      httpOnly: true,
      sameSite: 'Lax',
      secure,
      path: '/',
      maxAge: SESSION_MS / 1000,
    });
    return c.json({ ok: true });
  });

  app.post('/v1/web/logout', (c) => {
    const token = getCookie(c, WEB_COOKIE);
    if (token) sessions.revoke(token);
    deleteCookie(c, WEB_COOKIE, { path: '/' });
    return c.json({ ok: true });
  });

  return sessions;
}
