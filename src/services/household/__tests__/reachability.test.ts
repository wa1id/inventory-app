import {
  householdFetch,
  householdRequest,
  onHouseholdReachability,
  pairWithHousehold,
  type Reachability,
} from '@/services/household/client';

const ORIGIN = 'https://inventory.example';

function respond(status: number, body: unknown = {}): typeof fetch {
  return jest.fn(
    async () => new Response(JSON.stringify(body), { status }),
  ) as unknown as typeof fetch;
}

/** A token-carrying read that gets `status` back. */
function fetchWithToken(status: number): Promise<Response> {
  return householdFetch({
    origin: ORIGIN,
    path: '/v1/spaces',
    token: 't',
    fetchImpl: respond(status),
  });
}

function record(): { seen: Reachability[]; stop: () => void } {
  const seen: Reachability[] = [];
  const stop = onHouseholdReachability((reachability) => seen.push(reachability));
  return { seen, stop };
}

describe('household reachability', () => {
  let recorder: ReturnType<typeof record>;

  beforeEach(() => {
    recorder = record();
  });

  afterEach(() => {
    recorder.stop();
  });

  it('reports ok for any answer from the home server', async () => {
    await fetchWithToken(200);
    await expect(
      householdRequest({
        origin: ORIGIN,
        path: '/v1/items/x',
        token: 't',
        fetchImpl: respond(404),
      }),
    ).rejects.toMatchObject({ status: 404 });
    expect(recorder.seen).toEqual(['ok', 'ok']);
  });

  it('reports unauthorized for a 401 on a request that carried a token', async () => {
    await fetchWithToken(401);
    expect(recorder.seen).toEqual(['unauthorized']);
  });

  it('treats a refused household code while pairing as an answer, not a removed phone', async () => {
    await expect(
      pairWithHousehold({
        origin: ORIGIN,
        bootstrapSecret: 'nope',
        deviceName: 'Pixel',
        fetchImpl: respond(401, { error: 'unauthorized' }),
      }),
    ).rejects.toMatchObject({ status: 401 });
    expect(recorder.seen).toEqual(['ok']);
  });

  it('reports offline when the request never gets an answer', async () => {
    const fetchImpl = jest.fn(async () => {
      throw new TypeError('Network request failed');
    }) as unknown as typeof fetch;
    await expect(
      householdFetch({ origin: ORIGIN, path: '/v1/spaces', token: 't', fetchImpl }),
    ).rejects.toMatchObject({ code: 'offline' });
    expect(recorder.seen).toEqual(['offline']);
  });

  it('reports offline when Cloudflare says the home box is down', async () => {
    await fetchWithToken(530);
    await fetchWithToken(502);
    await fetchWithToken(500);
    expect(recorder.seen).toEqual(['offline', 'offline', 'ok']);
  });

  it('stops reporting to a listener that unsubscribed', async () => {
    recorder.stop();
    await fetchWithToken(200);
    expect(recorder.seen).toEqual([]);
  });

  it('never fails a request because a listener threw', async () => {
    const stop = onHouseholdReachability(() => {
      throw new Error('listener bug');
    });
    const response = await fetchWithToken(200);
    stop();
    expect(response.status).toBe(200);
  });
});
