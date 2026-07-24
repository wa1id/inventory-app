import {
  MIN_CONFIDENCE,
  RECOGNITION_CONTRACT_VERSION,
  parseRecognitionResponse,
} from '@/services/ai/contract';
import { recognizeItem } from '@/services/ai/recognition';
import { redact } from '@/services/telemetry';

const VALID_BODY = {
  contractVersion: RECOGNITION_CONTRACT_VERSION,
  suggestion: {
    name: 'Cordless Drill',
    category: 'Power Tools',
    tags: ['dewalt', '18v'],
    estimatedValue: 129.99,
    currency: 'eur',
    confidence: 0.92,
  },
};

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response;
}

const readImage = async () => 'ZmFrZS1pbWFnZQ==';

describe('parseRecognitionResponse', () => {
  it('accepts and normalizes a well-formed suggestion', () => {
    const result = parseRecognitionResponse(VALID_BODY);

    expect(result.status).toBe('success');
    if (result.status !== 'success') return;
    expect(result.suggestion.name).toBe('Cordless Drill');
    expect(result.suggestion.currency).toBe('EUR');
    expect(result.suggestion.tags).toEqual(['dewalt', '18v']);
  });

  it.each([
    ['null body', null],
    ['a string body', 'nope'],
    ['a missing contract version', { suggestion: VALID_BODY.suggestion }],
    ['a missing suggestion', { contractVersion: RECOGNITION_CONTRACT_VERSION }],
    [
      'a non-numeric confidence',
      {
        contractVersion: RECOGNITION_CONTRACT_VERSION,
        suggestion: { ...VALID_BODY.suggestion, confidence: 'high' },
      },
    ],
    [
      'a confidence above 1',
      {
        contractVersion: RECOGNITION_CONTRACT_VERSION,
        suggestion: { ...VALID_BODY.suggestion, confidence: 4 },
      },
    ],
  ])('rejects %s as malformed', (_label, body) => {
    expect(parseRecognitionResponse(body)).toEqual({
      status: 'failed',
      reason: 'malformed_response',
    });
  });

  it('rejects a contract version it does not understand', () => {
    const result = parseRecognitionResponse({ ...VALID_BODY, contractVersion: 999 });
    expect(result).toEqual({ status: 'failed', reason: 'unsupported_version' });
  });

  it('treats an explicit unrecognized outcome as recoverable', () => {
    const result = parseRecognitionResponse({
      contractVersion: RECOGNITION_CONTRACT_VERSION,
      status: 'unrecognized',
    });
    expect(result).toEqual({ status: 'failed', reason: 'unrecognized' });
  });

  it('rejects a suggestion with no usable name', () => {
    const result = parseRecognitionResponse({
      contractVersion: RECOGNITION_CONTRACT_VERSION,
      suggestion: { ...VALID_BODY.suggestion, name: '   ' },
    });
    expect(result).toEqual({ status: 'failed', reason: 'unrecognized' });
  });

  it('discards suggestions below the confidence floor', () => {
    const result = parseRecognitionResponse({
      contractVersion: RECOGNITION_CONTRACT_VERSION,
      suggestion: { ...VALID_BODY.suggestion, confidence: MIN_CONFIDENCE - 0.01 },
    });
    expect(result).toEqual({ status: 'failed', reason: 'low_confidence' });
  });

  it('drops junk values instead of passing them to the editor', () => {
    const result = parseRecognitionResponse({
      contractVersion: RECOGNITION_CONTRACT_VERSION,
      suggestion: {
        name: 'Drill',
        category: 42,
        tags: ['ok', 17, null, '  ', 'fine'],
        estimatedValue: -5,
        currency: 'euros',
        confidence: 0.8,
      },
    });

    expect(result.status).toBe('success');
    if (result.status !== 'success') return;
    expect(result.suggestion.category).toBeNull();
    expect(result.suggestion.tags).toEqual(['ok', 'fine']);
    expect(result.suggestion.estimatedValue).toBeNull();
    expect(result.suggestion.currency).toBeNull();
  });

  it('caps the number of tags', () => {
    const result = parseRecognitionResponse({
      contractVersion: RECOGNITION_CONTRACT_VERSION,
      suggestion: {
        ...VALID_BODY.suggestion,
        tags: Array.from({ length: 40 }, (_, i) => `tag${i}`),
      },
    });

    expect(result.status === 'success' && result.suggestion.tags).toHaveLength(8);
  });
});

describe('recognizeItem', () => {
  const endpoint = 'https://recognition.example.com/v1/identify';

  function callWith(fetchImpl: typeof fetch) {
    return recognizeItem({
      imageUri: 'file:///photo.jpg',
      endpoint,
      fetchImpl,
      readImage,
      timeoutMs: 50,
    });
  }

  it('returns a suggestion on success', async () => {
    const result = await callWith(async () => jsonResponse(VALID_BODY));
    expect(result.status).toBe('success');
  });

  it('never sends a provider credential from the client', async () => {
    const fetchImpl = jest.fn(async () => jsonResponse(VALID_BODY));
    await callWith(fetchImpl as unknown as typeof fetch);

    const [, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    const headerNames = Object.keys(init.headers as Record<string, string>).map((h) =>
      h.toLowerCase(),
    );
    expect(headerNames).not.toContain('authorization');
    expect(headerNames).not.toContain('x-api-key');
  });

  it('classifies a timeout as recoverable', async () => {
    const result = await callWith(async () => {
      const error = new Error('Aborted');
      error.name = 'AbortError';
      throw error;
    });
    expect(result).toEqual({ status: 'failed', reason: 'timeout' });
  });

  it('classifies a network failure as offline', async () => {
    const result = await callWith(async () => {
      throw new Error('Network request failed');
    });
    expect(result).toEqual({ status: 'failed', reason: 'offline' });
  });

  it('classifies rate limiting distinctly from other server errors', async () => {
    expect(await callWith(async () => jsonResponse({}, 429))).toEqual({
      status: 'failed',
      reason: 'rate_limited',
    });
    expect(await callWith(async () => jsonResponse({}, 500))).toEqual({
      status: 'failed',
      reason: 'server_error',
    });
  });

  it('handles a body that is not JSON', async () => {
    const result = await callWith(
      async () =>
        ({
          ok: true,
          status: 200,
          json: async () => {
            throw new SyntaxError('Unexpected token');
          },
        }) as unknown as Response,
    );
    expect(result).toEqual({ status: 'failed', reason: 'malformed_response' });
  });

  it('reports not_configured when no endpoint is set, without calling fetch', async () => {
    const fetchImpl = jest.fn();

    const result = await recognizeItem({
      imageUri: 'file:///photo.jpg',
      endpoint: null,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      readImage,
    });

    expect(result).toEqual({ status: 'failed', reason: 'not_configured' });
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});

describe('telemetry redaction', () => {
  it('keeps only allowlisted measurement keys', () => {
    expect(
      redact({
        latencyMs: 120,
        outcome: 'success',
        itemName: 'Grandmother necklace',
        notes: 'in the blue envelope',
        photoUri: 'file:///photos/secret.jpg',
        qrToken: 'a'.repeat(32),
      }),
    ).toEqual({ latencyMs: 120, outcome: 'success' });
  });

  it('drops non-primitive values even under an allowed key', () => {
    expect(redact({ outcome: { nested: 'object' } as never })).toEqual({});
  });
});
