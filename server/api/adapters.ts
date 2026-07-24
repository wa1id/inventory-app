import { DEFAULT_ADAPTER_ID } from '../src/adapters/index.ts';
import { CONTRACT_VERSION } from '../src/contract.ts';
import { getAdapter, listAdapterIds } from '../src/registry.ts';

/**
 * GET /api/adapters — which models this deployment can serve.
 *
 * Useful for confirming a redeploy actually changed the default, and for
 * picking an id to pass as `adapter` when A/B testing. Exposes no secrets:
 * ids and labels only.
 */
export default async function handler(request: Request): Promise<Response> {
  if (request.method !== 'GET') {
    return new Response(JSON.stringify({ error: 'Method not allowed.' }), {
      status: 405,
      headers: { 'content-type': 'application/json' },
    });
  }

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
