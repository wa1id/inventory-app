import { ConflictError } from '@/core/conflict';
import { appConfig } from '@/services/config';

export class HouseholdHttpError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
  ) {
    super(code);
    this.name = 'HouseholdHttpError';
  }
}

export { ConflictError };

export interface HouseholdSession {
  origin: string;
  token: string;
  deviceId: string;
  deviceName: string;
  householdName: string;
}

export interface PairRequest {
  origin?: string;
  bootstrapSecret: string;
  deviceName: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

export async function pairWithHousehold(request: PairRequest): Promise<HouseholdSession> {
  const origin = (request.origin ?? appConfig.householdOrigin).replace(/\/+$/, '');
  const body = await householdRequest({
    origin,
    path: '/v1/pair',
    method: 'POST',
    json: { bootstrapSecret: request.bootstrapSecret, deviceName: request.deviceName },
    fetchImpl: request.fetchImpl,
    timeoutMs: request.timeoutMs,
  });
  if (
    typeof body.token !== 'string' ||
    typeof body.deviceId !== 'string' ||
    typeof body.origin !== 'string'
  ) {
    throw new HouseholdHttpError(500, 'invalid_response');
  }
  return {
    origin: String(body.origin).replace(/\/+$/, ''),
    token: body.token,
    deviceId: body.deviceId,
    deviceName: request.deviceName.trim(),
    householdName: typeof body.householdName === 'string' ? body.householdName : 'Home',
  };
}

export async function householdRequest(options: {
  origin: string;
  path: string;
  method?: string;
  token?: string;
  json?: unknown;
  form?: FormData;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}): Promise<Record<string, unknown>> {
  const response = await householdFetch(options);
  if (response.status === 204) return {};
  const text = await response.text();
  let parsed: unknown = {};
  if (text) {
    try {
      parsed = JSON.parse(text) as unknown;
    } catch {
      throw new HouseholdHttpError(response.status, 'invalid_json');
    }
  }
  if (response.status === 409) {
    const updatedAt =
      parsed && typeof parsed === 'object' && parsed !== null && 'updatedAt' in parsed
        ? Number((parsed as { updatedAt: unknown }).updatedAt)
        : null;
    throw new ConflictError(Number.isFinite(updatedAt) ? updatedAt : null);
  }
  if (!response.ok) {
    const code =
      parsed && typeof parsed === 'object' && 'error' in parsed
        ? String((parsed as { error: unknown }).error)
        : `http_${response.status}`;
    throw new HouseholdHttpError(response.status, code);
  }
  if (typeof parsed !== 'object' || parsed === null) return {};
  return parsed as Record<string, unknown>;
}

export async function householdFetch(options: {
  origin: string;
  path: string;
  method?: string;
  token?: string;
  json?: unknown;
  form?: FormData;
  bytes?: Uint8Array;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}): Promise<Response> {
  const doFetch = options.fetchImpl ?? globalThis.fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 20_000);
  try {
    const copy = options.bytes ? new Uint8Array(options.bytes.byteLength) : undefined;
    if (copy && options.bytes) copy.set(options.bytes);
    return await doFetch(`${options.origin}${options.path}`, {
      method: options.method ?? 'GET',
      headers: {
        Accept: 'application/json',
        ...(options.json !== undefined && !options.form && !options.bytes
          ? { 'Content-Type': 'application/json' }
          : {}),
        ...(options.bytes ? { 'Content-Type': 'application/octet-stream' } : {}),
        ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
      },
      body:
        options.form ??
        copy ??
        (options.json !== undefined ? JSON.stringify(options.json) : undefined),
      signal: controller.signal,
    });
  } catch (error) {
    if (error instanceof HouseholdHttpError || error instanceof ConflictError) throw error;
    if (error instanceof Error && error.name === 'AbortError') {
      throw new HouseholdHttpError(0, 'timeout');
    }
    throw new HouseholdHttpError(0, 'offline');
  } finally {
    clearTimeout(timer);
  }
}
