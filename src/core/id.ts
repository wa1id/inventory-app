import * as Crypto from 'expo-crypto';

import { toHex } from './bytes';

/**
 * All identifiers and tokens come from the platform CSPRNG.
 *
 * There is deliberately no `Math.random` fallback: QR tokens are the only thing
 * standing between a printed label and someone else's inventory, so failing
 * loudly is better than silently degrading to predictable output.
 */
function randomBytes(count: number): Uint8Array {
  return Crypto.getRandomBytes(count);
}

/**
 * Stable entity identifier (RFC 4122 v4 layout).
 *
 * IDs are generated once at creation and never rewritten, so an edit or an app
 * restart can never change what an item, container, or space is.
 */
export function newId(): string {
  const bytes = randomBytes(16);
  // Version 4, variant 10xx.
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = toHex(bytes);
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join('-');
}

/**
 * Opaque QR token: 32 hex characters (128 bits) of CSPRNG output.
 *
 * Deliberately unrelated to any database ID so a printed label leaks nothing
 * about the inventory and cannot be enumerated by incrementing a number.
 */
export function newQrToken(): string {
  return toHex(randomBytes(16));
}
