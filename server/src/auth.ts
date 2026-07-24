import { timingSafeEqual } from 'node:crypto';

/**
 * Shared-secret gate for the recognition endpoint.
 *
 * Be honest about what this is: the secret ships inside the mobile app bundle,
 * so anyone who unpacks the APK can read it. It raises the cost of casual abuse
 * — drive-by scanners, someone who finds the URL in a proxy log — and nothing
 * more. The rate limit is the actual spend cap, and real authentication has to
 * wait for accounts (issue #15).
 *
 * Unset secret = open endpoint. That is deliberate for local development, and
 * the deployment sets it.
 */
export const AUTH_HEADER = 'x-inventory-key';

export type AuthResult = { ok: true } | { ok: false; status: number; error: string };

export function checkAuth(request: Request): AuthResult {
  const expected = process.env.RECOGNITION_SHARED_SECRET?.trim();
  if (!expected) return { ok: true };

  const provided = request.headers.get(AUTH_HEADER);
  if (!provided) {
    return { ok: false, status: 401, error: 'Missing credentials.' };
  }

  return safeEqual(provided, expected)
    ? { ok: true }
    : { ok: false, status: 401, error: 'Invalid credentials.' };
}

/**
 * Constant-time comparison.
 *
 * `timingSafeEqual` throws on length mismatch, which would itself leak the
 * expected length, so both sides are hashed to a fixed width first.
 */
function safeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const left = Buffer.from(encoder.encode(a));
  const right = Buffer.from(encoder.encode(b));

  if (left.length !== right.length) {
    // Still burn a comparison so the failure path costs the same.
    timingSafeEqual(left, left);
    return false;
  }

  return timingSafeEqual(left, right);
}
