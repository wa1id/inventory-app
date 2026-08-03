import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';

import { asBufferSource, toHex } from '@/core/bytes';
import { SECRET_BYTES } from '@/services/sync/contract';

import { decodeBase32, encodeBase32 } from './base32';

/**
 * The device's claim on its own backups.
 *
 * There is no account system here — no email, no password, no server-side user
 * record. The app generates 16 CSPRNG bytes, keeps them in the platform
 * keystore, and shows them to the user as a recovery code. The service hashes
 * that code into an account id and uses the hash as a storage prefix, so
 * holding the code *is* being the account.
 *
 * Why a code the user has to save, rather than something invisible:
 *
 * - **Android wipes the keystore on uninstall.** SecureStore is explicit about
 *   this — values are not preserved. Without a code, the exact event this
 *   feature exists to survive would destroy the only way back to the backup.
 * - **iOS keeps Keychain entries across uninstall**, so reinstalling there
 *   usually restores silently. Designing only for that would ship a feature
 *   that works on one platform and quietly fails on the other.
 *
 * The cost is real and the UI states it plainly: nothing on the server can
 * recover a lost code, because nothing on the server could reconstruct one.
 */
const SECRET_KEY = 'sync.accountSecret.v1';

export interface Account {
  /** Hex account id. Derived, never stored — the secret is the only state. */
  id: string;
  /** The 26-character code, unformatted. */
  recoveryCode: string;
}

export type ImportResult =
  { ok: true; account: Account } | { ok: false; reason: 'malformed' | 'unavailable' };

/** Whether this device can hold a secret at all. */
export async function isSecureStoreAvailable(): Promise<boolean> {
  try {
    return await SecureStore.isAvailableAsync();
  } catch {
    return false;
  }
}

/** Returns the existing account, or null when this device has never had one. */
export async function loadAccount(): Promise<Account | null> {
  let stored: string | null;
  try {
    stored = await SecureStore.getItemAsync(SECRET_KEY);
  } catch {
    // A keystore that errors is indistinguishable from one that is empty, and
    // treating it as empty would mint a second account and orphan the backups
    // under the first. Report "no account" and let the caller stay local-only.
    return null;
  }

  if (!stored) return null;

  const secret = decodeBase32(stored);
  if (!secret || secret.length !== SECRET_BYTES) return null;

  return { id: await deriveAccountId(secret), recoveryCode: stored };
}

/**
 * Creates and persists a new account secret.
 *
 * `getRandomBytesAsync` rather than the synchronous `getRandomBytes`: the docs
 * note the sync variant can fall back to `Math.random` during development, and
 * a predictable recovery code is a readable inventory.
 */
export async function createAccount(): Promise<Account> {
  const secret = await Crypto.getRandomBytesAsync(SECRET_BYTES);
  const recoveryCode = encodeBase32(secret);

  await SecureStore.setItemAsync(SECRET_KEY, recoveryCode);

  return { id: await deriveAccountId(secret), recoveryCode };
}

/**
 * Adopts an existing account from a typed recovery code.
 *
 * This is the restore path, so it is deliberately forgiving about formatting —
 * case, hyphens and the I/L/1 and O/0 confusions are all normalized by the
 * decoder — and deliberately strict about length. A code that decodes to fewer
 * than 16 bytes is not a typo to be salvaged; it is a smaller keyspace.
 */
export async function importAccount(code: string): Promise<ImportResult> {
  const secret = decodeBase32(code);
  if (!secret || secret.length !== SECRET_BYTES) {
    return { ok: false, reason: 'malformed' };
  }

  // Store the canonical form, so what is persisted never depends on how it was
  // typed and the account id stays stable across re-entry.
  const canonical = encodeBase32(secret.subarray(0, SECRET_BYTES));

  try {
    await SecureStore.setItemAsync(SECRET_KEY, canonical);
  } catch {
    return { ok: false, reason: 'unavailable' };
  }

  return { ok: true, account: { id: await deriveAccountId(secret), recoveryCode: canonical } };
}

/** Detaches this device from its account. Does not touch anything stored remotely. */
export async function forgetAccount(): Promise<void> {
  try {
    await SecureStore.deleteItemAsync(SECRET_KEY);
  } catch {
    // Nothing useful to do: the caller is already tearing down local state.
  }
}

/**
 * Account id = first 128 bits of SHA-256 over the secret.
 *
 * Must match `deriveAccountId` in `worker/src/auth.ts` exactly — it is what
 * decides which prefix in the bucket this device can reach. A plain hash is
 * right here precisely because the input is 128 CSPRNG bits: there is no
 * dictionary to iterate, so there is nothing for a slow KDF to buy.
 */
export async function deriveAccountId(secret: Uint8Array): Promise<string> {
  const digest = await Crypto.digest(Crypto.CryptoDigestAlgorithm.SHA256, asBufferSource(secret));
  return toHex(new Uint8Array(digest).subarray(0, 16));
}
