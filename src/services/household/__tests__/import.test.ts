import { initializeRepositories } from '@/db/repositories';
import { openNodeDatabase } from '@/db/testing/nodeDatabase';
import { collectHouseholdDump } from '@/services/household/collectDump';
import { importLocalInventory } from '@/services/household/importHousehold';

describe('household import', () => {
  it('collects local rows including system drop-zone', async () => {
    const repos = await initializeRepositories(openNodeDatabase());
    const space = await repos.spaces.create({ name: 'Garage', icon: '🚗', color: '#5B8DEF' });
    const container = await repos.containers.create({ spaceId: space.id, visualType: 'box' });
    await repos.items.create({ containerId: container.id, name: 'Drill' });

    const dump = await collectHouseholdDump(repos.db);
    expect(dump.spaces.some((row) => row.id === 'drop-zone-space')).toBe(true);
    expect(dump.containers.some((row) => row.id === 'drop-zone')).toBe(true);
    expect(dump.items.some((row) => row.name === 'Drill')).toBe(true);
  });

  it('POSTs the dump then PUTs each photo', async () => {
    const repos = await initializeRepositories(openNodeDatabase());
    const space = await repos.spaces.create({ name: 'Garage', icon: '🚗', color: '#5B8DEF' });
    const container = await repos.containers.create({ spaceId: space.id, visualType: 'box' });
    const photoId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    await repos.items.create({
      containerId: container.id,
      name: 'Cable',
      photo: { id: photoId, uri: 'file:///photos/cable.webp' },
    });

    const methods: string[] = [];
    const fetchImpl = jest.fn(async (input: RequestInfo, init?: RequestInit) => {
      const url = String(input);
      methods.push(`${init?.method ?? 'GET'} ${url}`);
      if (url.endsWith('/v1/import')) {
        return new Response(JSON.stringify({ ok: true, items: 1, photos: 1 }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        });
      }
      if (url.includes('/v1/photos/')) {
        return new Response(JSON.stringify({ id: photoId }), { status: 201 });
      }
      return new Response('{}', { status: 404 });
    }) as unknown as typeof fetch;

    const result = await importLocalInventory({
      session: {
        origin: 'https://inventory.wystudio.be',
        token: 'tok',
        deviceId: 'd1',
        deviceName: 'Phone',
        householdName: 'Home',
      },
      db: repos.db,
      fetchImpl,
      readPhoto: async () => new Uint8Array([1, 2, 3, 4]),
    });

    expect(result.items).toBe(1);
    expect(result.photosUploaded).toBe(1);
    expect(methods.some((line) => line.startsWith('POST ') && line.endsWith('/v1/import'))).toBe(
      true,
    );
    expect(methods.some((line) => line.startsWith('PUT ') && line.includes('/v1/photos/'))).toBe(
      true,
    );
  });
});
