import { decodeBase32 } from './base32.ts';
import { SECRET_BYTES } from './contract.ts';

/**
 * Two gates, doing two different jobs.
 *
 * `x-inventory-key` is the same shared app secret the recognition service uses,
 * and it deserves the same honesty: it ships inside the app bundle, so anyone
 * who unpacks the APK has it. It keeps drive-by scanners from discovering an
 * open storage endpoint. It is not what protects an account.
 *
 * `Authorization: Bearer <recovery code>` is the real credential. The account
 * id is derived from it by hashing, which is the whole reason this service
 * needs no user table: possession of the code *is* the account, and the server
 * stores nothing that could be leaked to impersonate one. The cost of that
 * design is stated plainly in the UI — lose the code, lose the backup.
 */
export const APP_KEY_HEADER = 'x-inventory-key';

export interface Account {
  /** 128-bit hex, derived from the code. Never the code itself. */
  id: string;
}

export type AuthResult =
  { ok: true; account: Account } | { ok: false; status: number; error: string };

export async function authenticate(request: Request, env: Env): Promise<AuthResult> {
  const appKey = env.SYNC_SHARED_SECRET?.trim();
  if (appKey) {
    const provided = request.headers.get(APP_KEY_HEADER);
    if (!provided || !constantTimeEquals(provided, appKey)) {
      return { ok: false, status: 401, error: 'Invalid credentials.' };
    }
  }

  const header = request.headers.get('authorization');
  if (!header) {
    return { ok: false, status: 401, error: 'Missing credentials.' };
  }

  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!match) {
    return { ok: false, status: 401, error: 'Malformed authorization header.' };
  }

  const secret = decodeBase32(match[1] as string);
  // A short code is not merely wrong, it is weak: accepting one would let
  // someone brute-force a small keyspace into somebody else's account.
  if (!secret || secret.length !== SECRET_BYTES) {
    return { ok: false, status: 401, error: 'Invalid recovery code.' };
  }

  return { ok: true, account: { id: await deriveAccountId(secret) } };
}

/**
 * Account id = first 128 bits of SHA-256 over the secret.
 *
 * A plain hash rather than a slow KDF is correct here *because* the input is
 * 128 CSPRNG bits: there is no dictionary to iterate and nothing to stretch.
 * That reasoning breaks the moment a human-chosen passphrase is allowed in, so
 * the code is generated for the user and never entered from imagination.
 */
export async function deriveAccountId(secret: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    secret.buffer.slice(secret.byteOffset, secret.byteOffset + secret.byteLength) as ArrayBuffer,
  );
  const bytes = new Uint8Array(digest).subarray(0, 16);
  let hex = '';
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, '0');
  }
  return hex;
}

/**
 * Length-independent comparison.
 *
 * Comparing lengths first would leak the secret's length through timing, so
 * both sides are folded into a fixed-width accumulator instead.
 */
export function constantTimeEquals(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);

  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }

  return difference === 0;
}
