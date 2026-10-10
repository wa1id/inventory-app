import Anthropic from '@anthropic-ai/sdk';
import { zodOutputFormat } from '@anthropic-ai/sdk/helpers/zod';

import type { AdapterErrorKind, AdapterOutcome, RecognizeOptions, VisionAdapter } from '../port.js';
import { SYSTEM_PROMPT, extractionSchema, toRawSuggestion, userPrompt } from '../prompt.js';

/**
 * Naming one object in a photo gains little from deliberation, and the request
 * has a 12 s budget. Haiku 5.5 would otherwise default to `medium`.
 */
const EFFORT = 'low';

/**
 * Thinking tokens count against this too. Running out mid-object leaves nothing
 * to parse, which surfaces as an upstream error, so it is not worth shaving.
 */
const MAX_TOKENS = 4096;

type ImageMediaType = Anthropic.Base64ImageSource['media_type'];

const SUPPORTED_MEDIA_TYPES: readonly string[] = [
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
] satisfies ImageMediaType[];

function isSupportedMediaType(mediaType: string): mediaType is ImageMediaType {
  return SUPPORTED_MEDIA_TYPES.includes(mediaType);
}

/**
 * Adapter over the Anthropic Messages API, billed to the deployment's own
 * `ANTHROPIC_API_KEY`.
 */
export function createAnthropicVisionAdapter(config: {
  id: string;
  label: string;
  /** Anthropic model id, e.g. `claude-haiku-5-5`. */
  model: string;
}): VisionAdapter {
  // Built on first use rather than here: `GET /api/adapters` builds every
  // registered adapter, and a deployment without a key should still be able to
  // list what it can serve.
  let client: Anthropic | undefined;

  return {
    id: config.id,
    label: config.label,

    async recognize({ image, signal, nameHint }: RecognizeOptions): Promise<AdapterOutcome> {
      if (!isSupportedMediaType(image.mediaType)) {
        return {
          status: 'error',
          kind: 'upstream',
          message: `Claude does not accept ${image.mediaType}; send JPEG, PNG, GIF, or WebP.`,
        };
      }

      try {
        client ??= new Anthropic();

        const response = await client.messages.parse(
          {
            model: config.model,
            max_tokens: MAX_TOKENS,
            system: SYSTEM_PROMPT,
            output_config: { effort: EFFORT, format: zodOutputFormat(extractionSchema) },
            messages: [
              {
                role: 'user',
                content: [
                  {
                    type: 'image',
                    source: {
                      type: 'base64',
                      media_type: image.mediaType,
                      data: Buffer.from(image.bytes).toString('base64'),
                    },
                  },
                  { type: 'text', text: userPrompt(nameHint) },
                ],
              },
            ],
          },
          { signal },
        );

        // A declined photo is one the user fills in by hand, same as one the
        // model could not name.
        if (response.stop_reason === 'refusal') {
          return { status: 'unrecognized' };
        }

        const output = response.parsed_output;
        if (!output) {
          return {
            status: 'error',
            kind: 'upstream',
            message: `No parseable answer (stop_reason: ${response.stop_reason}).`,
          };
        }

        // With a hint the name is the user's, so a model that omits it has
        // still answered usefully; only an explicit `identified: false` means
        // it could not work with the name it was given.
        if (!output.identified || !(nameHint ?? output.name)?.trim()) {
          return { status: 'unrecognized' };
        }

        return { status: 'ok', suggestion: toRawSuggestion(output, nameHint) };
      } catch (error) {
        return { status: 'error', ...classify(error) };
      }
    },
  };
}

/**
 * Maps Anthropic SDK errors onto the port's three buckets.
 *
 * Our own abort (the request budget running out) arrives as
 * `APIUserAbortError`, so it counts as a timeout alongside the SDK's.
 */
function classify(error: unknown): { kind: AdapterErrorKind; message: string } {
  const message = error instanceof Error ? error.message : String(error);

  if (
    error instanceof Anthropic.APIUserAbortError ||
    error instanceof Anthropic.APIConnectionTimeoutError
  ) {
    return { kind: 'timeout', message };
  }

  if (error instanceof Anthropic.RateLimitError) {
    return { kind: 'rate_limited', message };
  }

  return { kind: 'upstream', message };
}
