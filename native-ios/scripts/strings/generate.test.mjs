// Tests for generate.mjs's native copy files: node --test 'native-ios/scripts/strings/*.test.mjs'
//
// Each case writes native files into a temporary directory and runs the
// generator on them with --validate (build and verify everything, write
// nothing), so the committed outputs are never touched.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GENERATOR = path.join(HERE, 'generate.mjs');

function run(args) {
  const result = spawnSync(process.execPath, [GENERATOR, ...args], { encoding: 'utf8' });
  return { status: result.status, out: `${result.stdout}${result.stderr}` };
}

function withNativeFiles(files, body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'strings-native-'));
  try {
    for (const [name, source] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), source);
    return body(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('the committed outputs match strings.ts and the native files (--check)', () => {
  const { status, out } = run(['--check']);
  assert.equal(status, 0, out);
});

test('native copy with text, formats and plurals is merged and verified', () => {
  withNativeFiles(
    {
      'home.ts': `import { plural } from '@/i18n/format';
export const strings = {
  home: { nativeOnlyExample: 'Plain text' },
  nativeExample: {
    /** A doc comment. */
    named: (name: string) => \`Hello \${name}\`,
    counted: (count: number) => \`\${plural(count, 'item', 'items')} left\`,
  },
};
`,
    },
    (dir) => {
      const { status, out } = run(['--validate', '--native-dir', dir]);
      assert.equal(status, 0, out);
      assert.match(out, /1 native files/);
    },
  );
});

test('a key that already exists in strings.ts fails', () => {
  withNativeFiles({ 'account.ts': `export const strings = { backup: { title: 'Another title' } };\n` }, (dir) => {
    const { status, out } = run(['--validate', '--native-dir', dir]);
    assert.equal(status, 1);
    assert.match(out, /native\/account\.ts: backup\.title already exists in src\/i18n\/strings\.ts/);
  });
});

test('a group that replaces a strings.ts entry fails', () => {
  withNativeFiles({ 'account.ts': `export const strings = { backup: { title: { nested: 'x' } } };\n` }, (dir) => {
    const { status, out } = run(['--validate', '--native-dir', dir]);
    assert.equal(status, 1);
    assert.match(out, /backup\.title already exists in src\/i18n\/strings\.ts/);
  });
});

test('a key that already exists in another native file fails', () => {
  withNativeFiles(
    {
      'home.ts': `export const strings = { shared: { example: 'From home' } };\n`,
      'item.ts': `export const strings = { shared: { example: 'From item' } };\n`,
    },
    (dir) => {
      const { status, out } = run(['--validate', '--native-dir', dir]);
      assert.equal(status, 1);
      assert.match(out, /native\/item\.ts: shared\.example already exists in native\/home\.ts/);
    },
  );
});

test('a native file not named after an area fails', () => {
  withNativeFiles({ 'misc.ts': `export const strings = { misc: { example: 'x' } };\n` }, (dir) => {
    const { status, out } = run(['--validate', '--native-dir', dir]);
    assert.equal(status, 1);
    assert.match(out, /native\/misc\.ts is not named after an area/);
  });
});

test('a boolean branch in native copy fails with advice', () => {
  withNativeFiles(
    { 'labels.ts': `export const strings = { labelsExample: { pick: (on: boolean) => (on ? 'On' : 'Off') } };\n` },
    (dir) => {
      const { status, out } = run(['--validate', '--native-dir', dir]);
      assert.equal(status, 1);
      assert.match(out, /give each branch its own key/);
    },
  );
});
