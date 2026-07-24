import { DEFAULT_ADAPTER_ID } from '../src/adapters/index.ts';
import {
  parseRequest,
  statusForAdapterError,
  suggestionResponse,
  unrecognizedResponse,
} from '../src/contract.ts';
import { UnknownAdapterError, getAdapter, hasAdapter } from '../src/registry.ts';

/** Wall-clock budget for one provider call, below the client's own timeout. */
const TIMEOUT_MS = Number(process.env.RECOGNITION_TIMEOUT_MS ?? 12_000);

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

/**
 * POST /api/recognize — turn one item photo into an editable suggestion.
 *
 * The provider credential never leaves this function; the mobile client only
 * ever sees this endpoint. Selection is by adapter id, so which model answers
 * is a deployment decision.
 *
 * Logging records timings and outcome classes only — never the image, the
 * suggestion text, or anything the user typed.
 */
export default async function handler(request: Request): Promise<Response> {
  const startedAt = Date.now();

  if (request.method !== 'POST') {
    return json({ error: 'Method not allowed.' }, 405);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'Body must be valid JSON.' }, 400);
  }

  const parsed = parseRequest(body);
  if (!parsed.ok) {
    console.log(JSON.stringify({ event: 'recognize_rejected', status: parsed.status }));
    return json({ error: parsed.error }, parsed.status);
  }

  const adapterId = parsed.adapter ?? DEFAULT_ADAPTER_ID;
  if (parsed.adapter && !hasAdapter(parsed.adapter)) {
    return json({ error: `Unknown adapter "${parsed.adapter}".` }, 400);
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const adapter = getAdapter(adapterId);
    const outcome = await adapter.recognize({
      image: { bytes: parsed.bytes, mediaType: parsed.mediaType },
      signal: controller.signal,
    });

    const log = {
      event: 'recognize_completed',
      adapter: adapterId,
      outcome: outcome.status === 'error' ? outcome.kind : outcome.status,
      latencyMs: Date.now() - startedAt,
      imageBytes: parsed.bytes.byteLength,
      confidence: outcome.status === 'ok' ? outcome.suggestion.confidence : null,
    };
    console.log(JSON.stringify(log));

    if (outcome.status === 'ok') return json(suggestionResponse(outcome.suggestion), 200);
    if (outcome.status === 'unrecognized') return json(unrecognizedResponse(), 200);

    return json({ error: outcome.kind }, statusForAdapterError(outcome));
  } catch (error) {
    if (error instanceof UnknownAdapterError) {
      return json({ error: error.message }, 500);
    }
    console.error(
      JSON.stringify({
        event: 'recognize_failed',
        adapter: adapterId,
        latencyMs: Date.now() - startedAt,
        errorClass: error instanceof Error ? error.name : 'unknown',
      }),
    );
    return json({ error: 'upstream' }, 502);
  } finally {
    clearTimeout(timer);
  }
}
