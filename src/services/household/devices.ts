import { HouseholdHttpError, householdRequest, type HouseholdSession } from './client';

/** A phone joined to the household, as the home server lists it. */
export interface HouseholdDevice {
  id: string;
  name: string;
  createdAt: number;
  /** When it last made a request; null for a phone that joined and never came back. */
  lastSeenAt: number | null;
}

interface DeviceRequestOptions {
  fetchImpl?: typeof fetch;
  /** Overrides the client's 20 s; leaving asks only briefly, since it must work offline. */
  timeoutMs?: number;
}

function toDevice(value: unknown): HouseholdDevice | null {
  if (typeof value !== 'object' || value === null) return null;
  const record = value as Record<string, unknown>;
  if (typeof record.id !== 'string' || typeof record.name !== 'string') return null;
  const createdAt = Number(record.createdAt);
  const lastSeenAt = record.lastSeenAt === null ? null : Number(record.lastSeenAt);
  return {
    id: record.id,
    name: record.name,
    createdAt: Number.isFinite(createdAt) ? createdAt : 0,
    lastSeenAt: lastSeenAt !== null && Number.isFinite(lastSeenAt) ? lastSeenAt : null,
  };
}

/**
 * Every phone joined to the household (`GET /v1/devices`), oldest first.
 *
 * The endpoints existed on the home server (`home-server/src/app.ts:112-122`)
 * with no screen to reach them: any phone may see and remove any other (K19,
 * #47), so the owner can tidy up a lost phone and either phone can remove the
 * other. Entries the app cannot read are skipped rather than failing the list.
 */
export async function listDevices(
  session: HouseholdSession,
  options: DeviceRequestOptions = {},
): Promise<HouseholdDevice[]> {
  const body = await householdRequest({
    origin: session.origin,
    path: '/v1/devices',
    token: session.token,
    fetchImpl: options.fetchImpl,
  });
  if (!Array.isArray(body.devices)) throw new HouseholdHttpError(500, 'invalid_response');
  return body.devices.map(toDevice).filter((device) => device !== null);
}

/**
 * Removes a phone from the household (`DELETE /v1/devices/:id`). Its token
 * stops working at once; the inventory is untouched.
 *
 * A 404 means it is already gone (removed on another phone a moment ago),
 * which is what was asked for, so it resolves rather than reporting a failure.
 */
export async function revokeDevice(
  session: HouseholdSession,
  deviceId: string,
  options: DeviceRequestOptions = {},
): Promise<void> {
  try {
    await householdRequest({
      origin: session.origin,
      path: `/v1/devices/${encodeURIComponent(deviceId)}`,
      method: 'DELETE',
      token: session.token,
      fetchImpl: options.fetchImpl,
      timeoutMs: options.timeoutMs,
    });
  } catch (cause) {
    if (cause instanceof HouseholdHttpError && cause.status === 404) return;
    throw cause;
  }
}
