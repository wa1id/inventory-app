import type { AdapterOutcome, RawSuggestion } from './port.js';

/**
 * Wire contract v1 — must stay byte-compatible with the mobile client's
 * `src/services/ai/contract.ts`. The client validates everything it receives
 * and downgrades anything unexpected to manual entry, so a mismatch here
 * degrades gracefully rather than corrupting an item — but it still means no
 * suggestions, so treat this file and the client's as one unit.
 */
export const CONTRACT_VERSION = 1;

/** Largest base64 payload accepted (~8 MB of image). */
export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

export interface RecognizeRequestBody {
  contractVersion: number;
  image: { data: string; encoding: 'base64'; mediaType?: string };
  /** Optional adapter override, for A/B runs. Validated against the registry. */
  adapter?: string;
}

export type ParsedRequest =
  | { ok: true; bytes: Uint8Array; mediaType: string; adapter?: string }
  | { ok: false; status: number; error: string };

/**
 * Validates an untrusted request body.
 *
 * Everything is checked before a single provider token is spent: an oversized
 * or malformed upload should cost nothing.
 */
export function parseRequest(body: unknown): ParsedRequest {
  if (typeof body !== 'object' || body === null) {
    return { ok: false, status: 400, error: 'Request body must be a JSON object.' };
  }

  const payload = body as Partial<RecognizeRequestBody>;

  if (payload.contractVersion !== CONTRACT_VERSION) {
    return {
      ok: false,
      status: 400,
      error: `Unsupported contractVersion. This service speaks v${CONTRACT_VERSION}.`,
    };
  }

  const image = payload.image;
  if (typeof image !== 'object' || image === null || typeof image.data !== 'string') {
    return { ok: false, status: 400, error: 'image.data (base64) is required.' };
  }
  if (image.encoding !== 'base64') {
    return { ok: false, status: 400, error: "image.encoding must be 'base64'." };
  }

  // Base64 expands ~4/3; check before decoding so a huge string is rejected
  // without allocating the decoded buffer.
  if (image.data.length > MAX_IMAGE_BYTES * 1.4) {
    return { ok: false, status: 413, error: 'Image is too large.' };
  }

  let bytes: Uint8Array;
  try {
    bytes = new Uint8Array(Buffer.from(image.data, 'base64'));
  } catch {
    return { ok: false, status: 400, error: 'image.data is not valid base64.' };
  }

  if (bytes.byteLength === 0) {
    return { ok: false, status: 400, error: 'image.data decoded to zero bytes.' };
  }
  if (bytes.byteLength > MAX_IMAGE_BYTES) {
    return { ok: false, status: 413, error: 'Image is too large.' };
  }

  const mediaType =
    typeof image.mediaType === 'string' && /^image\/[a-z0-9.+-]+$/i.test(image.mediaType)
      ? image.mediaType.toLowerCase()
      : // The app's capture pipeline always writes JPEG.
        'image/jpeg';

  return {
    ok: true,
    bytes,
    mediaType,
    adapter: typeof payload.adapter === 'string' ? payload.adapter : undefined,
  };
}

/** Success body carrying a suggestion. */
export function suggestionResponse(suggestion: RawSuggestion) {
  return {
    contractVersion: CONTRACT_VERSION,
    suggestion: {
      name: suggestion.name,
      category: suggestion.category,
      tags: suggestion.tags,
      estimatedValue: suggestion.estimatedValue,
      currency: suggestion.currency,
      confidence: suggestion.confidence,
    },
  };
}

/** Success body meaning "looked, could not tell" — a 200, not an error. */
export function unrecognizedResponse() {
  return { contractVersion: CONTRACT_VERSION, status: 'unrecognized' as const };
}

/**
 * Maps an adapter failure to an HTTP status the client already understands:
 * 429 → `rate_limited`, anything else 5xx → `server_error`, and a client-side
 * abort → `timeout`.
 */
export function statusForAdapterError(
  outcome: Extract<AdapterOutcome, { status: 'error' }>,
): number {
  switch (outcome.kind) {
    case 'rate_limited':
      return 429;
    case 'timeout':
      return 504;
    default:
      return 502;
  }
}
