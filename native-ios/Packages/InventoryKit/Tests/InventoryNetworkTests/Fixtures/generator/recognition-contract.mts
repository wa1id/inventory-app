/**
 * Records the recognition endpoint's real answers (server/api/recognize.ts, with
 * a scripted vision adapter in place of Anthropic) for the request the native
 * RecognitionClient sends, and what the server handed the adapter: the declared
 * media type (U6: the real one, now) and the cleaned name hint.
 *
 * Writes Tests/InventoryNetworkTests/Fixtures/recognition-contract.json. To regenerate, in a worktree:
 *
 *   ln -s /home/walid/inventory-app/server/node_modules server/node_modules
 *   cd server && node --import tsx \
 *     ../native-ios/Packages/InventoryKit/Tests/InventoryNetworkTests/Fixtures/generator/recognition-contract.mts
 */
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const OUT = join(dirname(process.argv[1] ?? '.'), '..', 'recognition-contract.json');
const ENDPOINT = 'https://server.example/api/recognize';
const APP_KEY = 'app-key';
const WEBP = Buffer.concat([Buffer.from('RIFF'), Buffer.from([0x20, 0, 0, 0]), Buffer.from('WEBPVP8 fake photo bytes')]);

process.env.RECOGNITION_ADAPTER = 'fixture';
process.env.RECOGNITION_SHARED_SECRET = APP_KEY;

type Script = 'ok' | 'unrecognized' | 'rate_limited' | 'timeout' | 'upstream';

interface Exchange {
  request: { headers: Record<string, string>; json: string | null };
  response: { status: number; contentType: string | null; text: string };
  adapterSaw: { mediaType: string; byteLength: number; nameHint: string | null } | null;
}

async function main(): Promise<void> {
  const { registerAdapter } = await import('../../../../../../../server/src/registry.ts');
  const { toRawSuggestion } = await import('../../../../../../../server/src/prompt.ts');
  const { parseRequest } = await import('../../../../../../../server/src/contract.ts');

  let script: Script = 'ok';
  let saw: Exchange['adapterSaw'] = null;
  registerAdapter('fixture', () => ({
    id: 'fixture',
    label: 'Scripted adapter for contract fixtures',
    async recognize({ image, nameHint }) {
      saw = { mediaType: image.mediaType, byteLength: image.bytes.byteLength, nameHint: nameHint ?? null };
      switch (script) {
        case 'ok':
          return {
            status: 'ok',
            suggestion: toRawSuggestion(
              { identified: true, name: ' Cordless Drill ', category: 'Power Tools', tags: ['DeWalt', '18V', 'dewalt', '  '], confidence: 0.92 },
              nameHint,
            ),
          };
        case 'unrecognized':
          return { status: 'unrecognized' };
        default:
          return { status: 'error', kind: script, message: 'scripted' };
      }
    },
  }));
  const { POST } = await import('../../../../../../../server/api/recognize.ts');

  const exchanges: Record<string, Exchange> = {};

  async function record(
    name: string,
    body: unknown,
    options: { script?: Script; key?: string | null; raw?: string; recordBody?: boolean } = {},
  ): Promise<void> {
    script = options.script ?? 'ok';
    saw = null;
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'X-Contract-Version': '1' };
    const key = options.key === undefined ? APP_KEY : options.key;
    if (key) headers['x-inventory-key'] = key;
    const text = options.raw ?? JSON.stringify(body);
    const response = await POST(new Request(ENDPOINT, { method: 'POST', headers, body: text }));
    exchanges[name] = {
      request: { headers, json: options.recordBody === false ? null : text },
      response: {
        status: response.status,
        contentType: response.headers.get('content-type'),
        text: await response.text(),
      },
      adapterSaw: saw,
    };
  }

  const image = { data: WEBP.toString('base64'), encoding: 'base64', mediaType: 'image/webp' };
  await record('success', { contractVersion: 1, image });
  await record('successHinted', { contractVersion: 1, image, nameHint: 'Angle   grinder' });
  await record('unrecognized', { contractVersion: 1, image }, { script: 'unrecognized' });
  await record('rateLimited', { contractVersion: 1, image }, { script: 'rate_limited' });
  await record('providerTimeout', { contractVersion: 1, image }, { script: 'timeout' });
  await record('upstream', { contractVersion: 1, image }, { script: 'upstream' });
  await record('missingKey', { contractVersion: 1, image }, { key: null });
  await record('wrongKey', { contractVersion: 1, image }, { key: 'nope' });
  await record('notJSON', null, { raw: 'not json' });
  await record('wrongVersion', { contractVersion: 2, image });
  await record('emptyImage', { contractVersion: 1, image: { ...image, data: '' } });
  await record(
    'tooLarge',
    { contractVersion: 1, image: { ...image, data: 'A'.repeat(8 * 1024 * 1024 * 1.4 + 4) } },
    { recordBody: false },
  );

  // What parseRequest makes of each media type the client can sniff.
  const mediaTypes = ['image/webp', 'image/jpeg', 'image/png', 'image/gif'].map((mediaType) => {
    const parsed = parseRequest({ contractVersion: 1, image: { ...image, mediaType } });
    return { sent: mediaType, accepted: parsed.ok ? parsed.mediaType : null };
  });

  writeFileSync(OUT, `${JSON.stringify({ endpoint: ENDPOINT, appKey: APP_KEY, image: image.data, exchanges, mediaTypes }, null, 1)}\n`);
  console.log(`wrote ${Object.keys(exchanges).length} exchanges to ${OUT}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
