import { registerAdapter } from '../registry.js';
import { createAnthropicVisionAdapter } from './anthropicVision.js';

/**
 * Adapter registrations — the plug-in point.
 *
 * ADDING A CLAUDE MODEL: one line here; a different model is a different id.
 * Take ids from `GET https://api.anthropic.com/v1/models` — ids from memory are
 * frequently stale.
 *
 * ADDING ANOTHER PROVIDER: write a module satisfying `VisionAdapter` (see
 * `./anthropicVision.ts` for the shape), import it, and add one
 * `registerAdapter` line. No other file changes.
 */
registerAdapter('claude-haiku', () =>
  createAnthropicVisionAdapter({
    id: 'claude-haiku',
    label: 'Claude Haiku 5.5 (cheapest vision tier)',
    model: 'claude-haiku-5-5',
  }),
);

registerAdapter('claude-sonnet', () =>
  createAnthropicVisionAdapter({
    id: 'claude-sonnet',
    label: 'Claude Sonnet 5 (higher accuracy, ~20x input cost)',
    model: 'claude-sonnet-5',
  }),
);

/**
 * Default when the request does not name one. Overridable per deployment so
 * switching models is a redeploy, not a code change.
 *
 * Every adapter needs `ANTHROPIC_API_KEY` set on the deployment.
 */
export const DEFAULT_ADAPTER_ID = process.env.RECOGNITION_ADAPTER?.trim() || 'claude-haiku';
