import { DEFAULT_ADAPTER_ID } from '../src/adapters/index.js';
import { CONTRACT_VERSION } from '../src/contract.js';
import { getAdapter, listAdapterIds } from '../src/registry.js';

/**
 * GET /api/adapters — which models this deployment can serve.
 *
 * Useful for confirming a redeploy actually changed the default, and for
 * picking an id to pass as `adapter` when A/B testing. Exposes no secrets:
 * ids and labels only.
 */
export async function GET(): Promise<Response> {
  const adapters = listAdapterIds().map((id) => ({
    id,
    label: getAdapter(id).label,
    default: id === DEFAULT_ADAPTER_ID,
  }));

  return new Response(JSON.stringify({ contractVersion: CONTRACT_VERSION, adapters }, null, 2), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
}
