import { decodeBase32, encodeBase32, formatRecoveryCode } from '@/services/account/base32';
import {
  createAccount,
  deriveAccountId,
  forgetAccount,
  importAccount,
  loadAccount,
} from '@/services/account/identity';
import { SECRET_BYTES } from '@/services/sync/contract';

const mockStore = new Map<string, string>();
let mockFailNextWrite = false;
let mockFailNextRead = false;

jest.mock('expo-secure-store', () => ({
  isAvailableAsync: async () => true,
  getItemAsync: async (key: string) => {
    if (mockFailNextRead) {
      mockFailNextRead = false;
      throw new Error('keystore locked');
    }
    return mockStore.get(key) ?? null;
  },
  setItemAsync: async (key: string, value: string) => {
    if (mockFailNextWrite) {
      mockFailNextWrite = false;
      throw new Error('keystore unavailable');
    }
    mockStore.set(key, value);
  },
  deleteItemAsync: async (key: string) => {
    mockStore.delete(key);
  },
}));

beforeEach(() => {
  mockStore.clear();
  mockFailNextWrite = false;
  mockFailNextRead = false;
});

/*
 * These vectors are the contract with `worker/src/`. Both sides encode the same
 * recovery code and derive the same account id from it, and neither can be
 * changed alone without stranding every backup already written under it.
 */
describe('cross-implementation vectors', () => {
  const secret = new Uint8Array(SECRET_BYTES).fill(0x42);

  it('encodes a known secret to the code the service expects', () => {
    expect(encodeBase32(secret)).toBe('89144GJ289144GJ289144GJ288');
  });

  it('derives the account id the service derives', async () => {
    await expect(deriveAccountId(secret)).resolves.toBe('900dfeb7f1b5e344209e2abce56c333d');
  });
});

describe('recovery code encoding', () => {
  it('round-trips random secrets', () => {
    for (let attempt = 0; attempt < 50; attempt += 1) {
      const bytes = new Uint8Array(SECRET_BYTES);
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = Math.floor(Math.random() * 256);
      }
      expect(decodeBase32(encodeBase32(bytes))?.subarray(0, SECRET_BYTES)).toEqual(bytes);
    }
  });

  it('survives the transcription mistakes it was chosen to survive', () => {
    const bytes = new Uint8Array(SECRET_BYTES).fill(0x11);
    const code = encodeBase32(bytes);

    // Lowercase, hyphenated, and with 1 and 0 written as the letters people
    // reach for instead.
    const retyped = formatRecoveryCode(code).toLowerCase().replace(/1/g, 'l').replace(/0/g, 'o');

    expect(decodeBase32(retyped)?.subarray(0, SECRET_BYTES)).toEqual(bytes);
  });
});

describe('account lifecycle', () => {
  it('reports no account on a device that has never had one', async () => {
    await expect(loadAccount()).resolves.toBeNull();
  });

  it('creates an account and finds it again', async () => {
    const created = await createAccount();
    expect(created.recoveryCode).toHaveLength(26);

    const loaded = await loadAccount();
    expect(loaded).toEqual(created);
  });

  it('gives different devices different accounts', async () => {
    const first = await createAccount();
    mockStore.clear();
    const second = await createAccount();

    expect(second.id).not.toBe(first.id);
  });

  it('adopts an account from a code typed in any reasonable shape', async () => {
    const original = await createAccount();
    mockStore.clear();

    const result = await importAccount(formatRecoveryCode(original.recoveryCode).toLowerCase());

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    // Same code means the same account, which is the entire restore path.
    expect(result.account.id).toBe(original.id);
    // What gets persisted is canonical, never whatever was typed.
    expect(result.account.recoveryCode).toBe(original.recoveryCode);
  });

  it('refuses a code that decodes to too few bytes', async () => {
    const result = await importAccount('89144');

    expect(result).toEqual({ ok: false, reason: 'malformed' });
    expect(mockStore.size).toBe(0);
  });

  it('refuses a code containing characters outside the alphabet', async () => {
    await expect(importAccount('UUUUUUUUUUUUUUUUUUUUUUUUUU')).resolves.toEqual({
      ok: false,
      reason: 'malformed',
    });
  });

  it('reports an unwritable keystore rather than claiming success', async () => {
    const code = encodeBase32(new Uint8Array(SECRET_BYTES).fill(9));
    mockFailNextWrite = true;

    await expect(importAccount(code)).resolves.toEqual({ ok: false, reason: 'unavailable' });
  });

  it('treats a keystore read failure as no account, not a new one', async () => {
    await createAccount();
    mockFailNextRead = true;

    // Minting a second account here would orphan the backups under the first.
    await expect(loadAccount()).resolves.toBeNull();
  });

  it('forgets an account without touching anything else', async () => {
    await createAccount();
    await forgetAccount();

    await expect(loadAccount()).resolves.toBeNull();
  });
});
