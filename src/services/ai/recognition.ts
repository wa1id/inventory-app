import { appConfig } from '@/services/config';
import { logError, logEvent } from '@/services/telemetry';

import {
  RECOGNITION_CONTRACT_VERSION,
  parseRecognitionResponse,
  type RecognitionFailureReason,
  type RecognitionResult,
} from './contract';

export interface RecognizeOptions {
  /** Local file URI of the captured photo. */
  imageUri: string;
  /**
   * Recognition backend URL. Defaults to the configured endpoint; passing it
   * explicitly is what lets tests cover both configured and unconfigured
   * builds without reloading modules.
   */
  endpoint?: string | null;
  /** Overridable for tests; defaults to the global fetch. */
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  /** Reads the image as base64; injected so tests need no filesystem. */
  readImage?: (uri: string) => Promise<string>;
}

async function defaultReadImage(uri: string): Promise<string> {
  // Imported lazily so the Node test environment never loads a native module.
  const FileSystem = await import('expo-file-system');
  const file = new FileSystem.File(uri);
  return file.base64();
}

function classifyError(error: unknown): RecognitionFailureReason {
  if (error instanceof Error) {
    if (error.name === 'AbortError') return 'timeout';
    if (/network|fetch failed|internet|unreachable/i.test(error.message)) return 'offline';
  }
  return 'server_error';
}

function classifyStatus(status: number): RecognitionFailureReason {
  if (status === 429) return 'rate_limited';
  return 'server_error';
}

/**
 * Asks the backend to identify an item from its photo.
 *
 * Never throws: every failure — unconfigured build, offline, timeout, rate
 * limit, malformed body, low confidence — resolves to a `failed` result so the
 * caller always lands in the editable review state (issue #7).
 *
 * Only timings and outcome classes are logged. The image, the suggestion text,
 * and anything the user typed stay on the device (issue #8).
 */
export async function recognizeItem({
  imageUri,
  endpoint = appConfig.recognitionEndpoint,
  fetchImpl,
  timeoutMs = appConfig.recognitionTimeoutMs,
  readImage = defaultReadImage,
}: RecognizeOptions): Promise<RecognitionResult> {
  if (!endpoint) {
    logEvent('recognition_skipped', { outcome: 'not_configured' });
    return { status: 'failed', reason: 'not_configured' };
  }

  const doFetch = fetchImpl ?? globalThis.fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();

  try {
    const base64 = await readImage(imageUri);

    const response = await doFetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Contract-Version': String(RECOGNITION_CONTRACT_VERSION),
        ...(appConfig.recognitionKey ? { 'x-inventory-key': appConfig.recognitionKey } : {}),
      },
      body: JSON.stringify({
        contractVersion: RECOGNITION_CONTRACT_VERSION,
        image: { data: base64, encoding: 'base64', mediaType: 'image/jpeg' },
      }),
      signal: controller.signal,
    });

    if (!response.ok) {
      const reason = classifyStatus(response.status);
      logError('recognition_failed', {
        outcome: reason,
        statusCode: response.status,
        latencyMs: Date.now() - startedAt,
        contractVersion: RECOGNITION_CONTRACT_VERSION,
      });
      return { status: 'failed', reason };
    }

    let body: unknown;
    try {
      body = await response.json();
    } catch {
      logError('recognition_failed', {
        outcome: 'malformed_response',
        latencyMs: Date.now() - startedAt,
        contractVersion: RECOGNITION_CONTRACT_VERSION,
      });
      return { status: 'failed', reason: 'malformed_response' };
    }

    const result = parseRecognitionResponse(body);

    logEvent('recognition_completed', {
      outcome: result.status === 'success' ? 'success' : result.reason,
      latencyMs: Date.now() - startedAt,
      contractVersion: RECOGNITION_CONTRACT_VERSION,
      confidence: result.status === 'success' ? result.suggestion.confidence : null,
    });

    return result;
  } catch (error) {
    const reason = classifyError(error);
    logError('recognition_failed', {
      outcome: reason,
      latencyMs: Date.now() - startedAt,
      contractVersion: RECOGNITION_CONTRACT_VERSION,
    });
    return { status: 'failed', reason };
  } finally {
    clearTimeout(timer);
  }
}
