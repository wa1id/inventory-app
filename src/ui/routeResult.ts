/**
 * Results handed back between routes: a photo from the camera, a container
 * just created from the place picker, a finished move.
 *
 * The opener passes a short `request` id in the route params and awaits a
 * promise; the screen it opened delivers a value under that id and closes.
 * Values never travel as route params, so a photo's metadata or an item does
 * not end up in the URL or the navigation state.
 *
 * Pending requests live in memory only, so a request is lost if the app
 * restarts in between. That is acceptable: the opener is gone then too.
 */

const pending = new Map<string, (value: unknown) => void>();

function newRequestId(): string {
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Opens a route that will answer, and waits for the answer.
 *
 * `open` receives the request id to put in the route params. Resolves with the
 * delivered value, or `undefined` when the other screen closes without one.
 */
export function openForResult<T>(open: (requestId: string) => void): Promise<T | undefined> {
  const requestId = newRequestId();
  return new Promise<T | undefined>((resolve) => {
    pending.set(requestId, (value) => resolve(value as T | undefined));
    try {
      open(requestId);
    } catch (error) {
      pending.delete(requestId);
      throw error;
    }
  });
}

/**
 * Answers a request. Returns false when nobody is waiting any more (it was
 * already answered or abandoned, or the id is missing), so the caller can fall
 * back to its own behaviour.
 */
export function deliverResult<T>(requestId: string | null | undefined, value: T): boolean {
  if (!requestId) return false;
  const resolve = pending.get(requestId);
  if (!resolve) return false;
  pending.delete(requestId);
  resolve(value);
  return true;
}

/**
 * Closes a request without an answer. Idempotent, so a receiving screen can
 * call it from its unmount effect whether or not it delivered first.
 */
export function abandonResult(requestId: string | null | undefined): void {
  if (!requestId) return;
  const resolve = pending.get(requestId);
  if (!resolve) return;
  pending.delete(requestId);
  resolve(undefined);
}
