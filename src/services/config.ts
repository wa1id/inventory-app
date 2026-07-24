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
  /** Wall-clock budget for one recognition request. */
  recognitionTimeoutMs: number;
  environment: 'development' | 'preview' | 'production';
}

function readEnvironment(): AppConfig['environment'] {
  const value = process.env.EXPO_PUBLIC_ENV;
  if (value === 'production' || value === 'preview') return value;
  return 'development';
}

export const appConfig: AppConfig = {
  recognitionEndpoint: process.env.EXPO_PUBLIC_RECOGNITION_URL?.trim() || null,
  recognitionTimeoutMs: Number(process.env.EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS ?? 15_000),
  environment: readEnvironment(),
};
