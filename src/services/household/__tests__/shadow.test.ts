import { initializeRepositories } from '@/db/repositories';
import { openNodeDatabase } from '@/db/testing/nodeDatabase';
import { createHttpRepositories } from '@/services/household/httpRepositories';
import { withLocalShadow } from '@/services/household/shadow';

describe('withLocalShadow', () => {
  it('mirrors a successful household create into local SQLite', async () => {
    const local = await initializeRepositories(openNodeDatabase());
    const fetchImpl = jest.fn(async (input: RequestInfo, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith('/v1/spaces') && init?.method === 'POST') {
        return new Response(
          JSON.stringify({
            id: 'space-server',
            name: 'Garage',
            icon: '🚗',
            color: '#5B8DEF',
            createdAt: 1,
            updatedAt: 1,
          }),
          { status: 201, headers: { 'content-type': 'application/json' } },
        );
      }
      return new Response('{}', { status: 404 });
    }) as unknown as typeof fetch;

    const remote = createHttpRepositories(
      {
        origin: 'https://inventory.wystudio.be',
        token: 'tok',
        deviceId: 'd1',
        deviceName: 'Phone',
        householdName: 'Home',
      },
      fetchImpl,
    );
    const repos = withLocalShadow(remote, local);

    const space = await repos.spaces.create({ name: 'Garage', icon: '🚗', color: '#5B8DEF' });
    expect(space.id).toBe('space-server');
    expect(await local.spaces.getById('space-server')).toMatchObject({ name: 'Garage' });
  });
});
