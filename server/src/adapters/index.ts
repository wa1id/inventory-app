import { registerAdapter } from '../registry.js';
import { createGatewayVisionAdapter } from './gatewayVision.js';

/**
 * Adapter registrations — the plug-in point.
 *
 * ADDING A MODEL: one line here. The gateway fronts every major provider, so a
 * different model is a different string.
 *
 * ADDING A PROVIDER THE GATEWAY DOES NOT FRONT: write a module satisfying
 * `VisionAdapter` (see `./gatewayVision.ts` for the shape), import it, and add
 * one `registerAdapter` line. No other file changes.
 *
 * Model ids verified against `GET https://ai-gateway.vercel.sh/v1/models`.
 * Re-check that list before adding one — ids from memory are frequently stale.
 */
registerAdapter('claude-haiku', () =>
  createGatewayVisionAdapter({
    id: 'claude-haiku',
    label: 'Claude Haiku 4.5 (cheapest vision tier)',
    model: 'anthropic/claude-haiku-4.5',
  }),
);

registerAdapter('claude-sonnet', () =>
  createGatewayVisionAdapter({
    id: 'claude-sonnet',
    label: 'Claude Sonnet 5 (higher accuracy, ~3x input cost)',
    model: 'anthropic/claude-sonnet-5',
  }),
);

registerAdapter('gemini-flash', () =>
  createGatewayVisionAdapter({
    id: 'gemini-flash',
    label: 'Gemini 2.5 Flash (cross-vendor comparison)',
    model: 'google/gemini-2.5-flash',
  }),
);

/**
 * Default when the request does not name one. Overridable per deployment so
 * switching models is a redeploy, not a code change.
 */
export const DEFAULT_ADAPTER_ID = process.env.RECOGNITION_ADAPTER?.trim() || 'claude-haiku';
