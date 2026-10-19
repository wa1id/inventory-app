/**
 * Generates the InventoryCore parity vectors from the real TypeScript.
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryCoreTests/Fixtures/generator/core-vectors.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * The JSON lands next to this folder, in Tests/InventoryCoreTests/Fixtures/.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { toHex } from '@/core/bytes';
import { configureRandomBytes, newId, newQrToken } from '@/core/id';
import { clampQuantity, parseQuantityInput } from '@/core/quantity';
import { generateShortCode, normalizeShortCode } from '@/core/shortCode';
import { compactAlphanumeric, toLikePattern, tokenizeQuery } from '@/core/tokenize';
import { CONTAINER_VISUAL_TYPES, type ContainerVisualType } from '@/db/types';
import { strings } from '@/i18n/strings';
import { decodeBase32, encodeBase32, formatRecoveryCode } from '@/services/account/base32';
import { deriveAccountId } from '@/services/account/identity';
import { quantitySpoken, spellCode, whereSpoken, type PlaceLike } from '@/ui/a11y';
import { formatCode, invalidCodeChars, normaliseCode } from '@/ui/code';
import { contrast, luminance, mixHex, rgb, safeColor, spaceTint, toHex as colorHex, withAlpha } from '@/ui/color';
import { codeProblem, serverHost } from '@/ui/household/join';
import { matchesPlace, placeTerms } from '@/ui/placeMatch';
import { parseQrPayload } from '@/repositories/qr';

// identity.ts imports the native keystore module; only its pure hash is used here.
jest.mock('expo-secure-store', () => ({}));

const OUT = join(__dirname, '../../../native-ios/Packages/InventoryKit/Tests/InventoryCoreTests/Fixtures');

function write(name: string, data: unknown): void {
  writeFileSync(join(OUT, name), `${JSON.stringify(data, null, 1)}\n`);
}

/** Deterministic PRNG so regenerating gives the same files. */
function lcg(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x100000000;
  };
}

const SPEC_EXAMPLES = [
  'Cordless Drill', 'BOX-7K2M', '-drill-', 'a--b- --c', 'Café', 'ワイヤー', 'ガラス', 'ﬁle Ⅻ ①', 'ΟΔΟΣ',
  'İstanbul', 'emoji 🔧x', 'under_score', "o'neil", 'Straße', '™ 𝐀BC ℌ ㎒ Ｆｕｌｌ', '™ 𝐀BC ℌ ㎒', 'ǅ',
  'ΣΑΣ Σ', 'aΣ.', 'USB-C', 'usb c', 'usb/c', 'usbc', 'Küche', 'Кухня', 'a\\b', 'ΟΔΟΣ sign', '™',
];

const TEST_INPUTS = [
  '', '   ', '!!! ??? ...', 'drill drill DRILL', 'screws, nails; bolts', '18v battery', 'DRW-7K2M',
  ' Tool  chest! ', '50%', 'a_b', 'box-7k2m', '  drw-7k  garage - ', 'кухня', 'кух', 'kuche',
  'Microusb cable', 'USB-C to USB-A cable', 'widget 4242', 'garage drill', 'drill kitchen',
];

const SIGMA = [
  'ΣΣ', 'Σ', 'Σa', 'AΣ', 'aΣb', 'ΑΣ1', 'ΑΣ.Β', "ΑΣ'Β", 'ΑΣ’Β', 'ʰΣ', 'Σʰ', 'a\u0301Σ', 'Σ\u0301',
  'ὈΔΥΣΣΕΎΣ', 'ΑΣ\u00ADΒ', 'Α\u00ADΣ', 'ΑΣ\u200DΒ', 'ΑΣ:Β', 'ΑΣ·Β', 'ΑΣ\u0345', '\u0345Σ',
  'ΑΣ𐐀', 'ΑΣ😀', 'ΑΣ Β', 'ΑΣ-Β', 'ΑΣ_Β', 'Σ.Σ', '.Σ.', 'ΣΑΣΑΣ', 'ΑΣΣ', 'ǅΣ', 'ⅯΣ', 'ⒶΣ', '1Σ',
];

const CASE_AND_COMPAT = [
  'İ', 'I\u0307', 'ı', 'Ĳ', 'ŉ', 'ǰ', 'ẞ', 'ß', 'ﬀ', 'ﬃ', 'ﬆ', 'ΐ', 'ΰ', 'Ϊ', 'Å', 'Å', 'K', 'Ω',
  'ſ', 'µ', 'Ǆemo', 'ǈ', 'ǋ', 'ǲ', 'Ǳ', 'DŽ', 'Ꭰ', 'Ა', '𐐀', '𐐨', 'Ⓐⓑ', 'ⓔⓜⓞⓙⓘ', 'ℌℍℕ', '℡',
  '℃', '℉', '㈱', '㍿', '㎏', '㎡', 'Ⅻ xii XII', 'ⅯⅭⅮ', '𝒳𝓎', '𝔄𝔟', 'Ｆｕｌｌ', 'e\u0301', 'é', 'Ä',
  'A\u0308', 'Café cafe CAFÉ', 'ᾈ', 'ᾳ', 'ῼ', 'Ⴀ', 'ⴀ', 'ǅemo', 'Ꙁ', 'Ա', 'ﬓ', 'ǈub',
];

const NUMBERS = [
  'Ⅻ', 'ⅻ', 'Ⅳ', '①②⑳', '⓪', '²³¹', '½', '¾', '٣', '١٢٣', '४२', '𝟘𝟙', '⁰', '₂', 'Ⅿ', '〇', '十', '𐄇',
  '1,5', '1.5', '3/4', '10%', '#1', '१२३', '٠١', '¹²',
];

const PUNCTUATION = [
  'ＡＢＣ１２３', 'ａ－ｂ', 'a﹣b', 'a‐b', 'a‑b', 'a–b', 'a—b', 'a−b', 'a⁻b', 'a_b', 'a·b', 'a/b', 'a.b',
  "a'b", 'a’b', 'a&b', 'a+b', 'a#b', 'a@b', 'a%b', 'a\\b', 'a(b)', 'a[b]', 'a"b"', 'a«b»', 'a—', '---',
  '-', '- -', 'a-', '-a', '--a--b--', '1-2-3', 'BOX-7K2M box7k2m', '-BOX-', 'box_7k2m', 'a－', '－a－',
];

const SCRIPTS = [
  'नमस्ते', 'हिन्दी', 'ภาษาไทย', 'שָׁלוֹם', 'مَرْحَبًا', 'العربية', '한국어', '가나다', 'ㄱㄴ', 'ｶﾞﾗｽ',
  'ﾊﾟﾝ', 'パン', 'ぱん', '漢字', 'Ελληνικά', 'Привет мир', 'Ünïcödé', 'Ångström', 'Çà et là', 'Œuvre',
  'Æsir', 'Øresund', 'Łódź', 'Đà Nẵng', 'Tiếng Việt', 'ქართული', 'Հայերեն', 'ᏣᎳᎩ', 'ꯃꯤ',
];

const EMOJI = [
  '👍🏽', '👨‍👩‍👧', '🇧🇪', '1️⃣', '#️⃣', '❤️', '☺', '✓', '🔧🔨', 'tool🧰box', '🛋️ sofa',
];

const WHITESPACE = [
  'a\u00A0b', 'a\u2028b', 'a\u2029b', 'a\uFEFFb', 'a\u0085b', 'a\tb\nc\rd', 'a\u3000b', 'a\u200Bb',
  'a\u2060b', '\u00A0lead', 'trail\u00A0', '\uFEFFbom', '\u0085nel', 'nel\u0085', '\u1680x\u180E',
  '\u2000\u200Ax\u202F\u205F', '\u000B\u000Cx', ' \n\t ', '\u200B', 'a\u00ADb',
];

/** Compatibility forms whose NFKD output brings spaces, punctuation or capitals back after lowercasing. */
const COMPAT_MORE = [
  '№5', '⑴⒜', '⒈⒉', '㉐', '㏇', '🄰🄱', '🄐', '℀', '㋌', '㍱', '¨', 'a¨b', '´', 'a´b', '¯x', 'x˘y', '‼',
  '⁇', '…', 'a…b', '﹏', '︳', '⅓', '↉', '⁄', 'ẛ', 'ẖ', 'և', 'ꭰ', 'ᏸ', 'Ᏸ', 'Ɪ', 'ᲀ', 'Ꙋ', 'ǆ', 'Ǉ',
  'ﬅ', 'ﺀ', 'ﷺ', '﷽', 'ﾊﾞ', 'ﾟ', 'ｰ', '〜', '〰', '゛', '゜', 'ゟ', 'ヿ', '㌀', '㍻', 'ℓ', '℮', 'ℹ',
  '𝚺', '𝚺𝚺', 'Ϲ', 'ϲ', 'ϴ', 'ϑ', 'ϕ', 'ẞß', 'ǰ̌', 'ﬀﬃﬄ', '㎐', '㎑', '㎓', '㏒', 'Å', 'Ω', 'K',
];

/**
 * Case mappings in scripts the main corpus misses, up to Unicode 16 (Garay, Tulu-Tigalari, U+1C89).
 * Unicode 17 letters (e.g. U+323B0, CJK Extension J) are left out: Node 24 knows them, the
 * macOS 15 test host does not, so they would test the host's Unicode tables, not our code.
 */
const CASE_MORE = [
  '𐒰𐓘', '𞤀𞤢', '𐲀𐳀', '𑢠𑣀', '𖹀𖹠', '𐕰𐖗', 'ⰀⰰⱠⱡ', 'ⴀႠ', 'ꞪɦꞫɜ', 'Ʂʂ', 'ꞰʞꞱʇ', 'Ᶎᶎ', 'Ꟑꟑ', 'Ɐɐ',
  'Ᲊᲊ', 'Ꟍꟍ', 'Ƛƛ', '𐵐𐵰', '𑎀', '𑼄', '𞀰', '𰀀', '𱍐', '\u{2EBF0}', 'ΆΈΉΊΌΎΏ', 'ΪΫ', 'ᾼῌῼ',
  'ᾈᾉᾊ', 'ǅǈǋǲ', 'İİ', 'İ́', 'Ii̇', 'ΣΣΣ', 'ϹΣ', 'Σϲ',
];

/** More Final_Sigma contexts: marks, format characters and letters of other cases around Σ. */
const SIGMA_MORE = [
  'ΑΣ́', 'ΑΣ́Β', 'ΑΣ​', 'ΑΣ​Β', 'ΑΣ﻿Β', 'ΑΣ­Β', 'ἈΣ', '́Σ',
  'ΑΣ’', 'ΑΣ\'', 'ΑΣ.', 'ΑΣ:', 'ΑΣ·', 'ΑΣ·Β', 'ΑΣ״Β', 'ΑΣ‘Β', 'ΑΣʼΒ',
  'ΑΣʰ', 'ΑΣʰΒ', 'ΑΣᴬΒ', 'ΑΣⅯ', 'ΑΣⓐ', 'ΑΣ𝐀', 'ΑΣ𝚺', 'ΑΣͅΒ', 'ΑΣ゙Β',
  'ΑΣัΒ', 'ΑΣिΒ', 'ΑΣ⃝Β', 'ΑΣ\u{E0001}Β', 'ΑΣ\u{1F3FB}', 'ΑΣ\u{1F3FB}Β', 'ΑΣ️Β',
  'Σ\u{1D400}', '\u{1D400}Σ', 'ꭰΣ', 'ᏸΣ', 'ǅΣ', 'ʰΣ', 'ᵃΣ', 'ªΣ', 'ºΣ', 'ΑΣ Β', 'ΑΣ Β',
];

/** Strings made only of marks, separators or format characters. */
const EDGES = [
  '́', '́́a', 'á́', '゙', '‍', '⁠', '­', '﻿',
  '\u0000', 'a\u0000b', '�', '\u{10FFFF}', '\u{E000}', '\u{F0000}', '͸', '\u{E0041}',
];

const TOKEN = '0123456789abcdefABCDEF0123456789';
const QR = [
  `inventory://c/${TOKEN}`, TOKEN, ` ${TOKEN}\n`, ` inventory://c/${TOKEN}﻿`, `INVENTORY://c/${TOKEN}`,
  `inventory://c/${TOKEN}0`, TOKEN.slice(1), `inventory://c/ ${TOKEN}`, `inventory://c/inventory://c/${TOKEN}`,
  `${TOKEN.slice(0, 31)}g`, `${TOKEN.slice(0, 31)}０`, `inventory:/c/${TOKEN}`, `\u0085${TOKEN}`,
];

function buildCorpus(): string[] {
  const out = [
    ...SPEC_EXAMPLES, ...TEST_INPUTS, ...SIGMA, ...CASE_AND_COMPAT, ...NUMBERS, ...PUNCTUATION,
    ...SCRIPTS, ...EMOJI, ...WHITESPACE, ...QR, ...COMPAT_MORE, ...CASE_MORE, ...SIGMA_MORE, ...EDGES,
    Array.from({ length: 40 }, (_, i) => `term${i}`).join(' '),
    Array.from({ length: 13 }, (_, i) => String.fromCharCode(97 + i)).join(' '),
    'a b a c b d e f g h i j k l m n',
  ];
  const pool = [
    ...'abcXYZ019 -_./\'%\\,;:!?', 'Σ', 'σ', 'ς', 'Α', 'Ω', 'ʰ', '\u0301', '\u0308', '\u0327', '\u3099',
    '\u0345', 'ß', 'ẞ', 'İ', 'ı', 'ﬁ', 'Ⅻ', '①', '０', 'Ａ', 'ｂ', '－', '‐', '–', '🔧', '👍🏽', '漢', '가',
    'ｶ', 'ﾞ', 'ガ', 'न', '्', 'ি', '\u00A0', '\u00AD', '\u200D', '\uFEFF', '\u2028', '\u0085', 'ǅ', 'Ǆ',
    '™', '𝐀', 'ℌ', '㎒', 'µ', 'K', 'Å', 'é', 'e\u0301', '٣', '²', 'Ꭰ', '𐐀', '\t', '\n',
  ];
  const random = lcg(20261019);
  for (let n = 0; n < 400; n += 1) {
    const length = 1 + Math.floor(random() * 12);
    let s = '';
    for (let i = 0; i < length; i += 1) s += pool[Math.floor(random() * pool.length)];
    out.push(s);
  }
  return out;
}

const TYPE_NAMES = strings.entities.typeNames;

// Not exported by the RN modules, so restated verbatim here (same JS built-ins, same order).
/** src/repositories/items.ts:126-128 (also src/services/household/shadow.ts:225-226). */
function normalizeTag(tag: string): string {
  return tag.trim().toLowerCase();
}
/** src/repositories/items.ts:130-132 (also src/services/household/shadow.ts:153). */
function searchTextFor(name: string, category: string | null): string {
  return `${name} ${category ?? ''}`.trim().toLowerCase();
}

describe('InventoryCore parity vectors', () => {
  it('writes folding.json', () => {
    const entries = buildCorpus().map((input) => {
      const normalised = normaliseCode(input);
      return {
        input,
        // Code points of the input, so the Swift side can check JSON decoding kept every scalar.
        codePoints: [...input].map((char) => char.codePointAt(0)),
        lower: input.toLowerCase(),
        upper: input.toUpperCase(),
        trim: input.trim(),
        tokens: tokenizeQuery(input),
        compact: compactAlphanumeric(input),
        placeTerms: placeTerms(input),
        like: toLikePattern(input),
        normalizeShortCode: normalizeShortCode(input),
        normaliseCode: normalised,
        invalidCodeChars: invalidCodeChars(normalised),
        spellCode: spellCode(input),
        qr: parseQrPayload(input),
      };
    });
    write('folding.json', entries);
  });

  it('writes storedText.json', () => {
    const corpus = buildCorpus();
    const pairs: [string, string | null][] = [
      ['', null], ['', ''], ['Drill', null], ['  Drill ', ' Tools '], ['ΟΔΟΣ', 'ΣΑΣ'], ['Drill', 'ΣΑΣ'],
      ['ΑΣ', null], ['ΑΣ', ''], ['ΑΣ', ' '], ['\uFEFFİstanbul\u00A0', '\u0085Ünï'], ['Café', 'Küche'],
    ];
    corpus.forEach((name, index) => {
      pairs.push([name, index % 3 === 0 ? null : corpus[(index * 7 + 3) % corpus.length]!]);
    });
    write('storedText.json', {
      searchText: pairs.map(([name, category]) => ({ name, category, searchText: searchTextFor(name, category) })),
      tags: corpus.map((tag) => ({ tag, normalized: normalizeTag(tag) })),
    });
  });

  it('writes base32.json', async () => {
    const random = lcg(4242);
    const byteArrays: number[][] = [];
    for (let length = 0; length <= 20; length += 1) {
      byteArrays.push(Array.from({ length }, (_, i) => (i * 37 + length) & 0xff));
      byteArrays.push(Array.from({ length }, () => Math.floor(random() * 256)));
    }
    for (const fill of [0x00, 0x11, 0x42, 0xff, 0x09]) byteArrays.push(new Array(16).fill(fill));
    byteArrays.push(Array.from({ length: 16 }, (_, i) => i + 1));
    for (let n = 0; n < 40; n += 1) byteArrays.push(Array.from({ length: 16 }, () => Math.floor(random() * 256)));

    const encode = byteArrays.map((bytes) => ({
      hex: toHex(Uint8Array.from(bytes)),
      code: encodeBase32(Uint8Array.from(bytes)),
    }));

    const canonical = '89144GJ289144GJ289144GJ288';
    const decodeInputs = [
      '', '-', '--', '   ', 'Z', 'ZZ', '0', 'U', 'u', 'hello world', canonical, canonical.toLowerCase(),
      formatRecoveryCode(canonical), `  ${formatRecoveryCode(canonical).toLowerCase()}  `,
      `\n${canonical}\n`, `\u00A0${canonical}`, `\uFEFF${canonical}`, `${canonical}\u2028`,
      `\u0085${canonical}`, `${canonical.slice(0, 10)} ${canonical.slice(10)}`, `${canonical}X`,
      `${canonical}XY`, `${canonical.slice(0, 25)}9`, `${canonical.slice(0, 25)}A`, `${canonical.slice(0, 25)}B`,
      'IOIOIOIOIOIOIOIOIOIOIOIOIO', 'LOLOLOLOLOLOLOLOLOLOLOLOLO', '10101010101010101010101010',
      'ı', 'ﬁ', 'ß', 'ǰ', 'ö', 'Ａ', 'i', 'l', 'o', 'O0Il1L', '-8-9-1-4-4-', '8 9', '89144GJ2*9',
      'ZZZZZZZZZZZZZZZZZZZZZZZZZW', '00000000000000000000000000', '041061050R3GG28A1C60T3GF20',
      '248H248H248H248H248H248H24', 'abcdefghjkmnpqrstvwxyz', 'ABCDEFGHJKMNPQRSTVWXYZ0123456789',
      // Characters JS toUpperCase folds into the alphabet (ſ → S, ﬀ → FF) or next to it (K sign stays).
      'ſſſſſſſſ', 'ﬀﬀﬀﬀ', '\u212A\u212A', 'ŉ', 'ǅ', `${canonical.slice(0, 13)}\u00AD${canonical.slice(13)}`,
      `${canonical.slice(0, 13)}\u200B${canonical.slice(13)}`, `${canonical}\u0000`, `\t${canonical}\r\n`,
      `${canonical.slice(0, 13)}\u2010${canonical.slice(13)}`, `${canonical.slice(0, 13)}\uFF0D${canonical.slice(13)}`,
    ];
    const decode = decodeInputs.map((input) => {
      const bytes = decodeBase32(input);
      return { input, hex: bytes ? toHex(bytes) : null };
    });

    const formatInputs = [
      '', 'A', 'ABCDE', 'ABCDEF', canonical, 'MMWKYM2H78A', 'AB\nCD', 'ABCDEFG\r\nHIJ', 'AB\u2028CDEFGHIJK',
      '\n', 'ABCDE\n', '1234567890123', 'ÄÖÜäöüß', 'a b c d e f',
    ];
    const format = formatInputs.map((input) => ({
      input,
      formatRecoveryCode: formatRecoveryCode(input),
      formatCode: formatCode(input),
    }));

    const secrets = [
      ...[0x42, 0x00, 0xff, 0x11, 0x09].map((fill) => new Array(16).fill(fill)),
      Array.from({ length: 16 }, (_, i) => i + 1),
      [],
      [0x61],
      Array.from({ length: 32 }, (_, i) => i),
      ...Array.from({ length: 10 }, () => Array.from({ length: 16 }, () => Math.floor(random() * 256))),
    ];
    const accounts = [];
    for (const secret of secrets) {
      const bytes = Uint8Array.from(secret);
      accounts.push({
        hex: toHex(bytes),
        code: encodeBase32(bytes),
        formatted: formatRecoveryCode(encodeBase32(bytes)),
        accountId: await deriveAccountId(bytes),
      });
    }

    write('base32.json', { encode, decode, format, accounts });
  });

  it('writes ids.json', () => {
    const random = lcg(99);
    const byteArrays = [
      Array.from({ length: 16 }, (_, i) => i),
      new Array(16).fill(0xab),
      new Array(16).fill(0x00),
      new Array(16).fill(0xff),
      ...Array.from({ length: 20 }, () => Array.from({ length: 16 }, () => Math.floor(random() * 256))),
    ];
    const entries = byteArrays.map((bytes) => {
      configureRandomBytes(() => Uint8Array.from(bytes));
      const id = newId();
      configureRandomBytes(() => Uint8Array.from(bytes));
      const token = newQrToken();
      return { hex: toHex(Uint8Array.from(bytes)), id, token };
    });
    write('ids.json', entries);
  });

  it('writes quantity.json', () => {
    const inputs = [
      '', '   ', 'abc', '1.5', '-1', '0', ' 12 ', '1.0', '1e2', '0x1F', '0b11', '+5', '5.', '00012', '-0',
      ' 7\n', '12345', '.5', '1_000', 'Infinity', '٣', '1,5', '1e-7', '9999', '10000', '+0', '-0.0',
      '0.0', '000', '0x', '0X1f', '0o17', '0O17', '0b2', '0b', '-0x1F', '+0x1F', '1e', 'e5', '1e+2',
      '1E2', '.', '.e1', '1.e1', '.5e1', '1.5e1', '1.50', '2.000000', '1e400', '1e-400', '-1e-400',
      '9007199254740993', '9223372036854775807', '9223372036854775808', '12345678901234567890',
      '0xFFFFFFFFFFFFFFFFF', '1 2', '1\u00A0', '\uFEFF3', '\u00854', '４２', '①', '5-', '--5', '+-5',
      'infinity', '-Infinity', '+Infinity', 'NaN', '0.1e1', '100e-2', '1.23e2', '0e0', '0x0', '0b0',
      '0o0', '07', '08', '0.', '-.0', '- 1', '1 ', '\t8\t', '\u20283', '1e2.5', '1.2.3', '١',
      '0x1e2', '1e+', '1e-0', '+.5e1', '0b11e1', '1e0000000000000000002', '1e310', '4.9e-324',
      '9999.0000000000001', '9999.00000000000001', '1.0000000000000001', '０', '1\u00002', '5\u0000',
      '\u180E5', '5\u200B', '0x7FFFFFFFFFFFFFFF', '0x8000000000000000', '9223372036854774784',
      '0x', '0x_1', '0b1_0', '1__0', '+', '-', '++1', '1.', '.0', '0.e1', '00.5e1', '1E-2', '5e-1', '15e-1',
      `1${'0'.repeat(30)}e-30`, `0.${'0'.repeat(30)}1e31`,
    ];
    const parse = inputs.map((input) => {
      const value = parseQuantityInput(input);
      return { input, value: value === null ? null : String(value) };
    });
    const clampInputs = [0, 8, 9999, 10000, -1, 1.5, 0.5, -0.5, 123456789, -123456789, 9998.9999];
    const clamp = clampInputs.map((input) => ({ input, value: clampQuantity(input) }));
    write('quantity.json', { parse, clamp });
  });

  it('writes codes.json', () => {
    const prefixes = [...CONTAINER_VISUAL_TYPES, 'Box', 'unknown', '', 'BOX'].map((type) => ({
      type,
      prefix: generateShortCode(type as ContainerVisualType).split('-')[0],
    }));
    const codeInputs = [
      ' mmwky-m2h78 ', 'mmwky\nm2h78\t', 'il0o', 'ILO', 'U', 'ABUU!', 'MMWKY-M2H78', 'MMWKU-M2H7%',
      'MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S', 'mmwky m2h78 abcde fghjk mnpqr s', 'ı', 'ß', 'ﬁ', 'Ö', 'ü', 'é',
      'Ａ', '０', '🔧', '\u00A0A\u2028B\uFEFFC\u0085D', '–A—B', 'a_b', 'a.b', 'ʰ', '٣', 'ǅ',
      '', 'mmwky-m2h78-abcde-fghjk-mnpqr-sx', 'MMWKY-M2H78-ABCDE-FGH', 'ſ', 'ſoil', '89144-GJ289-144GJ-28914-4GJ28-8',
      '89144 gj289 144gj 28914 4gj28 8', 'MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S🔧', 'MMWKU-M2H7%', 'uu%%uu',
    ];
    const codes = codeInputs.map((input) => {
      const normalised = normaliseCode(input);
      return {
        input,
        normalised,
        invalid: invalidCodeChars(normalised),
        formatted: formatCode(normalised),
        problem: codeProblem(normalised),
      };
    });
    const hostInputs = [
      'https://inventory.wystudio.be', 'http://192.168.1.5:8788/', 'inventory.example', '  https://a.b/c?d#e  ',
      'HTTPS://Example.COM/path', 'ftp://x.y', 'web+app://host', '1http://host', 'http://', '   ', '',
      'https:/host', 'https://host?x=1', 'https://host#frag', 'host/path', '/path', 'http://[::1]:8080/',
      'a+b.c-d://h', 'mailto:me@x.y', 'https://user:pw@host:1/x', 'https://ex.com\n/abc', 'https://h/a\nb/c',
      'https://h/a\u2028b', '\u00A0https://h\u00A0', 'https://ünï.de/x', 'ſhttp://host', 'https://host/',
    ];
    const hosts = hostInputs.map((input) => ({ input, host: serverHost(input) }));
    write('codes.json', { prefixes, codes, hosts });
  });

  it('writes placeMatch.json', () => {
    const options = [
      { name: 'Drawer by the oven', shortCode: 'DRW-7K2M', spaceName: 'Kitchen', visualType: 'drawer' },
      { name: 'Tool chest', shortCode: 'CAB-J92R', spaceName: 'Garage', visualType: 'cabinet' },
      { name: null, shortCode: 'BOX-4F2A', spaceName: 'Loft', visualType: 'box' },
      { name: 'Küche', shortCode: 'DRW-1K2M', spaceName: 'Haus', visualType: 'drawer' },
      { name: 'Кухня', shortCode: 'BOX-4F2A', spaceName: 'Дом', visualType: 'box' },
      { name: 'tm', shortCode: 'BIN-2222', spaceName: 'Shed', visualType: 'bin' },
      { name: '', shortCode: 'CRT-9X', spaceName: 'Shed', visualType: 'crate' },
      { name: 'Odd type', shortCode: 'CTR-ABCD', spaceName: 'Attic', visualType: 'Box' },
      { name: 'ΟΔΟΣ', shortCode: 'SHF-ΣΣ', spaceName: 'Σπίτι', visualType: 'shelf' },
      { name: 'Ｆｕｌｌ ガラス', shortCode: 'BAG-0001', spaceName: '倉庫', visualType: 'bag' },
      { name: 'USB-C cables', shortCode: 'OTH-1', spaceName: 'Office', visualType: 'other' },
    ];
    const queries = [
      '', ' ', 'drw7k', 'DRW-7K2M', 'garage', 'cabinet', 'loft box', 'kitchen oven', 'kitchen garage',
      'kuche', 'Küche', 'кух', 'кухня', '™', 'tm', 'TM', 'box', 'container', 'crate', 'shed', 'οδος',
      'σπιτι', 'full', 'カラス', 'ガラス', '倉庫', 'usbc', 'usb c', 'usb-c', 'office other', 'container office',
      'ΟΔΟΣ', 'shf', 'shfσσ', '-', '!!', '7k2m drw', 'oven by', 'drawer',
    ];
    const results = options.map((option) => ({
      option,
      matches: queries.map((query) => matchesPlace(option, placeTerms(query))),
    }));
    write('placeMatch.json', { typeNames: TYPE_NAMES, queries, results });
  });

  it('writes a11y.json', () => {
    const base: PlaceLike = {
      containerId: 'c1',
      containerName: 'Tool chest',
      containerShortCode: 'CAB-J92R',
      spaceId: 's1',
      spaceName: 'Garage',
      spaceColor: '#5B8DEF',
    };
    const places: PlaceLike[] = [
      base,
      { ...base, containerName: null },
      { ...base, containerName: '' },
      { ...base, containerName: ' ' },
      { ...base, containerShortCode: '-AB--C-' },
      { ...base, containerShortCode: ' DRW - 7K2M ' },
      { ...base, containerId: 'drop-zone', containerName: 'Drop zone', containerShortCode: 'DROP-ZONE' },
      { ...base, spaceName: 'Küche', containerName: 'Ящик', containerShortCode: 'BOX-ÄÖ' },
    ];
    const where = places.map((place) => ({ place, spoken: whereSpoken(place) }));
    const quantities = [0, 1, 12, 9999, 10000].map((quantity) => ({ quantity, spoken: quantitySpoken(quantity) }));
    const spellInputs = ['DRW-7K2M', 'BOX1', '-AB--C-', '', '-', 'A', ' A B -C', 'É-ü', '🔧-x', 'a\u00A0b-c', 'DROP-ZONE'];
    const spell = spellInputs.map((input) => ({ input, spelled: spellCode(input) }));
    const copy = {
      inDropZone: strings.a11y.inDropZone,
      noneLeft: strings.rows.noneLeft,
      inPlace: strings.a11y.inPlace('%1$@', '%2$@', '%3$@'),
      inSpace: strings.a11y.inSpace('%1$@', '%2$@'),
      quantity: strings.rows.quantity(1234),
    };
    write('a11y.json', { copy, where, quantities, spell });
  });

  it('writes color.json', () => {
    const colorInputs = [
      '#5b8def', '5B8DEF', '  #0F9BB0 ', '#abc', '#abcd', '#11223344', '', 'blue', '#12', '#12345',
      '#GGGGGG', 'rgb(0,0,0)', '\uFEFF#5B8DEF', '\u00A0#5b8def\u00A0', 'abc', 'ABCD', '#5B8DEFF',
      '\u0085#5B8DEF', '＃５Ｂ８ＤＥＦ', '##abc', '#', 'abcdef12', '#ABCDEF1', '\n#fff\n', '#FfFfFf',
      '#000', '#0000', 'a\u0301bc', '٣٣٣',
    ];
    const safe = colorInputs.map((input) => ({ input, safe: safeColor(input), rgb: rgb(input) }));
    const channelTriples: [number, number, number][] = [
      [91, 141, 239], [-4, 255.6, 127.5], [0.5, 1.5, 2.5], [254.5, 254.49, 300], [0.49999999999999994, 10, 11],
      [-0.5, -0.4, 128.5],
    ];
    const hex = channelTriples.map(([r, g, b]) => ({ r, g, b, hex: colorHex(r, g, b) }));
    const palette = ['#5B8DEF', '#2E9E4F', '#E4572E', '#B15BEF', '#E0A800', '#0F9BB0', '#8A948D', '#000000', '#FFFFFF', 'junk'];
    const surfaces = ['#FFFFFF', '#E9ECE7', '#1C201E', '#141715'];
    const weights = [0, 0.24, 0.5, 0.45, 1, 0.333];
    const mix = [];
    for (const a of palette) for (const b of surfaces) for (const w of weights) mix.push({ a, b, weight: w, hex: mixHex(a, b, w) });
    const tint = [];
    for (const color of palette) for (const surface of surfaces) tint.push({ color, surface, hex: spaceTint(color, surface) });
    const alphas = [0, 0.45, 1, 0.5, -1, 2, 0.002, 0.998];
    const alpha = [];
    for (const color of ['#5B8DEF', '#abc', 'junk']) for (const a of alphas) alpha.push({ color, alpha: a, hex: withAlpha(color, a) });
    const lum = palette.map((color) => ({ color, luminance: luminance(color) }));
    const ratios = [];
    for (const a of palette) for (const b of palette) ratios.push({ a, b, contrast: contrast(a, b) });
    write('color.json', { safe, hex, mix, tint, alpha, luminance: lum, contrast: ratios });
  });
});
