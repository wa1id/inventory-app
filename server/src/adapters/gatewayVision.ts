import { Output, generateText } from 'ai';

import type { AdapterErrorKind, AdapterOutcome, RecognizeOptions, VisionAdapter } from '../port.js';
import { SYSTEM_PROMPT, USER_PROMPT, extractionSchema, toRawSuggestion } from '../prompt.js';

/**
 * Adapter over the Vercel AI Gateway.
 *
 * One adapter, many models: the gateway addresses every provider by a
 * `provider/model` string, so swapping Claude for Gemini or GPT is a
 * registration line, not new code. Write a *separate* adapter only for a
 * provider the gateway does not front — a self-hosted model, or a vendor whose
 * SDK you need directly.
 */
export function createGatewayVisionAdapter(config: {
  id: string;
  label: string;
  /** Gateway model id, e.g. `anthropic/claude-haiku-4.5`. */
  model: string;
}): VisionAdapter {
  return {
    id: config.id,
    label: config.label,

    async recognize({ image, signal }: RecognizeOptions): Promise<AdapterOutcome> {
      try {
        const { output } = await generateText({
          model: config.model,
          abortSignal: signal,
          system: SYSTEM_PROMPT,
          output: Output.object({ schema: extractionSchema }),
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

        if (!output.identified || !output.name?.trim()) {
          return { status: 'unrecognized' };
        }

        return { status: 'ok', suggestion: toRawSuggestion(output) };
      } catch (error) {
        return { status: 'error', ...classify(error) };
      }
    },
  };
}

/**
 * Maps provider and transport errors onto the port's three buckets.
 *
 * Classification lives in the adapter because only the adapter knows how its
 * provider signals failure; everything upstream reasons about the buckets.
 */
function classify(error: unknown): { kind: AdapterErrorKind; message: string } {
  const message = error instanceof Error ? error.message : String(error);

  if (error instanceof Error && (error.name === 'AbortError' || error.name === 'TimeoutError')) {
    return { kind: 'timeout', message };
  }

  const status = (error as { statusCode?: number; status?: number })?.statusCode
    ?? (error as { status?: number })?.status;

  if (status === 429 || /rate.?limit|quota|too many requests/i.test(message)) {
    return { kind: 'rate_limited', message };
  }

  return { kind: 'upstream', message };
}
