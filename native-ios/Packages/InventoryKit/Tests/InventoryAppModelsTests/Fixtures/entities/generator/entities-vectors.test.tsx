/**
 * Generates the parity vectors for InventoryAppModels' entity logic (Sources/InventoryAppModels/
 * Entities) from the real TypeScript: src/ui/components/ItemForm.tsx (validateItemForm,
 * applySuggestion), src/ui/components/SuggestionBanner.tsx (staleSuggestionName),
 * src/ui/item/itemDetails.ts, src/ui/container/containerRules.ts, src/ui/spaces/spaceSetup.ts,
 * src/ui/add/addSheet.ts and the `localeCompare(b, 'en', {sensitivity: 'base'})` order the
 * sorts rely on.
 *
 * The inputs lean on what Swift gets wrong by default: JS `trim()` white space (NBSP, BOM,
 * U+3000, line separators) against what it leaves (U+0085, U+200B), canonically equivalent
 * strings that JS `===` tells apart, case mapping beyond ASCII, and `Number()` forms.
 *
 * Not part of the RN test suite. It runs in the `ui` project because ItemForm.tsx and
 * SuggestionBanner.tsx import React Native. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryAppModelsTests/Fixtures/entities/generator/entities-vectors.test.tsx \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects ui
 *   rm -r src/__vectors__
 *
 * The JSON lands next to this folder, in Tests/InventoryAppModelsTests/Fixtures/entities/.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { formHasContent, hasDetails, photoFromParams, toPositiveInt } from '@/ui/add/addSheet';
import { applySuggestion, validateItemForm, type ItemFormValues } from '@/ui/components/ItemForm';
import { staleSuggestionName, type SuggestionState } from '@/ui/components/SuggestionBanner';
import { labelOf, shareText, sortContents, titleOf, typeNameOf } from '@/ui/container/containerRules';
import { detailsDirty, detailsSeed, keepsUnnamed, rebaseDetails } from '@/ui/item/itemDetails';
import {
  byContainerLabel,
  containerLabel,
  containerValuesChanged,
  isNameTaken,
  spaceValuesChanged,
  takenSpaceNames,
} from '@/ui/spaces/spaceSetup';

const OUT = join(
  __dirname,
  '../../../native-ios/Packages/InventoryKit/Tests/InventoryAppModelsTests/Fixtures/entities',
);

const EMPTY: ItemFormValues = { name: '', category: '', tags: '', quantity: '1', notes: '' };

/** Text that probes JS trim and equality: kept, stripped, and canonically equivalent pairs. */
const TEXT = [
  '',
  ' ',
  '   ',
  ' ',
  '﻿',
  '　',
  ' ',
  '\u0085',
  '​',
  'Drill',
  ' Drill ',
  ' Drill﻿',
  '　Drill ',
  '\u0085Drill',
  'Drill​',
  'Café',
  'Café',
  ' Café ',
  'İstanbul',
  'ΟΔΟΣ',
];

const QUANTITY = [
  '', ' ', '1', '0', '-1', '1.5', 'abc', ' 12 ', '1.0', '1e3', '0x10', '+5', '5.', '٣',
  '10000', ' 12﻿', '\u008512', '1_000', 'Infinity', '-0', '0b11', '9007199254740993',
];

const TAGS = [
  '',
  ' power tool ,, dewalt , ',
  'a,b',
  'a, b',
  ' a ,　, b ,',
  'a,́b',
  '\u0085,a',
  'garage,power ',
  ',,,',
  'Café,Café',
];

function values(overrides: Partial<ItemFormValues>): ItemFormValues {
  return { ...EMPTY, ...overrides };
}

// MARK: - localeCompare

const COLLATION = [
  'a', 'A', 'á', 'Á', 'b', 'B', 'ae', 'Æble', 'æble', 'oe', 'Œuvre', 'ss', 'ß', 'strasse', 'straße',
  'batteries', 'Batteries', 'Éclairs', 'eclairs', 'Allen keys', 'allen keys', 'Zip ties', 'zip ties',
  'Screws', 'screws', '10 screws', '2 screws', 'box 10', 'box 2', 'box-2', 'box2', '-dash', '_under',
  ' space', '(paren)', '#hash', 'émile', 'Emile', 'Ölkanne', 'olkanne', 'Zebra', 'zebra', 'ÿ', 'y',
  'Кухня', 'кухня', 'Ελλάδα', 'ελλαδα', '中文', '日本', '😀 smile', 'Ø', 'O', 'ø', 'Ł', 'L', 'ﬁle',
  'file', 'BOX-4F2A', 'BOX-4f2a', 'box4f2a', 'Ångström', 'Angstrom', 'İstanbul', 'istanbul', 'ı', 'i',
  'drawer by the oven', 'Étagère', 'Attic box', 'Cafe', 'Café', 'Café', 'Tool chest', 'tool-chest',
  'tool chest', 'Garage shelf', '', ' ', 'A1', 'A10', 'A2', 'Ab', 'aB', 'AB',
];

const localeCompare: { a: string; b: string; sign: number }[] = [];
for (let i = 0; i < COLLATION.length; i += 1) {
  for (let j = i + 1; j < COLLATION.length; j += 1) {
    const a = COLLATION[i] as string;
    const b = COLLATION[j] as string;
    localeCompare.push({ a, b, sign: Math.sign(a.localeCompare(b, 'en', { sensitivity: 'base' })) });
  }
}

// MARK: - Sorts

const contentLists = [
  [
    { id: 'u2', name: '', createdAt: 20 },
    { id: 'b', name: 'batteries', createdAt: 5 },
    { id: 'e', name: 'Éclairs', createdAt: 6 },
    { id: 'u1', name: '  ', createdAt: 10 },
    { id: 'a', name: 'Allen keys', createdAt: 7 },
    { id: 'z', name: 'Zip ties', createdAt: 1 },
  ],
  [
    { id: 'later', name: 'Screws', createdAt: 9 },
    { id: 'first', name: 'screws', createdAt: 3 },
    { id: 'cafe2', name: 'Café', createdAt: 4 },
    { id: 'cafe1', name: 'Cafe', createdAt: 8 },
    { id: 'cafe3', name: 'Café', createdAt: 2 },
    { id: 'nbsp', name: ' ', createdAt: 1 },
    { id: 'nel', name: '\u0085', createdAt: 30 },
    { id: 'zw', name: '​', createdAt: 31 },
    { id: 'ten', name: '10 screws', createdAt: 11 },
    { id: 'two', name: '2 screws', createdAt: 12 },
  ],
  [
    { id: 'k1', name: 'кухня', createdAt: 3 },
    { id: 'k2', name: 'Кухня', createdAt: 1 },
    { id: 'g', name: 'Ελλάδα', createdAt: 2 },
    { id: 'c', name: '中文', createdAt: 5 },
    { id: 'e', name: '😀 smile', createdAt: 6 },
    { id: 'p', name: '(paren)', createdAt: 7 },
    { id: 'd', name: '-dash', createdAt: 8 },
    { id: 's', name: ' space', createdAt: 9 },
    { id: 'x', name: '﻿Zebra', createdAt: 10 },
  ],
];

const sortContentsVectors = contentLists.map((items) => ({
  items,
  expected: sortContents(items).map((item) => item.id),
}));

const containerLists = [
  [
    { name: 'drawer by the oven', shortCode: 'DRW-7K2M' },
    { name: null, shortCode: 'BOX-4F2A' },
    { name: 'Étagère', shortCode: 'SHF-2222' },
    { name: 'Attic box', shortCode: 'BOX-9999' },
  ],
  [
    { name: 'Tool chest', shortCode: 'CAB-J92R' },
    { name: 'tool chest', shortCode: 'CAB-AAAA' },
    { name: null, shortCode: 'BOX-2222' },
    { name: null, shortCode: 'box-2222' },
    { name: 'Café', shortCode: 'BIN-3333' },
    { name: 'Cafe', shortCode: 'BIN-4444' },
    { name: ' ', shortCode: 'BAG-5555' },
    { name: '', shortCode: 'BAG-6666' },
    { name: 'Zebra', shortCode: 'CRT-7777' },
    { name: 'Ølkanne', shortCode: 'CTR-8888' },
  ],
];

const byContainerLabelVectors = containerLists.map((containers) => ({
  containers,
  expected: [...containers]
    .map((container, index) => ({ container, index }))
    .sort((a, b) => byContainerLabel(a.container, b.container))
    .map((entry) => entry.index),
  labels: containers.map(containerLabel),
}));

// MARK: - Item form

const validate = [
  ...TEXT.map((name) => values({ name })),
  ...QUANTITY.map((quantity) => values({ name: 'Drill', quantity })),
  ...TAGS.map((tags) => values({ name: 'Drill', tags })),
  ...TEXT.map((category) => values({ name: 'Drill', category, notes: category })),
  values({ name: '', quantity: '-1' }),
].map((input) => {
  const { errors, parsed } = validateItemForm(input);
  return { input, errors: Object.keys(errors).sort(), parsed };
});

const suggestions = [
  { name: 'Cordless drill', category: 'Power Tools', tags: ['dewalt', '18v'], confidence: 0.9 },
  { name: null, category: null, tags: [], confidence: 0.6 },
  { name: 'Shoebox', category: '', tags: [' a ', ''], confidence: 0.5 },
];
const currents = [
  EMPTY,
  values({ name: ' ', category: ' ', tags: ' ' }),
  values({ name: 'Angle grinder', category: 'Garage', quantity: '3', notes: 'top shelf' }),
  values({ name: ' ', tags: 'blender, mixing' }),
];
const apply: unknown[] = [];
for (const current of currents) {
  for (const suggestion of suggestions) {
    for (const overwrite of [false, true]) {
      apply.push({ current, suggestion, overwrite, expected: applySuggestion(current, suggestion, { overwrite }) });
    }
  }
}

const STATES: SuggestionState[] = [
  { status: 'idle' },
  { status: 'running' },
  { status: 'refreshing' },
  { status: 'failed', reason: 'offline' },
  { status: 'applied', confidence: 0.9, forName: 'Cordless drill' },
  { status: 'applied', confidence: 0.9, forName: 'Café' },
  { status: 'refreshed', forName: 'Café' },
  { status: 'refreshed', forName: '' },
];
const STALE_TYPED = [...TEXT, 'Cordless drill', '  Cordless drill  ', 'cordless drill', 'Angle grinder'];
const stale: unknown[] = [];
for (const state of STATES) {
  for (const typed of STALE_TYPED) {
    stale.push({ state, typed, expected: staleSuggestionName(state, typed) });
  }
}

// MARK: - Item details

const sources = [
  { name: 'Cordless drill', category: 'Tools', tags: ['garage', 'power'], notes: null, quantity: 2 },
  { name: '', category: null, tags: [], notes: 'Charger ', quantity: 0 },
  { name: 'Café', category: ' ', tags: ['Café', ' x '], notes: '', quantity: 12345 },
];
const seeds = sources.map((source) => ({ source, expected: detailsSeed(source) }));

const base = detailsSeed(sources[0] as (typeof sources)[number]);
const edits: ItemFormValues[] = [
  base,
  { ...base, name: ' Cordless drill ', tags: 'garage,power ' },
  { ...base, name: ' Cordless drill﻿' },
  { ...base, name: '\u0085Cordless drill' },
  { ...base, name: 'Drill' },
  { ...base, category: '' },
  { ...base, category: '　Tools' },
  { ...base, tags: 'garage' },
  { ...base, tags: 'garage,　power' },
  { ...base, tags: 'garage,power,' },
  { ...base, tags: 'power, garage' },
  { ...base, notes: 'Charger in the bag' },
  { ...base, notes: ' ' },
  { ...base, quantity: '5' },
  { ...base, name: 'Cordless dríll' },
];
const theirs = detailsSeed({ ...sources[0], notes: 'Charger in the bag', quantity: 3 } as (typeof sources)[number]);
const details = edits.map((edit) => ({
  values: edit,
  seed: base,
  theirs,
  dirty: detailsDirty(edit, base),
  rebased: rebaseDetails(edit, base, theirs),
}));

const keepsUnnamedVectors: unknown[] = [];
for (const stored of ['', ' ', 'Batteries']) {
  for (const typed of TEXT) {
    keepsUnnamedVectors.push({ stored, typed, expected: keepsUnnamed(stored, typed) });
  }
}

// MARK: - Container rules

const NAMES: (string | null)[] = [null, ...TEXT];
const TYPES = ['box', 'drawer', 'shelf', 'cabinet', 'bin', 'bag', 'crate', 'other', 'Box', 'suitcase', '', ' box'];
const containerRules: unknown[] = [];
for (const name of NAMES) {
  containerRules.push({
    name,
    labelOf: labelOf({ name, shortCode: 'BOX-7K2M' }),
    titleOf: titleOf({ name, visualType: 'drawer' }),
    shareText: shareText({ name, shortCode: 'BOX-7K2M' }, 'inventory://c/' + 'a'.repeat(32), { withPayload: true }),
  });
}
const typeNames = TYPES.map((type) => ({
  type,
  typeName: typeNameOf(type),
  title: titleOf({ name: null, visualType: type }),
}));

// MARK: - Space setup

const SPACE_NAMES = [' garage ', 'Kitchen', 'İstanbul', 'ΟΔΟΣ', 'Ǆungla', 'Straße', ' Loft﻿', '\u0085Shed', 'Café'];
const PROBES = ['Garage', 'KITCHEN', 'Loft', 'i̇stanbul', 'istanbul', 'İSTANBUL', 'οδος', 'οδοσ', 'ǆungla', 'strasse', 'STRASSE', 'Shed', '\u0085shed', 'Café', 'café'];
const taken = takenSpaceNames(SPACE_NAMES.map((name) => ({ name })));
const takenNames = {
  spaces: SPACE_NAMES,
  keys: [...taken],
  probes: PROBES.map((name) => ({ name, taken: isNameTaken(name, taken) })),
};

const spaceInitial = { name: 'Garage', icon: '🛋️', color: '#5B8DEF' };
const spaceChanges = [
  spaceInitial,
  { ...spaceInitial, name: ' Garage ' },
  { ...spaceInitial, name: ' Garage　' },
  { ...spaceInitial, name: '\u0085Garage' },
  { ...spaceInitial, name: 'garage' },
  { ...spaceInitial, icon: '🛋' },
  { ...spaceInitial, color: '#5b8def' },
  { ...spaceInitial, name: 'Shed' },
].map((next) => ({ values: next, initial: spaceInitial, changed: spaceValuesChanged(next, spaceInitial) }));

const containerInitial = { name: 'Café', visualType: 'cabinet', spaceId: 'garage' };
const containerChanges = [
  containerInitial,
  { ...containerInitial, name: 'Café ' },
  { ...containerInitial, name: 'Café' },
  { ...containerInitial, name: '' },
  { ...containerInitial, name: '﻿Café' },
  { ...containerInitial, visualType: 'Cabinet' },
  { ...containerInitial, spaceId: 'loft' },
].map((next) => ({ values: next, initial: containerInitial, changed: containerValuesChanged(next, containerInitial) }));

// MARK: - Add sheet

const POSITIVE = [
  '1400', '', '0', '-3', '2.5', 'wide', ' 12 ', '1e3', '0x10', '1.0', '+5', '0b11', '0o7', 'Infinity',
  '9007199254740993', '1e400', ' 7﻿', '\u00857', '٣', '5.', '.5e1', '-0', '00012',
];
const positiveInts = POSITIVE.map((value) => ({ value, expected: toPositiveInt(value) ?? null }));

const params = [
  {},
  { photoUri: '' },
  { photoUri: 'file:///p.webp', photoThumbUri: '', photoWidth: '1400', photoHeight: ' 1050 ', photoBytes: 'x' },
  { photoUri: 'file:///p.webp', photoThumbUri: 'file:///p-thumb.webp', photoBytes: '1e3' },
].map((input) => ({ params: input, photo: photoFromParams(input) }));

const content = [
  ...TEXT.map((name) => values({ name })),
  ...TEXT.map((tags) => values({ tags })),
  ...QUANTITY.map((quantity) => values({ quantity })),
].map((input) => ({
  values: input,
  hasDetails: hasDetails(input),
  hasContent: formHasContent(input, null, EMPTY),
}));

writeFileSync(
  join(OUT, 'entities-vectors.json'),
  `${JSON.stringify(
    {
      localeCompare,
      sortContents: sortContentsVectors,
      byContainerLabel: byContainerLabelVectors,
      validate,
      applySuggestion: apply,
      staleSuggestionName: stale,
      detailsSeed: seeds,
      details,
      keepsUnnamed: keepsUnnamedVectors,
      containerRules,
      typeNames,
      takenNames,
      spaceValuesChanged: spaceChanges,
      containerValuesChanged: containerChanges,
      toPositiveInt: positiveInts,
      photoFromParams: params,
      content,
    },
    null,
    1,
  )}\n`,
);

it('writes the entity vectors', () => {
  expect(localeCompare.length).toBeGreaterThan(0);
});
