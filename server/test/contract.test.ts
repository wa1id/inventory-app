import assert from 'node:assert/strict';
import { test } from 'node:test';

import { toExtraction } from '../src/adapters/mimoVision.js';
import { AUTH_HEADER, checkAuth } from '../src/auth.js';
import { CONTRACT_VERSION, parseRequest, statusForAdapterError } from '../src/contract.js';
import { toRawSuggestion } from '../src/prompt.js';
import {
  UnknownAdapterError,
  getAdapter,
  hasAdapter,
  listAdapterIds,
  registerAdapter,
  resetRegistry,
} from '../src/registry.js';

const validImage = Buffer.from('fake-jpeg-bytes').toString('base64');

function body(overrides: Record<string, unknown> = {}) {
  return {
    contractVersion: CONTRACT_VERSION,
    image: { data: validImage, encoding: 'base64' },
    ...overrides,
  };
}

test('accepts a well-formed request', () => {
  const parsed = parseRequest(body());
  assert.equal(parsed.ok, true);
  if (!parsed.ok) return;
  assert.equal(parsed.mediaType, 'image/jpeg');
  assert.ok(parsed.bytes.byteLength > 0);
});

test('rejects a mismatched contract version', () => {
  const parsed = parseRequest(body({ contractVersion: 99 }));
  assert.equal(parsed.ok, false);
  if (parsed.ok) return;
  assert.equal(parsed.status, 400);
});

test('rejects non-object bodies', () => {
  for (const value of [null, 'nope', 42, undefined]) {
    assert.equal(parseRequest(value).ok, false);
  }
});

test('rejects a missing or non-base64 encoding', () => {
  assert.equal(parseRequest(body({ image: { data: validImage } })).ok, false);
  assert.equal(
    parseRequest(body({ image: { data: validImage, encoding: 'hex' } })).ok,
    false,
  );
});

test('rejects an empty image', () => {
  const parsed = parseRequest(body({ image: { data: '', encoding: 'base64' } }));
  assert.equal(parsed.ok, false);
});

test('rejects an oversized image before decoding it', () => {
  const huge = 'A'.repeat(20 * 1024 * 1024);
  const parsed = parseRequest(body({ image: { data: huge, encoding: 'base64' } }));
  assert.equal(parsed.ok, false);
  if (parsed.ok) return;
  assert.equal(parsed.status, 413);
});

test('honours a valid mediaType and ignores a bogus one', () => {
  const png = parseRequest(
    body({ image: { data: validImage, encoding: 'base64', mediaType: 'image/PNG' } }),
  );
  assert.equal(png.ok && png.mediaType, 'image/png');

  const bogus = parseRequest(
    body({ image: { data: validImage, encoding: 'base64', mediaType: 'application/pdf' } }),
  );
  assert.equal(bogus.ok && bogus.mediaType, 'image/jpeg');
});

test('maps adapter errors to the statuses the client expects', () => {
  assert.equal(statusForAdapterError({ status: 'error', kind: 'rate_limited', message: '' }), 429);
  assert.equal(statusForAdapterError({ status: 'error', kind: 'timeout', message: '' }), 504);
  assert.equal(statusForAdapterError({ status: 'error', kind: 'upstream', message: '' }), 502);
});

test('normalization clamps confidence and cleans fields', () => {
  const raw = toRawSuggestion({
    identified: true,
    name: '  Cordless Drill  ',
    category: '   ',
    tags: ['  DeWalt ', 'dewalt', '', 'x'.repeat(80), 'drill'],
    estimatedValue: -5,
    currency: 'eur',
    confidence: 4.2,
  });

  assert.equal(raw.name, 'Cordless Drill');
  assert.equal(raw.category, null, 'whitespace-only category becomes null');
  assert.deepEqual(raw.tags, ['dewalt', 'drill'], 'lowercased, deduped, over-long dropped');
  assert.equal(raw.estimatedValue, 0, 'negative value floored at zero');
  assert.equal(raw.currency, 'EUR');
  assert.equal(raw.confidence, 1, 'confidence clamped into 0..1');
});

test('normalization drops a non-ISO currency', () => {
  const raw = toRawSuggestion({
    identified: true,
    name: 'Drill',
    category: null,
    tags: [],
    estimatedValue: 10,
    currency: 'euros',
    confidence: 0.5,
  });
  assert.equal(raw.currency, null);
});

// MiMo answers HTTP 200 with a partial object rather than the schema it was
// given. These are the two shapes observed against the live API; both must
// survive, because the strict schema throws on either.
test('MiMo: a bare identified=false stays an honest "could not tell"', () => {
  const extraction = toExtraction({ identified: false });

  assert.equal(extraction.identified, false);
  assert.equal(extraction.name, null);
  assert.deepEqual(extraction.tags, []);
  assert.equal(extraction.confidence, 0);
});

test('MiMo: an omitted identified is inferred from the name', () => {
  const extraction = toExtraction({
    name: 'Cordless drill',
    category: 'Power Tools',
    tags: ['drill'],
    estimatedValue: 35,
    currency: 'USD',
    confidence: 0.95,
  });

  assert.equal(extraction.identified, true, 'a usable name is an identification');
  assert.equal(extraction.name, 'Cordless drill');
  assert.equal(extraction.confidence, 0.95);
});

test('MiMo: a blank name is not an identification', () => {
  assert.equal(toExtraction({ name: '   ' }).identified, false);
  assert.equal(toExtraction({}).identified, false);
});

test('MiMo: an omitted confidence is never invented', () => {
  const extraction = toExtraction({ name: 'Drill' });
  assert.equal(extraction.confidence, 0, 'scores zero so the contract filters it out');
});

test('MiMo: nulls survive the trip to normalization', () => {
  const raw = toRawSuggestion(
    toExtraction({ identified: true, name: 'Drill', estimatedValue: null, currency: null }),
  );

  assert.equal(raw.name, 'Drill');
  assert.equal(raw.category, null);
  assert.deepEqual(raw.tags, []);
  assert.equal(raw.estimatedValue, null);
  assert.equal(raw.currency, null);
});

test('registry resolves, caches, and rejects unknown ids', () => {
  resetRegistry();
  let built = 0;
  registerAdapter('stub', () => {
    built += 1;
    return { id: 'stub', label: 'Stub', recognize: async () => ({ status: 'unrecognized' }) };
  });

  assert.deepEqual(listAdapterIds(), ['stub']);
  assert.equal(hasAdapter('stub'), true);
  assert.equal(hasAdapter('nope'), false);

  const first = getAdapter('stub');
  const second = getAdapter('stub');
  assert.equal(first, second, 'adapter instance is cached');
  assert.equal(built, 1, 'factory runs once');

  assert.throws(() => getAdapter('nope'), UnknownAdapterError);
});

test('registry refuses duplicate registration', () => {
  resetRegistry();
  registerAdapter('dup', () => ({
    id: 'dup',
    label: 'Dup',
    recognize: async () => ({ status: 'unrecognized' }),
  }));
  assert.throws(
    () =>
      registerAdapter('dup', () => ({
        id: 'dup',
        label: 'Dup',
        recognize: async () => ({ status: 'unrecognized' }),
      })),
    /already registered/,
  );
});

test('auth is open when no secret is configured', () => {
  delete process.env.RECOGNITION_SHARED_SECRET;
  assert.equal(checkAuth(new Request('https://x/api/recognize')).ok, true);
});

test('auth rejects a missing or wrong key when a secret is set', () => {
  process.env.RECOGNITION_SHARED_SECRET = 'correct-horse';

  const missing = checkAuth(new Request('https://x/api/recognize'));
  assert.equal(missing.ok, false);
  if (!missing.ok) assert.equal(missing.status, 401);

  const wrong = checkAuth(
    new Request('https://x/api/recognize', { headers: { [AUTH_HEADER]: 'battery-staple' } }),
  );
  assert.equal(wrong.ok, false);

  // A wrong key of a different length must also fail, not throw.
  const shortKey = checkAuth(
    new Request('https://x/api/recognize', { headers: { [AUTH_HEADER]: 'x' } }),
  );
  assert.equal(shortKey.ok, false);

  const right = checkAuth(
    new Request('https://x/api/recognize', { headers: { [AUTH_HEADER]: 'correct-horse' } }),
  );
  assert.equal(right.ok, true);

  delete process.env.RECOGNITION_SHARED_SECRET;
});
