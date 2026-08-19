/**
 * Two devices edited the same row from different `updatedAt` values.
 *
 * Thrown by `items.update` when `expectedUpdatedAt` no longer matches, and by
 * the household client when the server answers 409. Screens keep calling
 * `repos.items.update(id, patch)` — this is the only extra they have to catch.
 */
export class ConflictError extends Error {
  readonly status = 409;
  readonly code = 'conflict';

  constructor(public readonly updatedAt: number | null = null) {
    super('conflict');
    this.name = 'ConflictError';
  }
}
