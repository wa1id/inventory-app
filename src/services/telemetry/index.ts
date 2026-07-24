/**
 * Analytics and crash-reporting seam.
 *
 * No provider is wired up for the MVP. Everything funnels through here so a
 * real backend can be attached later by implementing `TelemetrySink` and
 * calling `setTelemetrySink` once at startup — without touching call sites and
 * without blocking local development (issue #2).
 *
 * The privacy rule from issue #8 is enforced here rather than trusted to every
 * caller: event payloads may only contain the primitive, non-identifying keys
 * on `ALLOWED_KEYS`. Item names, notes, photo URIs, and QR tokens can never
 * reach a log line, even by accident.
 */

export type TelemetryValue = string | number | boolean | null;
export type TelemetryPayload = Record<string, TelemetryValue>;

export interface TelemetrySink {
  event(name: string, payload: TelemetryPayload): void;
  error(name: string, payload: TelemetryPayload): void;
}

/**
 * Allowlist, not a denylist: anything not named here is dropped.
 *
 * These are all measurements and enum-like classifications — never inventory
 * content.
 */
const ALLOWED_KEYS = new Set([
  'durationMs',
  'latencyMs',
  'outcome',
  'errorClass',
  'contractVersion',
  'statusCode',
  'itemCount',
  'containerCount',
  'spaceCount',
  'resultCount',
  'termCount',
  'queryLength',
  'confidence',
  'source',
  'permission',
  'screen',
  'step',
  'schemaVersion',
  'byteSize',
  'attempt',
  'hasPhoto',
  'suggestionAccepted',
]);

/** Drops any key that is not explicitly allowed and any non-primitive value. */
export function redact(payload: TelemetryPayload): TelemetryPayload {
  const safe: TelemetryPayload = {};

  for (const [key, value] of Object.entries(payload)) {
    if (!ALLOWED_KEYS.has(key)) continue;
    if (value === null || ['string', 'number', 'boolean'].includes(typeof value)) {
      safe[key] = value;
    }
  }

  return safe;
}

/** Development sink: prints to the console so events are visible while building. */
const consoleSink: TelemetrySink = {
  event(name, payload) {
    if (__DEV__) console.log(`[telemetry] ${name}`, payload);
  },
  error(name, payload) {
    if (__DEV__) console.warn(`[telemetry:error] ${name}`, payload);
  },
};

let sink: TelemetrySink = consoleSink;

export function setTelemetrySink(next: TelemetrySink): void {
  sink = next;
}

export function logEvent(name: string, payload: TelemetryPayload = {}): void {
  sink.event(name, redact(payload));
}

export function logError(name: string, payload: TelemetryPayload = {}): void {
  sink.error(name, redact(payload));
}
