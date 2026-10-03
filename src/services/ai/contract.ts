/**
 * Versioned contract between the app and the recognition backend.
 *
 * The client never talks to an AI provider directly — it posts an image to our
 * own endpoint, which holds the provider credential. Bumping
 * `RECOGNITION_CONTRACT_VERSION` lets an older app reject a response shape it
 * does not understand instead of misreading it (issue #7).
 */
export const RECOGNITION_CONTRACT_VERSION = 1;

export interface RecognitionSuggestion {
  name: string | null;
  category: string | null;
  tags: string[];
  /** 0–1. Below `MIN_CONFIDENCE` the result is treated as unusable. */
  confidence: number;
}

/** Suggestions weaker than this are discarded rather than shown as guesses. */
export const MIN_CONFIDENCE = 0.35;

export type RecognitionFailureReason =
  | 'not_configured'
  | 'offline'
  | 'timeout'
  | 'rate_limited'
  | 'server_error'
  | 'malformed_response'
  | 'unsupported_version'
  | 'low_confidence'
  | 'unrecognized';

export type RecognitionResult =
  | { status: 'success'; suggestion: RecognitionSuggestion; contractVersion: number }
  | { status: 'failed'; reason: RecognitionFailureReason };

const MAX_TAGS = 8;
const MAX_TEXT_LENGTH = 80;

function cleanText(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim().slice(0, MAX_TEXT_LENGTH);
  return trimmed.length > 0 ? trimmed : null;
}

function cleanNumber(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return null;
  return value;
}

/**
 * Validates and normalizes an untrusted response body.
 *
 * Anything unexpected downgrades to a failure the UI can recover from — a bad
 * response must never be able to inject junk into the item editor.
 */
export function parseRecognitionResponse(body: unknown): RecognitionResult {
  if (typeof body !== 'object' || body === null) {
    return { status: 'failed', reason: 'malformed_response' };
  }

  const payload = body as Record<string, unknown>;
  const version = payload.contractVersion;

  if (typeof version !== 'number') {
    return { status: 'failed', reason: 'malformed_response' };
  }
  if (version !== RECOGNITION_CONTRACT_VERSION) {
    return { status: 'failed', reason: 'unsupported_version' };
  }

  // The backend reports an image it could not interpret as an explicit outcome
  // rather than an error status, so the app can offer manual entry directly.
  if (payload.status === 'unrecognized') {
    return { status: 'failed', reason: 'unrecognized' };
  }

  const suggestionValue = payload.suggestion;
  if (typeof suggestionValue !== 'object' || suggestionValue === null) {
    return { status: 'failed', reason: 'malformed_response' };
  }

  const raw = suggestionValue as Record<string, unknown>;
  const confidence = cleanNumber(raw.confidence);

  if (confidence === null || confidence > 1) {
    return { status: 'failed', reason: 'malformed_response' };
  }

  const name = cleanText(raw.name);
  if (!name) {
    return { status: 'failed', reason: 'unrecognized' };
  }

  if (confidence < MIN_CONFIDENCE) {
    return { status: 'failed', reason: 'low_confidence' };
  }

  const tags = Array.isArray(raw.tags)
    ? raw.tags
        .map(cleanText)
        .filter((tag): tag is string => tag !== null)
        .slice(0, MAX_TAGS)
    : [];

  return {
    status: 'success',
    contractVersion: version,
    suggestion: {
      name,
      category: cleanText(raw.category),
      tags,
      confidence,
    },
  };
}
