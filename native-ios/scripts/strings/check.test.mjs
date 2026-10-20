// Tests for check.mjs, the String Catalog strictness check: node --test 'native-ios/scripts/strings/*.test.mjs'
//
// Each case writes Swift files into a temporary App directory and runs check.mjs on it with
// --app-dir, so the real App/ sources are only read by the first test.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CHECK = path.join(HERE, 'check.mjs');

function run(args) {
  const result = spawnSync(process.execPath, [CHECK, ...args], { encoding: 'utf8' });
  return { status: result.status, out: `${result.stdout}${result.stderr}` };
}

function withApp(files, body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'strings-check-'));
  try {
    for (const [name, source] of Object.entries(files)) {
      fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
      fs.writeFileSync(path.join(dir, name), source);
    }
    return body(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('the app sources pass: catalog current, no hard-coded copy, only known L10n members', () => {
  const { status, out } = run([]);
  assert.equal(status, 0, out);
});

test('hard-coded copy in shipping code is reported, with its line', () => {
  withApp(
    {
      'Screens/Bad.swift': `import SwiftUI
struct Bad: View {
    var body: some View {
        VStack {
            Text("Hello there")
            Button("Save") {}
            Label("Tools", systemImage: "hammer")
            Image(systemName: "camera").accessibilityLabel("Take a photo")
            LoadingButton(label: "Try again", fullWidth: true) {}
        }
        .navigationTitle("Settings")
        .accessibilityAction(named: "Delete") {}
        .searchable(text: .constant(""), prompt: "Find anything")
    }
    var title: String { String(localized: "home.title") }
}
`,
    },
    (dir) => {
      const { status, out } = run(['--app-dir', dir]);
      assert.equal(status, 1);
      for (const [line, text] of [
        [5, 'Hello there'], [6, 'Save'], [7, 'Tools'], [8, 'Take a photo'], [9, 'Try again'],
        [11, 'Settings'], [12, 'Delete'], [13, 'Find anything'],
      ]) {
        assert.match(out, new RegExp(`Bad\\.swift:${line}: hard-coded copy "${text}"`));
      }
      assert.match(out, /Bad\.swift:15: String\(localized: outside InventoryStrings/);
    },
  );
});

test('L10n, verbatim data, DEBUG code, previews, identifiers and justified lines pass', () => {
  withApp(
    {
      'Screens/Good.swift': `import SwiftUI
import InventoryStrings
struct Good: View {
    let name: String
    let count: Int
    private let queue = DispatchQueue(label: "com.wystudio.inventory.camera")
    var body: some View {
        VStack {
            Text(L10n.Common.cancel)
            Text(verbatim: name)
            Text("\\(count)")
            Text(L10n.Onboarding.\`continue\`.uppercased())
            Button(L10n.Common.close) {}.accessibilityIdentifier("sheet-close")
            Color("Tape")
            Text("Inventory") // l10n-ok: the brand name, never translated
        }
        .navigationTitle("")
    }
}

#if DEBUG
struct GoodGallery: View {
    var body: some View { Text("Gallery only") }
}
#endif

#Preview("Good") {
    Button("Preview only") {}
}
`,
    },
    (dir) => {
      const { status, out } = run(['--app-dir', dir]);
      assert.equal(status, 0, out);
    },
  );
});

test('an L10n member that does not exist is reported, through an alias too', () => {
  withApp(
    {
      'Screens/Unknown.swift': `import InventoryStrings
enum Unknown {
    static var a: String { L10n.Common.nope }
    static var b: String {
        typealias Copy = L10n.Privacy
        return Copy.title + Copy.missing
    }
    static var c: String { L10n.Nowhere.title }
}
`,
    },
    (dir) => {
      const { status, out } = run(['--app-dir', dir]);
      assert.equal(status, 1);
      assert.match(out, /Unknown\.swift:3: L10n\.Common\.nope .*is not an L10n member/);
      assert.match(out, /Unknown\.swift:6: Copy\.missing \(L10n\.Privacy\.missing\) is not an L10n member/);
      assert.doesNotMatch(out, /Copy\.title/);
      assert.match(out, /Unknown\.swift:8: L10n\.Nowhere\.title/);
    },
  );
});

test('--unused lists the catalog keys no native code reads', () => {
  const { status, out } = run(['--unused']);
  assert.equal(status, 0, out);
  assert.match(out, /of \d+ catalog keys are read by no native code/);
  // Read only through a typealias in SyncStatus.swift.
  assert.doesNotMatch(out, /^ {2}settings\.backupSummary\.on$/m);
  // Read as L10n.Onboarding.`continue`.
  assert.doesNotMatch(out, /^ {2}onboarding\.continue$/m);
});
