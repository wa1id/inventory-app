import assert from 'node:assert/strict';
import { test } from 'node:test';

import { decodeBase32, encodeBase32, formatRecoveryCode } from '../src/base32.ts';
import { RECOVERY_CODE_LENGTH, SECRET_BYTES } from '../src/contract.ts';

test('round-trips every byte value', () => {
  for (let seed = 0; seed < 256; seed += 1) {
    const bytes = new Uint8Array(SECRET_BYTES).fill(seed);
    const decoded = decodeBase32(encodeBase32(bytes));
    assert.deepEqual(decoded?.subarray(0, SECRET_BYTES), bytes);
  }
});

test('a 16-byte secret encodes to a code of the documented length', () => {
  const code = encodeBase32(new Uint8Array(SECRET_BYTES).fill(0xff));
  assert.equal(code.length, RECOVERY_CODE_LENGTH);
});

test('folds the characters people actually mistype', () => {
  // I and L read as 1, O reads as 0 — the whole reason for this alphabet.
  const canonical = decodeBase32('10101010101010101010101010');
  assert.deepEqual(decodeBase32('IOIOIOIOIOIOIOIOIOIOIOIOIO'), canonical);
  assert.deepEqual(decodeBase32('LOLOLOLOLOLOLOLOLOLOLOLOLO'), canonical);
});

test('ignores case, hyphens, and surrounding whitespace', () => {
  const bytes = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
  const code = encodeBase32(bytes);

  const messy = `  ${formatRecoveryCode(code).toLowerCase()}  `;
  assert.deepEqual(decodeBase32(messy)?.subarray(0, SECRET_BYTES), bytes);
});

test('rejects characters outside the alphabet', () => {
  assert.equal(decodeBase32('UUUUUUUUUUUUUUUUUUUUUUUUUU'), null);
  assert.equal(decodeBase32('hello world'), null);
  assert.equal(decodeBase32(''), null);
});

test('formats into readable groups without changing the value', () => {
  const code = encodeBase32(new Uint8Array(SECRET_BYTES).fill(0x42));

  assert.equal(code, '89144GJ289144GJ289144GJ288');
  assert.equal(formatRecoveryCode(code), '89144-GJ289-144GJ-28914-4GJ28-8');
  assert.deepEqual(decodeBase32(formatRecoveryCode(code)), decodeBase32(code));
});
