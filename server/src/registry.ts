import type { AdapterFactory, VisionAdapter } from './port.js';

/**
 * The registry: `id → adapter`.
 *
 * This is what makes providers plug-and-play. Registration is the only place
 * that knows a given adapter exists; selection is by string, so the model in
 * use is a deployment decision (an env var) rather than a code change.
 */
const factories = new Map<string, AdapterFactory>();
const instances = new Map<string, VisionAdapter>();

export function registerAdapter(id: string, factory: AdapterFactory): void {
  if (factories.has(id)) {
    throw new Error(`Vision adapter "${id}" is already registered.`);
  }
  factories.set(id, factory);
}

export function listAdapterIds(): string[] {
  return [...factories.keys()].sort();
}

export function hasAdapter(id: string): boolean {
  return factories.has(id);
}

/**
 * Resolves an adapter by id, constructing it once and caching it.
 *
 * Throws `UnknownAdapterError` rather than silently falling back: quietly
 * serving a different model than the caller asked for would make A/B results
 * meaningless and cost surprises invisible.
 */
export function getAdapter(id: string): VisionAdapter {
  const cached = instances.get(id);
  if (cached) return cached;

  const factory = factories.get(id);
  if (!factory) {
    throw new UnknownAdapterError(id, listAdapterIds());
  }

  const adapter = factory();
  instances.set(id, adapter);
  return adapter;
}

export class UnknownAdapterError extends Error {
  // Declared as plain fields rather than constructor parameter properties:
  // those need code generation, which Node's type-stripping cannot do, and the
  // test runner loads this file directly.
  readonly requested: string;
  readonly available: string[];

  constructor(requested: string, available: string[]) {
    super(`Unknown vision adapter "${requested}". Available: ${available.join(', ') || 'none'}`);
    this.name = 'UnknownAdapterError';
    this.requested = requested;
    this.available = available;
  }
}

/** Test seam — resets registration state between suites. */
export function resetRegistry(): void {
  factories.clear();
  instances.clear();
}
