import { HouseholdHttpError, type HouseholdSession } from '@/services/household/client';
import { listDevices, revokeDevice } from '@/services/household/devices';

const session: HouseholdSession = {
  origin: 'https://inventory.example',
  token: 'secret-token',
  deviceId: 'b',
  deviceName: 'Anna’s iPhone',
  householdName: 'Home',
};

function respond(status: number, body?: unknown) {
  return jest.fn(
    async (_url: string, _init?: RequestInit) =>
      new Response(body === undefined ? null : JSON.stringify(body), { status }),
  );
}

describe('listDevices', () => {
  it('reads the household’s phones with the session token', async () => {
    const fetchImpl = respond(200, {
      devices: [
        { id: 'a', name: 'Kitchen iPhone', createdAt: 1, lastSeenAt: 5 },
        { id: 'b', name: 'Anna’s iPhone', createdAt: 2, lastSeenAt: null },
      ],
    });

    const devices = await listDevices(session, { fetchImpl: fetchImpl as typeof fetch });

    expect(devices).toEqual([
      { id: 'a', name: 'Kitchen iPhone', createdAt: 1, lastSeenAt: 5 },
      { id: 'b', name: 'Anna’s iPhone', createdAt: 2, lastSeenAt: null },
    ]);
    const [url, init] = fetchImpl.mock.calls[0]!;
    expect(url).toBe('https://inventory.example/v1/devices');
    expect(init?.method).toBe('GET');
    expect((init?.headers as Record<string, string>).Authorization).toBe('Bearer secret-token');
  });

  it('skips entries it cannot read instead of failing the list', async () => {
    const fetchImpl = respond(200, {
      devices: [{ id: 'a', name: 'Kitchen iPhone', createdAt: 1, lastSeenAt: 5 }, { id: 7 }, null],
    });

    const devices = await listDevices(session, { fetchImpl: fetchImpl as typeof fetch });

    expect(devices.map((device) => device.id)).toEqual(['a']);
  });

  it('rejects an answer without a list', async () => {
    const fetchImpl = respond(200, { nope: true });

    await expect(
      listDevices(session, { fetchImpl: fetchImpl as typeof fetch }),
    ).rejects.toBeInstanceOf(HouseholdHttpError);
  });
});

describe('revokeDevice', () => {
  it('deletes the phone by id', async () => {
    const fetchImpl = respond(204);

    await revokeDevice(session, 'a/b', { fetchImpl: fetchImpl as typeof fetch });

    const [url, init] = fetchImpl.mock.calls[0]!;
    expect(url).toBe('https://inventory.example/v1/devices/a%2Fb');
    expect(init?.method).toBe('DELETE');
  });

  it('treats a phone that is already gone as removed', async () => {
    const fetchImpl = respond(404, { error: 'not_found' });

    await expect(
      revokeDevice(session, 'a', { fetchImpl: fetchImpl as typeof fetch }),
    ).resolves.toBeUndefined();
  });

  it('passes other failures on', async () => {
    const fetchImpl = respond(500, { error: 'boom' });

    await expect(
      revokeDevice(session, 'a', { fetchImpl: fetchImpl as typeof fetch }),
    ).rejects.toMatchObject({ status: 500 });
  });
});
