/**
 * Generates the AppConfig and describeError parity vectors from the real TypeScript
 * (src/services/config.ts and src/ui/errors.ts).
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryCoreTests/Fixtures/generator/app-vectors.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * The JSON lands next to this folder, in Tests/InventoryCoreTests/Fixtures/.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { ConflictError } from '@/core/conflict';
import { HouseholdHttpError } from '@/services/household/client';
import {
  describeError,
  isOffline,
  needsRefreshBanner,
  type ErrorContext,
  type ErrorSubject,
} from '@/ui/errors';

const OUT = join(__dirname, '../../../native-ios/Packages/InventoryKit/Tests/InventoryCoreTests/Fixtures');

function write(name: string, data: unknown): void {
  writeFileSync(join(OUT, name), `${JSON.stringify(data, null, 1)}\n`);
}

const ENV_KEYS = [
  'EXPO_PUBLIC_RECOGNITION_URL',
  'EXPO_PUBLIC_RECOGNITION_KEY',
  'EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS',
  'EXPO_PUBLIC_SYNC_URL',
  'EXPO_PUBLIC_SYNC_KEY',
  'EXPO_PUBLIC_SYNC_TIMEOUT_MS',
  'EXPO_PUBLIC_HOUSEHOLD_ORIGIN',
  'EXPO_PUBLIC_ENV',
] as const;

type Env = Partial<Record<(typeof ENV_KEYS)[number], string>>;

/** `appConfig` as config.ts computes it at module load for `env`. */
function loadConfig(env: Env): Record<string, unknown> {
  for (const key of ENV_KEYS) delete process.env[key];
  Object.assign(process.env, env);
  let config: Record<string, unknown> = {};
  jest.isolateModules(() => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    config = require('@/services/config').appConfig;
  });
  for (const key of ENV_KEYS) delete process.env[key];
  return config;
}

/** Values for the string settings: white space (JS trim set, and what it leaves), slashes, empties. */
const TEXT = [
  '', ' ', '\t\n\r', 'https://a.example', 'https://a.example/', 'https://a.example///',
  ' https://a.example/ ', 'https://a.example/ /', 'https://a.example /', 'https://a.example/path/',
  'https://a.example/path//', '/', '///', ' / ', '/ /', 'https:/', 'http://192.168.1.5:8788/',
  '﻿https://a.example　', ' https://a.example/ ', ' https://a.example/ ',
  '\u0085https://a.example\u0085', '​https://a.example/​', '᠎https://a.example᠎',
  'https://a.example\\', 'https://a.example/\\/', 'https://a.example/?q=/', 'https://a.example/#/',
  '  key with spaces  ', 'k', 'ünïcode/', 'é/', '\u{1F511}//',
];

const ENVIRONMENTS = [
  '', 'production', 'preview', 'development', 'Production', 'PREVIEW', ' production', 'production ',
  'preview\n', 'staging', 'prod', 'test', '﻿preview',
];

const TIMEOUTS = [
  '', ' ', '15000', ' 20000 ', ' 30000﻿', '20000.7', '1.5e4', '.5e4', '5.', '+500', '0x3A98',
  '0X3a98', '0o17', '0b101', '0', '-0', '-1', '-20000', '0.4', '0.9999', '1', '1.9', 'abc', '12abc',
  'Infinity', '-Infinity', '+Infinity', 'infinity', 'NaN', '1e21', '1e400', '9007199254740993',
  '1_000', '1,000', '٣٠٠٠', '１５０００', '0x', '1e', 'e5',
];

const STATUSES = [0, 200, 400, 401, 403, 404, 409, 500, 501, 502, 503, 519, 520, 525, 530, 531];

const CODES = [
  'offline', 'timeout', 'http_502', 'http_530', 'http_520', 'http_519', 'http_531', 'http_500',
  'http_503', 'http_404', 'http_401', 'http_200', 'http_525', 'origin_down', 'unauthorized',
  'not_found', 'photo_missing', 'invalid_json', 'invalid_response', 'photos_not_configured',
  'conflict', '', 'http_5020', 'http_50', 'HTTP_502', 'http_502 ', ' http_502', 'http_502\n',
  'http_５０２', 'http_٥٠٢', 'Offline', 'TIMEOUT', 'Unauthorized',
  'not found', 'photo_missing ',
];

const CONTEXTS: ErrorContext[] = ['read', 'save', 'move', 'quantity', 'delete', 'label', 'join'];
const SUBJECTS: ErrorSubject[] = ['item', 'space', 'container', 'list'];

/** A cause as the Swift side rebuilds it. JS `undefined` and a plain `Error` both carry no class. */
type CauseSpec =
  | { type: 'http'; status: number; code: string }
  | { type: 'conflict'; updatedAt: number | null }
  | { type: 'null' }
  | { type: 'error'; message: string }
  | { type: 'undefined' };

function build(spec: CauseSpec): unknown {
  switch (spec.type) {
    case 'http':
      return new HouseholdHttpError(spec.status, spec.code);
    case 'conflict':
      return new ConflictError(spec.updatedAt);
    case 'null':
      return null;
    case 'error':
      return new Error(spec.message);
    case 'undefined':
      return undefined;
  }
}

describe('AppConfig and describeError parity vectors', () => {
  it('writes config.json', () => {
    const text = TEXT.map((value) => {
      const config = loadConfig({
        EXPO_PUBLIC_RECOGNITION_URL: value,
        EXPO_PUBLIC_RECOGNITION_KEY: value,
        EXPO_PUBLIC_SYNC_URL: value,
        EXPO_PUBLIC_SYNC_KEY: value,
        EXPO_PUBLIC_HOUSEHOLD_ORIGIN: value,
      });
      return {
        input: value,
        recognitionEndpoint: config.recognitionEndpoint,
        recognitionKey: config.recognitionKey,
        syncEndpoint: config.syncEndpoint,
        syncKey: config.syncKey,
        householdOrigin: config.householdOrigin,
      };
    });
    const environments = ENVIRONMENTS.map((value) => ({
      input: value,
      environment: loadConfig({ EXPO_PUBLIC_ENV: value }).environment,
    }));
    // JS keeps whatever `Number()` gives (0 and NaN abort a request at once); the native
    // parser falls back to the default for those (00-index §5, 09 §15 Q14), so record the raw number.
    const timeouts = TIMEOUTS.map((value) => {
      const config = loadConfig({
        EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS: value,
        EXPO_PUBLIC_SYNC_TIMEOUT_MS: value,
      });
      return {
        input: value,
        recognition: String(config.recognitionTimeoutMs),
        sync: String(config.syncTimeoutMs),
      };
    });
    const unset = loadConfig({});
    write('config.json', { unset, text, environments, timeouts });
  });

  it('writes errors.json', () => {
    const causes: CauseSpec[] = [];
    for (const status of STATUSES) {
      for (const code of CODES) causes.push({ type: 'http', status, code });
    }
    causes.push(
      { type: 'conflict', updatedAt: 1 },
      { type: 'conflict', updatedAt: null },
      { type: 'null' },
      { type: 'error', message: 'http_500 invalid_json' },
      { type: 'error', message: 'SQLITE_BUSY' },
      { type: 'undefined' },
    );

    // Titles and bodies are stored once and referenced by index, to keep the file small.
    const texts: string[] = [];
    const textIndex = (value: string): number => {
      const found = texts.indexOf(value);
      if (found >= 0) return found;
      texts.push(value);
      return texts.length - 1;
    };

    const entries = causes.map((spec) => {
      const cause = build(spec);
      // described[context][subject] = [kind, title index, body index]
      const described = CONTEXTS.map((context) =>
        SUBJECTS.map((subject) => {
          const result = describeError(cause, context, subject);
          return [result.kind, textIndex(result.title), textIndex(result.body)];
        }),
      );
      return {
        cause: spec,
        described,
        defaults: describeError(cause).kind,
        refreshBanner: needsRefreshBanner(true, cause),
        offline: isOffline(cause),
      };
    });
    // One entry per line: pretty-printing the nested arrays would make the file six times larger.
    writeFileSync(
      join(OUT, 'errors.json'),
      `{"contexts":${JSON.stringify(CONTEXTS)},\n"subjects":${JSON.stringify(SUBJECTS)},\n` +
        `"texts":${JSON.stringify(texts, null, 1)},\n` +
        `"entries":[\n${entries.map((entry) => JSON.stringify(entry)).join(',\n')}\n]}\n`,
    );
  });
});
