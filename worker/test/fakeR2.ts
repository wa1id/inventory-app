import { createHash } from 'node:crypto';

/**
 * In-memory stand-in for an R2 bucket.
 *
 * Only the surface `src/storage.ts` and `src/index.ts` actually touch, but
 * faithful about the parts the routes depend on for correctness: listing is
 * prefix-scoped and paginated, `put` verifies a declared sha256 the way R2
 * does, and `delete` accepts a batch. Those are exactly the behaviours the
 * account-isolation and retention tests are asserting against, so a fake that
 * glossed over them would prove nothing.
 */
interface StoredObject {
  bytes: Uint8Array;
  customMetadata?: Record<string, string>;
  contentType?: string;
}

export class FakeR2Bucket {
  readonly objects = new Map<string, StoredObject>();

  async put(
    key: string,
    value: Uint8Array | string,
    options?: {
      httpMetadata?: { contentType?: string };
      customMetadata?: Record<string, string>;
      sha256?: string;
    },
  ): Promise<void> {
    const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value;

    if (options?.sha256) {
      const actual = createHash('sha256').update(bytes).digest('hex');
      if (actual !== options.sha256) {
        throw new Error('put: The SHA-256 checksum you specified did not match what we received.');
      }
    }

    this.objects.set(key, {
      bytes: new Uint8Array(bytes),
      customMetadata: options?.customMetadata,
      contentType: options?.httpMetadata?.contentType,
    });
  }

  async get(key: string) {
    const stored = this.objects.get(key);
    if (!stored) return null;

    return {
      size: stored.bytes.byteLength,
      httpEtag: `"${createHash('md5').update(stored.bytes).digest('hex')}"`,
      customMetadata: stored.customMetadata,
      httpMetadata: stored.contentType ? { contentType: stored.contentType } : undefined,
      // Built directly rather than via Blob: the Workers runtime types model
      // Uint8Array as generic over its backing buffer, which does not satisfy
      // BlobPart without a cast that hides real mismatches.
      body: new ReadableStream({
        start(controller) {
          controller.enqueue(stored.bytes);
          controller.close();
        },
      }),
      arrayBuffer: async () => stored.bytes.slice().buffer,
      json: async () => JSON.parse(new TextDecoder().decode(stored.bytes)),
      text: async () => new TextDecoder().decode(stored.bytes),
    };
  }

  async head(key: string) {
    const stored = this.objects.get(key);
    return stored ? { size: stored.bytes.byteLength } : null;
  }

  async delete(keys: string | string[]): Promise<void> {
    for (const key of Array.isArray(keys) ? keys : [keys]) {
      this.objects.delete(key);
    }
  }

  async list(options?: { prefix?: string; cursor?: string; limit?: number }) {
    const prefix = options?.prefix ?? '';
    const limit = options?.limit ?? 1000;

    const matching = [...this.objects.entries()]
      .filter(([key]) => key.startsWith(prefix))
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));

    const start = options?.cursor ? Number(options.cursor) : 0;
    const page = matching.slice(start, start + limit);
    const end = start + page.length;

    return {
      objects: page.map(([key, stored]) => ({
        key,
        size: stored.bytes.byteLength,
        customMetadata: stored.customMetadata,
      })),
      truncated: end < matching.length,
      cursor: end < matching.length ? String(end) : undefined,
    };
  }
}

export function makeEnv(overrides: Record<string, unknown> = {}) {
  return { BUCKET: new FakeR2Bucket(), ...overrides } as unknown as Env & { BUCKET: FakeR2Bucket };
}
