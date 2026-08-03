import { createHash, randomFillSync } from 'node:crypto';

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

export enum CryptoDigestAlgorithm {
  SHA256 = 'SHA-256',
}

/**
 * Real SHA-256, not a stub value.
 *
 * The account id is this digest, and it has to match what the service computes
 * from the same recovery code. A fake digest here would let a derivation bug
 * pass every test and only fail against the deployed service.
 */
export function digest(algorithm: CryptoDigestAlgorithm, data: BufferSource): Promise<ArrayBuffer> {
  const bytes = ArrayBuffer.isView(data)
    ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
    : new Uint8Array(data);

  const hash = createHash(algorithm.replace('-', '').toLowerCase()).update(bytes).digest();
  return Promise.resolve(
    hash.buffer.slice(hash.byteOffset, hash.byteOffset + hash.byteLength) as ArrayBuffer,
  );
}
