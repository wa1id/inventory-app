/**
 * Environment-specific configuration.
 *
 * Read from `EXPO_PUBLIC_*` variables, which Metro inlines at build time. Only
 * non-secret values belong here: anything in this file ships inside the app
 * bundle and must be treated as public (issue #2).
 *
 * The AI provider key deliberately has no entry — recognition goes through our
 * own endpoint, which holds the provider credential server-side (issue #7).
 *
 * This module imports nothing native on purpose, so configuration stays
 * readable from plain Node in tests and tooling.
 */
export interface AppConfig {
  /** Base URL of the recognition backend, or null when not configured. */
  recognitionEndpoint: string | null;
  /**
   * Shared key the recognition service expects.
   *
   * This ships inside the app bundle and is therefore extractable by anyone who
   * unpacks the build — it raises the cost of casual abuse, nothing more. The
   * server's rate limit is the real spend cap, and proper auth waits on
   * accounts (issue #15).
   */
  recognitionKey: string | null;
  /** Wall-clock budget for one recognition request. */
  recognitionTimeoutMs: number;
  /**
   * Base URL of the photo and backup service, or null when not configured.
   *
   * Null is a supported build, not a broken one: the app stays entirely local,
   * which is exactly what it was before this service existed.
   */
  syncEndpoint: string | null;
  /**
   * Shared key the sync service expects.
   *
   * Same honesty as `recognitionKey`: it ships inside the bundle and is
   * extractable. It keeps the endpoint from being discovered and used as free
   * storage. What actually protects an account is the recovery code, which is
   * generated on the device and never travels in a build.
   */
  syncKey: string | null;
  /**
   * Wall-clock budget for one sync request.
   *
   * Longer than recognition's: a backup upload is megabytes rather than one
   * photo, and it runs where the user is not waiting on it.
   */
  syncTimeoutMs: number;
  /**
   * Household API origin. Phones only use the Cloudflare hostname.
   * Override in tests; production default is inventory.wystudio.be.
   */
  householdOrigin: string;
  environment: 'development' | 'preview' | 'production';
}

function readEnvironment(): AppConfig['environment'] {
  const value = process.env.EXPO_PUBLIC_ENV;
  if (value === 'production' || value === 'preview') return value;
  return 'development';
}

export const appConfig: AppConfig = {
  recognitionEndpoint: process.env.EXPO_PUBLIC_RECOGNITION_URL?.trim() || null,
  recognitionKey: process.env.EXPO_PUBLIC_RECOGNITION_KEY?.trim() || null,
  recognitionTimeoutMs: Number(process.env.EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS ?? 15_000),
  syncEndpoint: process.env.EXPO_PUBLIC_SYNC_URL?.trim().replace(/\/+$/, '') || null,
  syncKey: process.env.EXPO_PUBLIC_SYNC_KEY?.trim() || null,
  syncTimeoutMs: Number(process.env.EXPO_PUBLIC_SYNC_TIMEOUT_MS ?? 60_000),
  householdOrigin:
    process.env.EXPO_PUBLIC_HOUSEHOLD_ORIGIN?.trim().replace(/\/+$/, '') ||
    'https://inventory.wystudio.be',
  environment: readEnvironment(),
};
