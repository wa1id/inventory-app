import { ConflictError, pairWithHousehold } from '@/services/household/client';
import { createHttpRepositories } from '@/services/household/httpRepositories';

describe('pairWithHousehold', () => {
  it('stores the token and origin from a successful pair', async () => {
    const fetchImpl = jest.fn(async () => {
      return new Response(
        JSON.stringify({
          token: 'abc',
          deviceId: 'dev-1',
          origin: 'https://inventory.wystudio.be',
          householdName: 'Home',
          contractVersion: 1,
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      );
    }) as unknown as typeof fetch;

    const session = await pairWithHousehold({
      bootstrapSecret: 'MMWKY-M2H78',
      deviceName: 'Pixel',
      fetchImpl,
    });

    expect(session.token).toBe('abc');
    expect(session.deviceId).toBe('dev-1');
    expect(session.origin).toBe('https://inventory.wystudio.be');
    expect(fetchImpl).toHaveBeenCalled();
  });

  it('maps 401 to HouseholdHttpError', async () => {
    const fetchImpl = jest.fn(async () => {
      return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 });
    }) as unknown as typeof fetch;

    await expect(
      pairWithHousehold({ bootstrapSecret: 'nope', deviceName: 'Pixel', fetchImpl }),
    ).rejects.toMatchObject({ name: 'HouseholdHttpError', status: 401, code: 'unauthorized' });
  });
});

describe('createHttpRepositories', () => {
  it('lists spaces from the household API', async () => {
    const fetchImpl = jest.fn(async (input: RequestInfo) => {
      const url = String(input);
      expect(url).toContain('/v1/spaces');
      return new Response(
        JSON.stringify({
          spaces: [{ id: 's1', name: 'Garage', containerCount: 1, itemCount: 2 }],
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      );
    }) as unknown as typeof fetch;

    const repos = createHttpRepositories(
      {
        origin: 'https://inventory.wystudio.be',
        token: 'tok',
        deviceId: 'd1',
        deviceName: 'Phone',
        householdName: 'Home',
      },
      fetchImpl,
    );

    const spaces = await repos.spaces.listWithCounts();
    expect(spaces[0]?.name).toBe('Garage');
  });

  it('POSTs item photos as multipart and maps 409 to ConflictError', async () => {
    const fetchImpl = jest.fn(async (input: RequestInfo, init?: RequestInit) => {
      const url = String(input);
      if (url.includes('/v1/items') && init?.method === 'POST') {
        expect(init.body).toBeInstanceOf(FormData);
        return new Response(
          JSON.stringify({
            id: 'item-1',
            containerId: 'c1',
            name: 'Cable',
            photoId: 'p1',
            updatedAt: 10,
            createdAt: 10,
          }),
          { status: 201, headers: { 'content-type': 'application/json' } },
        );
      }
      if (url.includes('/v1/items/item-1') && init?.method === 'PATCH') {
        return new Response(JSON.stringify({ error: 'conflict', updatedAt: 11 }), { status: 409 });
      }
      return new Response('{}', { status: 404 });
    }) as unknown as typeof fetch;

    const repos = createHttpRepositories(
      {
        origin: 'https://inventory.wystudio.be',
        token: 'tok',
        deviceId: 'd1',
        deviceName: 'Phone',
        householdName: 'Home',
      },
      fetchImpl,
      async () => new Uint8Array([1, 2, 3]),
    );

    const created = await repos.items.create({
      containerId: 'c1',
      name: 'Cable',
      photo: { uri: 'file:///photos/cable.webp' },
    });
    expect(created.id).toBe('item-1');

    await expect(
      repos.items.update('item-1', { name: 'HDMI', expectedUpdatedAt: 10 }),
    ).rejects.toBeInstanceOf(ConflictError);
  });
});
