/**
 * Generates the parity vectors for InventoryAppModels' Home logic from the real TypeScript:
 * `splitHighlight` (src/ui/components/AppText.tsx: a case-insensitive, non-Unicode JS regex
 * split, whose case folding and alternation order the Swift port reproduces) and `nameTotals`
 * (src/ui/home/homeList.ts: JS trim, toLowerCase and string keys).
 *
 * Not part of the RN test suite. It runs in the `ui` Jest project (AppText imports React
 * Native). To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryAppModelsTests/Fixtures/shell/generator/shell-vectors.test.tsx \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects ui
 *   rm -r src/__vectors__ node_modules
 *
 * The JSON lands in Tests/InventoryAppModelsTests/Fixtures/shell/home-vectors.json.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { splitHighlight } from '@/ui/components/AppText';
import { nameTotals } from '@/ui/home/homeList';

const OUT = join(__dirname, '../../../native-ios/Packages/InventoryKit/Tests/InventoryAppModelsTests/Fixtures/shell');

const highlightCases: { text: string; terms: string[] }[] = [
  { text: 'Spare batteries AA', terms: ['batt', 'aa'] },
  { text: 'USB-C (2m)', terms: ['c', '(2m)'] },
  { text: 'Drill', terms: [] },
  { text: '', terms: ['ab'] },
  { text: 'AA batteries', terms: ['aa batt'] },
  { text: 'Mixed CASE case Case', terms: ['case'] },
  { text: 'aaa', terms: ['aa', 'aaa'] },
  { text: 'abc', terms: ['abc', 'ab'] },
  { text: 'abc', terms: ['ab', 'abc'] },
  { text: 'tape tape', terms: ['ta', 'ta'] },
  { text: 'a+b (c) [d] {e} ^f$ g|h \\i .j *k ?l', terms: ['a+b', '(c)', '[d]', '{e}', '^f$', 'g|h', '\\i', '.j', '*k', '?l'] },
  { text: 'ÉCOLE école Ecole', terms: ['éc'] },
  { text: 'Straße STRASSE strasse', terms: ['ß', 'straße', 'ss'] },
  { text: 'ſtop STOP stop', terms: ['st'] },
  { text: 'Kelvin KELVIN Kelvin', terms: ['Kel', 'ke'] },
  { text: 'İstanbul istanbul ISTANBUL', terms: ['is', 'İs'] },
  { text: 'ΣΊΣΥΦΟΣ σίσυφος', terms: ['σί', 'ος'] },
  { text: '🧰 tool box 🧰', terms: ['🧰', 'box'] },
  { text: 'x é y', terms: ['é'] },
  { text: 'Café Café', terms: ['café'] },
  { text: 'ǅungla ǆ Ǆ', terms: ['ǆu', 'ǅu'] },
  { text: 'ﬁle FILE file', terms: ['fi'] },
  { text: 'µm MM μm', terms: ['µm', 'μm'] },
  { text: 'Ⅻ ⅻ', terms: ['ⅻ ', 'Ⅻ'] },
  { text: 'BOX-7K2M box-7k2m', terms: ['box-7k2m'] },
];

const totalsCases: { name: string; quantity: number; containerId: string }[][] = [
  [
    { name: 'AA batteries', quantity: 12, containerId: 'c1' },
    { name: ' aa Batteries ', quantity: 2, containerId: 'c2' },
  ],
  [
    { name: '﻿Café ', quantity: 1, containerId: 'c1' },
    { name: 'CAFÉ', quantity: 4, containerId: 'c2' },
  ],
  [
    { name: 'Café', quantity: 1, containerId: 'c1' },
    { name: 'Café', quantity: 1, containerId: 'c2' },
  ],
  [
    { name: 'ΟΔΟΣ', quantity: 1, containerId: 'c1' },
    { name: 'οδος', quantity: 2, containerId: 'c2' },
    { name: 'οδοσ', quantity: 3, containerId: 'c3' },
  ],
  [
    { name: 'İpek', quantity: 1, containerId: 'c1' },
    { name: 'i̇pek', quantity: 1, containerId: 'c2' },
    { name: 'ipek', quantity: 1, containerId: 'c3' },
  ],
  [
    { name: 'Glue', quantity: 1, containerId: 'c1' },
    { name: 'Tape', quantity: 1, containerId: 'c1' },
    { name: 'glue', quantity: 1, containerId: 'c1' },
    { name: 'TAPE', quantity: 1, containerId: 'c2' },
    { name: 'GLUE', quantity: 1, containerId: 'c2' },
  ],
];

test('writes home-vectors.json', () => {
  const highlight = highlightCases.map(({ text, terms }) => ({ text, terms, parts: splitHighlight(text, terms) }));
  const totals = totalsCases.map((items) => ({ items, totals: nameTotals(items) }));
  writeFileSync(join(OUT, 'home-vectors.json'), `${JSON.stringify({ highlight, totals }, null, 1)}\n`);
});
