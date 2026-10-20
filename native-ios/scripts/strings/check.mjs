#!/usr/bin/env node
/**
 * Keeps the String Catalog strict (DECISIONS U9, spec 08 §2): every check the
 * compiler cannot make about the app's copy.
 *
 *   node native-ios/scripts/strings/check.mjs            run the checks; exit 1 on a problem
 *   node native-ios/scripts/strings/check.mjs --unused   also list the catalog keys no native code reads
 *
 * 1. The generated outputs are current (`generate.mjs --check`).
 * 2. Every `L10n.…` chain in App/ names a member generate.mjs emitted (or one
 *    composed in L10n+Logic.swift), followed only by String API.
 * 3. No user-facing English is hard-coded in App/: a string literal with letters
 *    as the title of `Text`, `Label`, `Button` and the other stock titled
 *    controls, in `.navigationTitle`, `.accessibilityLabel/Hint/Value`, `.help`,
 *    `.alert`, `.confirmationDialog`, `.badge`, `.accessibilityAction(named:)`, as
 *    a `prompt:`, or as the copy argument of our own components (`label:`,
 *    `title:`, `message:`, …), including either side of `? :`, a `??` default
 *    and a `+` concatenation. `String(localized:)`, `LocalizedStringKey` and
 *    `LocalizedStringResource` are never used outside InventoryStrings. Code
 *    under `#if DEBUG` (galleries, demos), `#Preview` bodies (Release builds
 *    drop them) and `Text(verbatim:)` are exempt; so is a line that ends with
 *    `// l10n-ok: <reason>`.
 * 4. With --unused: the catalog keys that no native code reads (App/ and the
 *    package sources, generated L10n.swift aside). They stay in the catalog
 *    while RN still reads strings.ts; the list is for docs/RELEASE.md.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const NATIVE = path.resolve(HERE, '../..');
const APP = path.join(NATIVE, 'App');
const SOURCES = path.join(NATIVE, 'Packages/InventoryKit/Sources');
const GENERATED_L10N = path.join(SOURCES, 'InventoryStrings/L10n.swift');
const ARGS = process.argv.slice(2);
const appDir = (() => {
  const at = ARGS.indexOf('--app-dir');
  return at >= 0 ? path.resolve(ARGS[at + 1]) : APP;
})();

let problems = 0;
const report = (message) => {
  problems++;
  console.error(message);
};

// ---------------------------------------------------------------------------
// Swift source helpers.
// ---------------------------------------------------------------------------

function swiftFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir, { withFileTypes: true, recursive: true })
    .filter((e) => e.isFile() && e.name.endsWith('.swift'))
    .map((e) => path.join(e.parentPath ?? e.path, e.name))
    .sort();
}

/**
 * Reads one string literal starting at `src[at]` (the opening quote of `"…"`,
 * `"""…"""` or a raw `#"…"#`). Returns its text with each interpolation
 * replaced by U+FFFC, and the index just past it.
 */
function readStringLiteral(src, at) {
  let hashes = 0;
  let i = at;
  while (src[i] === '#') {
    hashes++;
    i++;
  }
  const multiline = src.startsWith('"""', i);
  const quote = multiline ? '"""' : '"';
  i += quote.length;
  const close = quote + '#'.repeat(hashes);
  const escape = '\\' + '#'.repeat(hashes);
  let text = '';
  while (i < src.length) {
    if (src.startsWith(close, i)) return { text, end: i + close.length };
    if (!multiline && src[i] === '\n') return { text, end: i };
    if (src.startsWith(escape, i)) {
      i += escape.length;
      if (src[i] === '(') {
        // Interpolation: skip to the matching parenthesis, stepping over nested literals.
        let depth = 0;
        for (; i < src.length; i++) {
          if (src[i] === '"' || (src[i] === '#' && src[i + 1] === '"')) {
            i = readStringLiteral(src, i).end - 1;
          } else if (src[i] === '(') depth++;
          else if (src[i] === ')' && --depth === 0) break;
        }
        text += '￼';
        i++;
      } else {
        text += src[i] ?? '';
        i++;
      }
      continue;
    }
    text += src[i];
    i++;
  }
  return { text, end: i };
}

/**
 * The source with comments blanked (newlines kept) and string literals intact,
 * plus a per-line flag for code that only exists under `#if DEBUG`.
 */
function prepare(src) {
  let out = '';
  for (let i = 0; i < src.length; ) {
    if (src.startsWith('//', i)) {
      const end = src.indexOf('\n', i);
      const stop = end < 0 ? src.length : end;
      out += ' '.repeat(stop - i);
      i = stop;
    } else if (src.startsWith('/*', i)) {
      let depth = 0;
      let j = i;
      for (; j < src.length; j++) {
        if (src.startsWith('/*', j)) {
          depth++;
          j++;
        } else if (src.startsWith('*/', j)) {
          depth--;
          j++;
          if (depth === 0) {
            j++;
            break;
          }
        }
      }
      out += src.slice(i, j).replace(/[^\n]/g, ' ');
      i = j;
    } else if (src[i] === '"' || (src[i] === '#' && /^#+"/.test(src.slice(i, i + 8)))) {
      const { end } = readStringLiteral(src, i);
      out += src.slice(i, end);
      i = end;
    } else {
      out += src[i];
      i++;
    }
  }
  // #if DEBUG regions (and the #else of #if !DEBUG); other conditions are neutral.
  const lines = out.split('\n');
  const debugOnly = [];
  const stack = [];
  for (const line of lines) {
    const directive = line.trim().match(/^#(if|elseif|else|endif)\b\s*(.*)$/);
    if (directive) {
      const [, kind, condition] = directive;
      if (kind === 'if') stack.push({ debug: condition.trim() === 'DEBUG' ? 'if' : condition.trim() === '!DEBUG' ? 'else' : null, branch: 'if' });
      else if (kind === 'elseif' || kind === 'else') {
        const top = stack[stack.length - 1];
        if (top) top.branch = kind === 'else' ? 'else' : 'elseif';
      } else stack.pop();
      debugOnly.push(true);
      continue;
    }
    debugOnly.push(stack.some((f) => f.debug !== null && f.branch === f.debug));
  }
  // `#Preview { … }` bodies: the compiler drops previews from Release builds
  // (scripts/release/check-release.sh checks the binary), so they count as DEBUG code.
  for (const m of out.matchAll(/#Preview\b/g)) {
    let i = m.index + m[0].length;
    let depth = 0;
    // Skip the macro's arguments, then take the trailing closure.
    for (; i < out.length; i++) {
      const c = out[i];
      if (c === '"' || (c === '#' && out[i + 1] === '"')) i = readStringLiteral(out, i).end - 1;
      else if (c === '(') depth++;
      else if (c === ')') depth--;
      else if (c === '{' && depth === 0) break;
    }
    const start = i;
    depth = 0;
    for (; i < out.length; i++) {
      const c = out[i];
      if (c === '"' || (c === '#' && out[i + 1] === '"')) i = readStringLiteral(out, i).end - 1;
      else if (c === '{') depth++;
      else if (c === '}' && --depth === 0) break;
    }
    const first = lineOf(out, m.index);
    const last = lineOf(out, Math.max(start, i));
    for (let line = first; line <= last; line++) debugOnly[line - 1] = true;
  }
  return { code: out, lines, debugOnly };
}

const lineOf = (code, index) => code.slice(0, index).split('\n').length;
const hasLetters = (text) => /\p{L}/u.test(text.replace(/￼/g, ''));
/** A reverse-DNS name (`com.wystudio.inventory.camera`): a queue or log label, not copy. */
const isReverseDNS = (text) => /^[a-z][a-z0-9-]*(\.[A-Za-z0-9-]+){2,}$/.test(text);

// ---------------------------------------------------------------------------
// 1. Generated outputs are current, and the accessor manifest.
// ---------------------------------------------------------------------------

const manifestPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'strings-check-')), 'manifest.json');
const generated = spawnSync(process.execPath, [path.join(HERE, 'generate.mjs'), '--check', '--manifest', manifestPath], { encoding: 'utf8' });
if (generated.status !== 0) {
  report(`generate.mjs --check failed:\n${generated.stdout}${generated.stderr}`);
  process.exit(1);
}
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
fs.rmSync(path.dirname(manifestPath), { recursive: true, force: true });
const accessors = new Set(manifest.accessors);

// ---------------------------------------------------------------------------
// 2 and 3. App/ sources.
// ---------------------------------------------------------------------------

/** Stock controls and modifiers whose first argument is a title (a LocalizedStringKey literal). */
const TITLED_CALLS = [
  'Text', 'Label', 'Button', 'Toggle', 'TextField', 'SecureField', 'Picker', 'Section', 'Menu', 'Link',
  'NavigationLink', 'LabeledContent', 'ContentUnavailableView', 'ProgressView', 'Stepper', 'DatePicker',
  'Tab', 'Gauge', 'ShareLink', 'ControlGroup', 'DisclosureGroup', 'GroupBox',
  '.navigationTitle', '.navigationSubtitle', '.accessibilityLabel', '.accessibilityHint', '.accessibilityValue',
  '.help', '.alert', '.confirmationDialog', '.badge', '.accessibilityCustomContent', '.accessibilityAction',
];
/** Argument labels that carry copy, in stock API (`prompt:`) and in our components. */
const COPY_LABELS = [
  'prompt', 'label', 'title', 'message', 'body', 'subtitle', 'placeholder', 'hint', 'caption',
  'accessibilityLabel', 'accessibilityHint', 'confirmLabel', 'cancelLabel', 'text', 'heading', 'notice',
];
// A control (`Text(`) must not follow a word or a dot (`MyText(`, `x.Text(`); a modifier
// (`.navigationTitle(`) may follow anything, `content.accessibilityLabel(…)` included.
const titledPattern = new RegExp(
  `(?:(?:^|[^\\w.])(${TITLED_CALLS.filter((c) => !c.startsWith('.')).join('|')})|(${TITLED_CALLS.filter((c) => c.startsWith('.')).map((c) => `\\${c}`).join('|')}))\\(`,
  'g',
);
const labelPattern = new RegExp(`[(,]\\s*(${COPY_LABELS.join('|')}):`, 'g');

/**
 * The string literals of one argument that starts at `start` (just past `(`, `,` or a label's
 * `:`), up to its top-level `,` or the call's `)`. Only literals at the argument's own level
 * count: the title itself, either side of `? :` or `??`, and a `+` concatenation; a literal
 * inside a nested call (`L10n.Item.count(name: "x")`) or a closure is that call's business.
 */
function argumentLiterals(code, start) {
  const found = [];
  let depth = 0;
  for (let i = start; i < code.length; i++) {
    const c = code[i];
    if (c === '"' || (c === '#' && /^#+"/.test(code.slice(i, i + 8)))) {
      const { text, end } = readStringLiteral(code, i);
      if (depth === 0) found.push({ at: i, text });
      i = end - 1;
    } else if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') {
      if (depth === 0) break;
      depth--;
    } else if (c === ',' && depth === 0) break;
  }
  return found;
}

/**
 * The copy literals of a titled call whose `(` ends at `open`: its first argument, unless that
 * argument is labelled (`Text(verbatim:)`, `Button(action:)`, `.alert(isPresented:)`); the
 * labelled title of `.accessibilityAction(named:)` counts.
 */
function titleLiterals(code, open) {
  const rest = code.slice(open, open + 80);
  const label = rest.match(/^\s*([A-Za-z_]\w*)\s*:(?!:)/);
  if (!label) return argumentLiterals(code, open);
  if (label[1] === 'named') return argumentLiterals(code, open + label[0].length);
  return [];
}
const localizedPattern = /\b(String\(localized:|LocalizedStringKey\(|LocalizedStringResource\(|NSLocalizedString\(|L10nRuntime\.)/g;
// Members may be keyword-escaped: L10n.Onboarding.`continue`.
const chainPattern = /\bL10n((?:\.`?[A-Za-z_][A-Za-z0-9_]*`?)+)/g;
const unescape = (chain) => chain.replace(/`/g, '');
const aliasPattern = /\btypealias\s+([A-Za-z_]\w*)\s*=\s*(L10n(?:\.[A-Za-z_]\w*)+)|\blet\s+([A-Za-z_]\w*)\s*=\s*(L10n(?:\.[A-Za-z_]\w*)+)\.self\b/g;

/**
 * Every `L10n.…` chain in `code`, direct or through an alias (`typealias Copy =
 * L10n.Privacy`, `let names = L10n.Entities.TypeNames.self`). An alias applies
 * from its declaration to the next declaration of the same name, so two scopes
 * of one file may each have their own `Copy`.
 */
function l10nChains(code) {
  const found = [];
  for (const m of code.matchAll(chainPattern)) found.push({ index: m.index, chain: unescape(`L10n${m[1]}`), text: m[0] });
  const definitions = [...code.matchAll(aliasPattern)].map((m) => ({ name: m[1] ?? m[3], target: m[2] ?? m[4], index: m.index }));
  for (const name of new Set(definitions.map((d) => d.name))) {
    const own = definitions.filter((d) => d.name === name);
    for (const m of code.matchAll(new RegExp(`\\b${name}((?:\\.\`?[A-Za-z_][A-Za-z0-9_]*\`?)+)`, 'g'))) {
      const definition = own.filter((d) => d.index < m.index).pop();
      if (definition) found.push({ index: m.index, chain: unescape(`${definition.target}${m[1]}`), text: m[0] });
    }
  }
  return { found, definitions };
}

/** Resolves an `L10n.…` chain: the longest accessor prefix, and whether what follows is allowed. */
function resolveChain(chain) {
  const parts = chain.split('.');
  for (let n = parts.length; n >= 1; n--) {
    const prefix = parts.slice(0, n).join('.');
    if (!accessors.has(prefix)) continue;
    const rest = parts.slice(n);
    // A group must be followed by one of its members; a leaf may be followed by String API.
    const isGroup = manifest.accessors.some((a) => a.startsWith(`${prefix}.`));
    const restIsMember = rest.length > 0 && isGroup;
    return { prefix, ok: !restIsMember, rest };
  }
  return { prefix: null, ok: false, rest: parts };
}

const appFiles = swiftFiles(appDir);
for (const file of appFiles) {
  const rel = path.relative(NATIVE, file);
  const src = fs.readFileSync(file, 'utf8');
  const { code, lines, debugOnly } = prepare(src);
  const rawLines = src.split('\n');
  const exempt = (line) => debugOnly[line - 1] || /\/\/\s*l10n-ok:\s*\S/.test(rawLines[line - 1] ?? '');
  const where = (index) => `${rel}:${lineOf(code, index)}`;

  const reportCopy = (literals, name) => {
    for (const { at, text } of literals) {
      if (exempt(lineOf(code, at)) || !hasLetters(text) || isReverseDNS(text)) continue;
      report(`${where(at)}: hard-coded copy ${JSON.stringify(text.slice(0, 60))} in ${name}; use L10n (native-only copy: scripts/strings/native/<area>.ts)`);
    }
  };
  titledPattern.lastIndex = 0;
  for (let m; (m = titledPattern.exec(code)); ) {
    reportCopy(titleLiterals(code, m.index + m[0].length), `${m[1] ?? m[2]}(…)`);
  }
  labelPattern.lastIndex = 0;
  for (let m; (m = labelPattern.exec(code)); ) {
    reportCopy(argumentLiterals(code, m.index + m[0].length), `${m[1]}:`);
  }
  localizedPattern.lastIndex = 0;
  for (let m; (m = localizedPattern.exec(code)); ) {
    const line = lineOf(code, m.index);
    if (exempt(line)) continue;
    report(`${where(m.index)}: ${m[1]} outside InventoryStrings; read copy through L10n`);
  }

  const { found, definitions } = l10nChains(code);
  for (const d of definitions) {
    if (!accessors.has(d.target)) report(`${where(d.index)}: alias ${d.name} = ${d.target} names no L10n group`);
  }
  for (const { index, chain, text } of found) {
    const { prefix, ok, rest } = resolveChain(chain);
    if (!prefix || !ok) report(`${where(index)}: ${text} (${chain}) is not an L10n member (unknown: ${rest.join('.')})`);
  }
}

// The package reads copy through L10n too: no lookup of its own outside InventoryStrings.
for (const file of swiftFiles(SOURCES)) {
  if (file.includes(`${path.sep}InventoryStrings${path.sep}`)) continue;
  const { code, debugOnly } = prepare(fs.readFileSync(file, 'utf8'));
  for (const m of code.matchAll(localizedPattern)) {
    const line = lineOf(code, m.index);
    if (!debugOnly[line - 1]) report(`${path.relative(NATIVE, file)}:${line}: ${m[1]} outside InventoryStrings; read copy through L10n`);
  }
}

// ---------------------------------------------------------------------------
// 4. Catalog keys no native code reads.
// ---------------------------------------------------------------------------

function referencedAccessors() {
  const files = [...swiftFiles(appDir), ...swiftFiles(SOURCES)].filter(
    (f) => f !== GENERATED_L10N && !f.includes(`${path.sep}InventoryTestSupport${path.sep}`),
  );
  const all = new Set();
  const release = new Set();
  const add = (chain, debug) => {
    const parts = chain.split('.');
    for (let n = parts.length; n >= 1; n--) {
      const prefix = parts.slice(0, n).join('.');
      if (accessors.has(prefix)) {
        all.add(prefix);
        if (!debug) release.add(prefix);
        return;
      }
    }
  };
  for (const file of files) {
    const src = fs.readFileSync(file, 'utf8');
    const { code, debugOnly } = prepare(src);
    const isDebug = (index) => debugOnly[lineOf(code, index) - 1];
    // Inside `extension L10n.X { … }` (L10n+Logic.swift, InventoryCore helpers) members are
    // reached without the prefix; count `Self.member` and bare uses through the extension's path.
    const scopes = [...code.matchAll(/\bextension\s+(L10n(?:\.\w+)*)\s*\{/g)].map((m) => m[1]);
    for (const { index, chain } of l10nChains(code).found) add(chain, isDebug(index));
    for (const scope of scopes) {
      // A call, not the declaration of the function itself.
      for (const m of code.matchAll(/(?<!func\s+)\b(?:Self\.)?([a-z]\w*)\s*\(/g)) add(`${scope}.${m[1]}`, isDebug(m.index));
    }
    if (/\bFormat\.ago\(|\bago\(/.test(code)) {
      all.add('Format.ago');
      release.add('Format.ago');
    }
  }
  return { all, release };
}

if (ARGS.includes('--unused')) {
  const { all, release } = referencedAccessors();
  // A map used whole (its subscript, allKeys or an alias of it) reads every entry; an entry
  // named on its own (`L10n.Entities.TypeNames.box`) reads just that one.
  const isRead = (entry, set) =>
    set.has(entry.accessor) ||
    (entry.kind === 'map' && (set.has(`${entry.accessor}.allKeys`) || (entry.member !== null && set.has(entry.member))));
  const unused = [];
  const debugOnly = [];
  for (const [key, entry] of Object.entries(manifest.keys)) {
    if (!isRead(entry, all)) unused.push(key);
    else if (!isRead(entry, release)) debugOnly.push(key);
  }
  console.log(`${unused.length} of ${Object.keys(manifest.keys).length} catalog keys are read by no native code:`);
  for (const key of unused) console.log(`  ${key}`);
  console.log(`${debugOnly.length} more are read only by DEBUG code (galleries, demos, previews):`);
  for (const key of debugOnly) console.log(`  ${key}`);
}

if (problems > 0) {
  console.error(`check.mjs: ${problems} problem(s)`);
  process.exit(1);
}
console.log(`check.mjs: catalog current; ${appFiles.length} App files have no hard-coded copy and only known L10n members.`);
