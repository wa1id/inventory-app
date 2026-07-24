import { randomFillSync } from 'node:crypto';

/**
 * Stands in for `expo-crypto` under Jest, backed by Node's CSPRNG.
 *
 * Mapped in via `moduleNameMapper` so repository and ID tests exercise the real
 * code path with real randomness instead of a stubbed constant.
 */
export function getRandomBytes(count: number): Uint8Array {
  return randomFillSync(new Uint8Array(count));
}

export function getRandomBytesAsync(count: number): Promise<Uint8Array> {
  return Promise.resolve(getRandomBytes(count));
}
