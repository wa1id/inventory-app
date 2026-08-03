/**
 * Small byte helpers shared by the id, identity, and backup code.
 *
 * They live here rather than being rewritten per call site because two of the
 * three uses feed a hash whose output is an account id or a checksum — places
 * where a subtly different hex encoding is a bug that only shows up as "the
 * server does not recognize this device".
 */

/** Lowercase hex, zero-padded per byte. */
export function toHex(bytes: Uint8Array): string {
  let out = '';
  for (const byte of bytes) {
    out += byte.toString(16).padStart(2, '0');
  }
  return out;
}

/**
 * Widens a `Uint8Array` to the `BufferSource` the crypto APIs ask for.
 *
 * TypeScript models `Uint8Array` as generic over its backing buffer, so an
 * array that might be backed by a `SharedArrayBuffer` is not assignable to
 * `BufferSource` — which every `Uint8Array` from Expo's APIs nominally is. The
 * alternative is copying into a fresh array on every call, and a snapshot is
 * measured in megabytes. The cast is safe: nothing in this app ever allocates
 * a `SharedArrayBuffer`.
 */
export function asBufferSource(bytes: Uint8Array): BufferSource {
  return bytes as unknown as BufferSource;
}
