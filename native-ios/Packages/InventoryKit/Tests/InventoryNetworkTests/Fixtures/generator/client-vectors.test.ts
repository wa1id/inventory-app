/**
 * Generates the InventoryNetwork client parity vectors by running the real RN
 * clients (src/services/household/client.ts, devices.ts, src/services/ai/contract.ts,
 * src/services/sync/contract.ts) against canned responses.
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryNetworkTests/Fixtures/generator/client-vectors.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * Output: Tests/InventoryNetworkTests/Fixtures/client-vectors.json.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { parseRecognitionResponse } from '@/services/ai/contract';
import { ConflictError, HouseholdHttpError, householdRequest } from '@/services/household/client';
import { listDevices } from '@/services/household/devices';
import { parseBackupList } from '@/services/sync/contract';

const OUT = join(__dirname, '../../../native-ios/Packages/InventoryKit/Tests/InventoryNetworkTests/Fixtures');

const session = {
  origin: 'https://inventory.example',
  token: 't',
  deviceId: 'd',
  deviceName: 'Phone',
  householdName: 'Home',
};

function respond(status: number, text: string | null): typeof fetch {
  return (async () =>
    new Response(status === 204 ? null : text, { status })) as unknown as typeof fetch;
}

type Outcome =
  | { kind: 'ok'; body: unknown }
  | { kind: 'http'; status: number; code: string }
  | { kind: 'conflict'; updatedAt: number | null };

/**
 * A Swift String cannot hold a lone surrogate; the Swift clients read one as U+FFFD
 * (what `toWellFormed` gives), so expected values are written that way.
 */
function wellFormed<T>(value: T): T {
  if (typeof value === 'string') return value.toWellFormed() as T;
  if (Array.isArray(value)) return value.map(wellFormed) as T;
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, inner]) => [key, wellFormed(inner)])) as T;
  }
  return value;
}

async function outcomeOf(work: () => Promise<unknown>): Promise<Outcome> {
  try {
    return { kind: 'ok', body: await work() };
  } catch (error) {
    if (error instanceof ConflictError) return { kind: 'conflict', updatedAt: error.updatedAt };
    if (error instanceof HouseholdHttpError) {
      return { kind: 'http', status: error.status, code: error.code };
    }
    throw error;
  }
}

/** (status, body text) pairs for householdRequest's parsing rules (04 §3.2). */
const HOUSEHOLD_RESPONSES: [number, string | null][] = [
  [200, '{"a":1,"b":[true,null]}'],
  [200, ''],
  [200, '[]'],
  [200, '[1,2]'],
  [200, '42'],
  [200, 'null'],
  [200, '"str"'],
  [200, 'true'],
  [200, '<html>oops</html>'],
  [200, '   '],
  [201, '{"id":"x"}'],
  [204, null],
  [404, '{"error":"not_found"}'],
  [404, '404 Not Found'],
  [500, 'Internal Server Error'],
  [530, '<!DOCTYPE html><title>Origin is unreachable</title>'],
  [502, '{"error":"upstream"}'],
  [418, '{}'],
  [418, ''],
  [401, '{"error":"unauthorized"}'],
  [400, '{"error":"Item name is required."}'],
  [400, '{"error":42}'],
  [400, '{"error":null}'],
  [400, '{"error":true}'],
  [400, '{"error":["a",null,1,[2,[3]]]}'],
  [400, '{"error":{"x":1}}'],
  [400, '{"error":1.5}'],
  [400, '{"error":-0}'],
  [400, '{"error":1e21}'],
  [400, '{"error":123456789012345680000}'],
  [400, '{"error":0.000001}'],
  [400, '{"error":1e-7}'],
  [400, '{"error":-2.5e-9}'],
  [400, '{"error":""}'],
  [400, '[]'],
  [400, '["error"]'],
  [400, '"error"'],
  [409, '{"error":"conflict","updatedAt":11}'],
  [409, '{"updatedAt":null}'],
  [409, '{"updatedAt":"11"}'],
  [409, '{"updatedAt":" 0x1F "}'],
  [409, '{"updatedAt":"1e3"}'],
  [409, '{"updatedAt":""}'],
  [409, '{"updatedAt":"junk"}'],
  [409, '{"updatedAt":true}'],
  [409, '{"updatedAt":false}'],
  [409, '{"updatedAt":[]}'],
  [409, '{"updatedAt":[7]}'],
  [409, '{"updatedAt":["8"]}'],
  [409, '{"updatedAt":[1,2]}'],
  [409, '{"updatedAt":{}}'],
  [409, '{}'],
  [409, ''],
  [409, '[1]'],
  [409, '12'],
  [409, 'oops'],
  // JSON.stringify writes a lone surrogate as an escape; JSON.parse takes it.
  [400, '{"error":"\\ud83d"}'],
  [200, '{"high":"x\\ud83d","low":"\\udc00y","pair":"\\ud83d\\udd27","escaped":"\\\\ud83d"}'],
];

/** `devices` arrays for listDevices' lenient entry reading (devices.ts:18-30). */
const DEVICE_BODIES: string[] = [
  '{"devices":[{"id":"a","name":"Kitchen iPhone","createdAt":1,"lastSeenAt":5},{"id":"b","name":"Anna’s iPhone","createdAt":2,"lastSeenAt":null}]}',
  '{"devices":[{"id":"a","name":"Kitchen iPhone","createdAt":1,"lastSeenAt":5},{"id":7},null]}',
  '{"devices":[{"id":"c","name":"C"}]}',
  '{"devices":[{"id":"d","name":"D","createdAt":"5","lastSeenAt":" 6 "}]}',
  '{"devices":[{"id":"e","name":"E","createdAt":true,"lastSeenAt":false}]}',
  '{"devices":[{"id":"f","name":"F","createdAt":"x","lastSeenAt":{}}]}',
  '{"devices":[{"id":"g","name":"G","createdAt":null,"lastSeenAt":[]}]}',
  '{"devices":[["a"],"str",3,{"id":"h","name":7},{"id":"i","name":"I","createdAt":[4],"lastSeenAt":"0x10"}]}',
  '{"devices":[]}',
  '{"nope":true}',
  '{"devices":{}}',
  '{"devices":null}',
  '{"devices":"a"}',
  '[]',
  '',
];

/** Recognition bodies for parseRecognitionResponse (05 §10.4). */
const RECOGNITION_BODIES: string[] = [
  '{"contractVersion":1,"suggestion":{"name":"Cordless Drill","category":"Power Tools","tags":["dewalt","18v"],"confidence":0.92}}',
  'null',
  '"nope"',
  '42',
  '[]',
  '{}',
  '{"contractVersion":"1","suggestion":{"name":"A","tags":[],"confidence":0.9}}',
  '{"contractVersion":true,"suggestion":{"name":"A","tags":[],"confidence":0.9}}',
  '{"contractVersion":1.0,"suggestion":{"name":"A","tags":[],"confidence":0.9}}',
  '{"contractVersion":2,"status":"unrecognized"}',
  '{"contractVersion":0,"suggestion":{"name":"A","tags":[],"confidence":0.9}}',
  '{"contractVersion":1,"status":"unrecognized","suggestion":{"name":"A","tags":[],"confidence":0.9}}',
  '{"contractVersion":1,"status":"UNRECOGNIZED"}',
  '{"contractVersion":1}',
  '{"contractVersion":1,"suggestion":null}',
  '{"contractVersion":1,"suggestion":[]}',
  '{"contractVersion":1,"suggestion":"A"}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[]}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":null}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":"0.9"}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":true}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":-0.1}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":-0}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":0}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":1}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":1.0000001}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":0.35}}',
  '{"contractVersion":1,"suggestion":{"name":"A","tags":[],"confidence":0.3499999}}',
  '{"contractVersion":1,"suggestion":{"name":"   ","tags":[],"confidence":0.9}}',
  '{"contractVersion":1,"suggestion":{"name":"   ","tags":[],"confidence":4}}',
  '{"contractVersion":1,"suggestion":{"tags":[],"confidence":0.1}}',
  '{"contractVersion":1,"suggestion":{"name":42,"tags":[],"confidence":0.9}}',
  '{"contractVersion":1,"suggestion":{"name":"\\ufeff\\u00a0 Angle  grinder \\u0085","category":" \\u2003Tools\\u3000","tags":["  a  "],"confidence":0.9}}',
  '{"contractVersion":1,"suggestion":{"name":"Drill","category":42,"tags":["ok",17,null,"  ","fine"],"confidence":0.8}}',
  '{"contractVersion":1,"suggestion":{"name":"Drill","category":"","tags":"a,b","confidence":0.8}}',
  '{"contractVersion":1,"suggestion":{"name":"Drill","category":null,"tags":{"0":"a"},"confidence":0.8}}',
  '{"contractVersion":1,"suggestion":{"name":"Drill","tags":["1","2","3","4","5","6","7","8","9","10"],"confidence":0.8}}',
  '{"contractVersion":1,"suggestion":{"name":"Drill","tags":[" ","1","","2",null,"3","4","5","6","7","8","9"],"confidence":0.8}}',
  `{"contractVersion":1,"suggestion":{"name":"${'x'.repeat(79)} b","tags":["${'y'.repeat(100)}"],"confidence":0.8}}`,
  `{"contractVersion":1,"suggestion":{"name":"${'x'.repeat(78)}🔧tail","tags":[],"confidence":0.8}}`,
  `{"contractVersion":1,"suggestion":{"name":"   ${'é'.repeat(90)}","tags":[],"confidence":0.8}}`,
  '{"contractVersion":1,"suggestion":{"name":"Drill","tags":[],"confidence":0.8},"extra":{"nested":[1]}}',
  // The recognition server cuts names with slice(0, 80), which can split a pair (server/src/prompt.ts:83-85).
  `{"contractVersion":1,"suggestion":{"name":"${'x'.repeat(79)}\\ud83d","category":"\\udc00Tools","tags":["a\\ud83d","\\\\ud83d"],"confidence":0.9}}`,
];

/** List bodies for parseBackupList (sync/contract.ts:67-76). */
const BACKUP_LISTS: string[] = [
  '{"contractVersion":1,"backups":[]}',
  '{"contractVersion":1,"backups":[{"id":"2","size":2,"capturedAt":2,"schemaVersion":7},{"id":"1","size":1,"capturedAt":1,"schemaVersion":6}]}',
  '{"contractVersion":1.0,"backups":[]}',
  '{"contractVersion":2,"backups":[]}',
  '{"contractVersion":"1","backups":[]}',
  '{"contractVersion":true,"backups":[]}',
  '{"backups":[]}',
  '{"contractVersion":1}',
  '{"contractVersion":1,"backups":{}}',
  '{"contractVersion":1,"backups":null}',
  '{"contractVersion":1,"backups":[{"id":"1","size":1,"capturedAt":1}]}',
  '{"contractVersion":1,"backups":[{"id":1,"size":1,"capturedAt":1,"schemaVersion":1}]}',
  '{"contractVersion":1,"backups":[{"id":"1","size":"1","capturedAt":1,"schemaVersion":1}]}',
  '{"contractVersion":1,"backups":[{"id":"1","size":1,"capturedAt":1,"schemaVersion":true}]}',
  '{"contractVersion":1,"backups":[null]}',
  '{"contractVersion":1,"backups":[{"id":"1","size":1,"capturedAt":1,"schemaVersion":1,"extra":"x"}]}',
  '[]',
  'null',
];

/** JSON values for JS String() / Number() coercion. */
const COERCION_VALUES: string[] = [
  '"text"', '""', '"  42  "', '" 0x1F "', '"1e3"', '"-5"', '"+5"', '"5."', '".5"', '"Infinity"', '"-Infinity"',
  '"1,2"', '"0b101"', '"0o17"', '"12px"', '"\\u00a0 7 \\ufeff"',
  '0', '-0', '1', '-1', '1.5', '0.1', '100', '1e21', '1e20', '123456789012345680000', '0.000001',
  '0.0000001', '1e-7', '-2.5e-9', '5e-324', '1.7976931348623157e308', '9007199254740993', '12345678901234567890',
  '0.30000000000000004', '1234.5678', '-1e-6',
  'true', 'false', 'null', '[]', '[7]', '["8"]', '[1,2]', '[null]', '[[1,2],3]', '[true]', '{}', '{"a":1}',
];

const URI_COMPONENTS: string[] = [
  '', 'abc', 'a/b', 'a b', 'a+b', "-_.!~*'()", '#?&=%', '@:;,$', '[]{}|\\^`"<>', 'drop-zone',
  '11111111-2222-4333-8444-555555555555', 'é', 'Straße', '日本', '🔧', 'a\u0000b', ' ', 'Ünïcödé 🔧 x/y?z',
];

describe('network client vectors', () => {
  it('writes client-vectors.json', async () => {
    const household = [];
    for (const [status, text] of HOUSEHOLD_RESPONSES) {
      household.push({
        status,
        body: text,
        outcome: wellFormed(
          await outcomeOf(() =>
            householdRequest({ origin: 'https://inventory.example', path: '/v1/x', token: 't', fetchImpl: respond(status, text) }),
          ),
        ),
      });
    }

    const devices = [];
    for (const text of DEVICE_BODIES) {
      devices.push({
        body: text,
        outcome: await outcomeOf(() => listDevices(session, { fetchImpl: respond(200, text) })),
      });
    }

    const recognition = RECOGNITION_BODIES.map((text) => ({
      body: text,
      result: wellFormed(parseRecognitionResponse(JSON.parse(text))),
    }));

    const backupLists = BACKUP_LISTS.map((text) => ({
      body: text,
      result: parseBackupList(JSON.parse(text)),
    }));

    const coercion = COERCION_VALUES.map((text) => {
      const value = JSON.parse(text) as unknown;
      const number = Number(value);
      return {
        json: text,
        string: String(value),
        number: Number.isNaN(number) ? null : Number.isFinite(number) ? number : String(number),
        numberString: typeof value === 'number' ? String(value) : null,
      };
    });

    const uriComponents = URI_COMPONENTS.map((value) => ({ value, encoded: encodeURIComponent(value) }));

    writeFileSync(
      join(OUT, 'client-vectors.json'),
      `${JSON.stringify({ household, devices, recognition, backupLists, coercion, uriComponents }, null, 1)}\n`,
    );
  });
});
