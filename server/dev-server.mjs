/**
 * Local host for the recognition function.
 *
 * In production `api/recognize.ts` is a Vercel function invoked with a web
 * `Request`. This serves the identical handler over plain HTTP so the flow can
 * be exercised end to end from a device on the same machine — no deploy, and no
 * second copy of the logic that could drift from the real one.
 *
 *   node --import tsx server/dev-server.mjs
 *   adb reverse tcp:8787 tcp:8787
 *
 * Reads `server/.env.local`, which holds the provider key and is gitignored.
 * The key stays in this process; the app only ever sees this endpoint.
 */
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { Buffer } from 'node:buffer';

const PORT = Number(process.env.PORT ?? 8787);

try {
  const raw = readFileSync(new URL('./.env.local', import.meta.url), 'utf8');
  for (const line of raw.split('\n')) {
    const match = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$/);
    if (match && !line.trimStart().startsWith('#')) {
      process.env[match[1]] ??= match[2].trim();
    }
  }
} catch {
  console.warn('No server/.env.local found; the adapter will have no credentials.');
}

const { POST } = await import('./api/recognize.ts');

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  if (req.method !== 'POST' || !req.url?.startsWith('/api/recognize')) {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found. POST /api/recognize' }));
    return;
  }

  try {
    const body = await readBody(req);
    const request = new Request(`http://localhost:${PORT}${req.url}`, {
      method: 'POST',
      headers: req.headers,
      body,
    });

    const response = await POST(request);
    const text = await response.text();

    res.writeHead(response.status, {
      'content-type': response.headers.get('content-type') ?? 'application/json',
    });
    res.end(text);
  } catch (error) {
    console.error('recognition host error:', error);
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'Local recognition host failed.' }));
  }
});

server.listen(PORT, () => {
  console.log(`recognition host listening on http://localhost:${PORT}/api/recognize`);
});
