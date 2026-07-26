import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { Output, generateText } from 'ai';
import { z } from 'zod';

import type { AdapterErrorKind, AdapterOutcome, RecognizeOptions, VisionAdapter } from '../port.js';
import {
  SYSTEM_PROMPT,
  USER_PROMPT,
  toRawSuggestion,
  type Extraction,
} from '../prompt.js';

/** Xiaomi's OpenAI-compatible endpoint. */
const BASE_URL = 'https://api.xiaomimimo.com/v1';

/**
 * Generous enough for the JSON answer plus any reasoning tokens MiMo decides to
 * spend. Running out mid-object truncates the JSON, which surfaces as an
 * upstream error rather than a suggestion, so the ceiling is not worth shaving.
 */
const MAX_OUTPUT_TOKENS = 2048;

/**
 * MiMo declares support for `response_format: json_schema` but does not enforce
 * it. Two observed shapes, both HTTP 200:
 *
 *   {"identified": false}                       ← every other field omitted
 *   {"name": "...", "confidence": 0.9, ...}     ← `identified` omitted
 *
 * Validating those against the shared strict schema throws, which would report
 * a photo the model honestly could not name as a provider failure — the user
 * would see "suggestions are unavailable" instead of "add the details
 * yourself". So the wire shape is parsed loosely here and the gaps are filled
 * in `toExtraction`. The prompt and the normalization stay shared; only this
 * provider's looseness is absorbed locally.
 */
const wireExtraction = z.object({
  identified: z.boolean().optional(),
  name: z.string().nullish(),
  category: z.string().nullish(),
  tags: z.array(z.string()).optional(),
  estimatedValue: z.number().nullish(),
  currency: z.string().nullish(),
  confidence: z.number().optional(),
});

/** Fills the fields MiMo omits, without inventing anything the model did not say. */
export function toExtraction(wire: z.infer<typeof wireExtraction>): Extraction {
  return {
    // An omitted `identified` means the model answered with a name instead of
    // the flag; treat a usable name as the identification it clearly intended.
    identified: wire.identified ?? Boolean(wire.name?.trim()),
    name: wire.name ?? null,
    category: wire.category ?? null,
    tags: wire.tags ?? [],
    estimatedValue: wire.estimatedValue ?? null,
    currency: wire.currency ?? null,
    // Certainty is never invented on the model's behalf (see `port.ts`). An
    // omitted confidence scores zero, which the contract then filters out as
    // low confidence — a weak suggestion the user must undo is worse than none.
    confidence: wire.confidence ?? 0,
  };
}

/**
 * Adapter over Xiaomi MiMo.
 *
 * MiMo is not fronted by the AI Gateway, so it gets its own adapter rather than
 * a registration line. Its API is OpenAI-shaped, hence the openai-compatible
 * provider — but only the transport is OpenAI-shaped, which is why this file
 * exists at all:
 *
 * - Tool calls are unusable. The model writes `<tool_call>…</tool_call>` into
 *   the message content and returns `tool_calls: null`, so structured output
 *   must go through JSON mode, never tool mode.
 * - `strict: true` on the JSON schema is accepted and ignored (see above).
 */
export function createMimoVisionAdapter(config: {
  id: string;
  label: string;
  /** MiMo model id, e.g. `mimo-v2.5`. */
  model: string;
}): VisionAdapter {
  const apiKey = process.env.MIMO_API_KEY?.trim();

  const mimo = createOpenAICompatible({
    name: 'mimo',
    baseURL: BASE_URL,
    apiKey: apiKey ?? '',
    // Sends the schema as `response_format: json_schema`. MiMo treats it as a
    // strong hint rather than a guarantee; `wireExtraction` covers the gap.
    supportsStructuredOutputs: true,
  });

  return {
    id: config.id,
    label: config.label,

    async recognize({ image, signal }: RecognizeOptions): Promise<AdapterOutcome> {
      // Checked here rather than thrown at construction: `GET /api/adapters`
      // builds every registered adapter, and a deployment without a MiMo key
      // should still be able to list what it can serve.
      if (!apiKey) {
        return {
          status: 'error',
          kind: 'upstream',
          message: 'MIMO_API_KEY is not set; the MiMo adapter cannot authenticate.',
        };
      }

      try {
        const { output } = await generateText({
          model: mimo(config.model),
          abortSignal: signal,
          system: SYSTEM_PROMPT,
          maxOutputTokens: MAX_OUTPUT_TOKENS,
          output: Output.object({ schema: wireExtraction }),
          messages: [
            {
              role: 'user',
              content: [
                { type: 'file', mediaType: image.mediaType, data: image.bytes },
                { type: 'text', text: USER_PROMPT },
              ],
            },
          ],
        });

        const extraction = toExtraction(output);

        if (!extraction.identified || !extraction.name?.trim()) {
          return { status: 'unrecognized' };
        }

        return { status: 'ok', suggestion: toRawSuggestion(extraction) };
      } catch (error) {
        return { status: 'error', ...classify(error) };
      }
    },
  };
}

/**
 * Maps MiMo and transport errors onto the port's three buckets.
 *
 * Unparseable output lands in `upstream` deliberately: the model returning
 * something that is not the agreed JSON is a provider fault, not a photo the
 * model could not read — that case comes back as a well-formed
 * `{"identified": false}` and never reaches here.
 */
function classify(error: unknown): { kind: AdapterErrorKind; message: string } {
  const message = error instanceof Error ? error.message : String(error);

  if (error instanceof Error && (error.name === 'AbortError' || error.name === 'TimeoutError')) {
    return { kind: 'timeout', message };
  }

  const status =
    (error as { statusCode?: number; status?: number })?.statusCode ??
    (error as { status?: number })?.status;

  if (status === 429 || /rate.?limit|quota|too many requests/i.test(message)) {
    return { kind: 'rate_limited', message };
  }

  return { kind: 'upstream', message };
}
