/**
 * Crockford base32 — the encoding behind the recovery code.
 *
 * This exists because a recovery code is transcribed by a human, off a screen
 * onto paper and back again, possibly months later. Crockford's alphabet drops
 * I, L, O and U, so the two mistakes that actually happen — reading 1 as I and
 * 0 as O — cannot produce a different valid code. Decoding folds those pairs
 * back together and ignores case and hyphens, so a code copied by hand in the
 * wrong case with the groups run together still opens the account.
 *
 * Must stay byte-compatible with the service's `worker/src/base32.ts`. The two
 * files are one unit: a change here that is not mirrored there strands every
 * existing backup behind a code that no longer decodes.
 */
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/** Reverse lookup, including the ambiguous characters folded to their twins. */
const DECODE_MAP: Record<string, number> = (() => {
  const map: Record<string, number> = {};
  for (let index = 0; index < ALPHABET.length; index += 1) {
    map[ALPHABET[index] as string] = index;
  }
  map['I'] = 1;
  map['L'] = 1;
  map['O'] = 0;
  return map;
})();

export function encodeBase32(bytes: Uint8Array): string {
  let out = '';
  let buffer = 0;
  let bits = 0;

  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += ALPHABET[(buffer >> bits) & 0x1f];
    }
  }

  // Left-align the remainder so the final character encodes the leftover bits.
  if (bits > 0) {
    out += ALPHABET[(buffer << (5 - bits)) & 0x1f];
  }

  return out;
}

/**
 * Decodes a recovery code, returning null for anything malformed.
 *
 * Null rather than a throw because the caller is a text field someone is still
 * typing into: a half-entered code is the normal state, not an error worth
 * unwinding the stack for.
 */
export function decodeBase32(value: string): Uint8Array | null {
  const normalized = value.replace(/-/g, '').trim().toUpperCase();
  if (normalized.length === 0) return null;

  const out: number[] = [];
  let buffer = 0;
  let bits = 0;

  for (const character of normalized) {
    const digit = DECODE_MAP[character];
    if (digit === undefined) return null;

    buffer = (buffer << 5) | digit;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }

  return new Uint8Array(out);
}

/** Groups a code into fives so it can be read off a screen without losing place. */
export function formatRecoveryCode(code: string): string {
  return (code.match(/.{1,5}/g) ?? []).join('-');
}
