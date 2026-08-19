/**
 * Crockford base32, same alphabet as the app recovery code.
 *
 * The bootstrap secret is typed by a human. This encoding drops I/L/O/U so
 * 1/I and 0/O cannot produce a different valid secret.
 */
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const DECODE_MAP: Record<string, number> = (() => {
  const map: Record<string, number> = {};
  for (let index = 0; index < ALPHABET.length; index += 1) {
    map[ALPHABET[index] as string] = index;
  }
  map.I = 1;
  map.L = 1;
  map.O = 0;
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
  if (bits > 0) {
    out += ALPHABET[(buffer << (5 - bits)) & 0x1f];
  }
  return out;
}

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

export function formatSecret(code: string): string {
  return (code.match(/.{1,5}/g) ?? []).join('-');
}
