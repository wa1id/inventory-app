import { randomFillSync } from 'node:crypto';

import { configureRandomBytes, newId, newQrToken } from '@/core/id';

afterEach(() => {
  configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));
});

describe('newId', () => {
  it('throws until an RNG is configured', () => {
    configureRandomBytes(null);
    expect(() => newId()).toThrow(/not configured/);
  });

  it('formats RFC 4122 version-4 UUIDs from the injected bytes', () => {
    const bytes = Uint8Array.from({ length: 16 }, (_, i) => i);
    configureRandomBytes(() => bytes.slice());

    const id = newId();

    expect(id).toBe('00010203-0405-4607-8809-0a0b0c0d0e0f');
  });
});

describe('newQrToken', () => {
  it('hex-encodes the injected 16 bytes', () => {
    configureRandomBytes(() => new Uint8Array(16).fill(0xab));
    expect(newQrToken()).toBe('abababababababababababababababab');
  });
});
