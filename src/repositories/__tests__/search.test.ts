import { initializeRepositories } from '@/db/repositories';
import type { Repositories } from '@/db/repositories';
import { openNodeDatabase } from '@/db/testing/nodeDatabase';
import { formatLocationPath } from '@/repositories/search';

async function seedInventory() {
  const repos = await initializeRepositories(openNodeDatabase());

  const garage = await repos.spaces.create({ name: 'Garage', icon: 'car', color: '#5B8DEF' });
  const kitchen = await repos.spaces.create({ name: 'Kitchen', icon: 'pot', color: '#E4572E' });

  const toolBox = await repos.containers.create({
    spaceId: garage.id,
    visualType: 'box',
    name: 'Tool Box',
  });
  const drawer = await repos.containers.create({
    spaceId: kitchen.id,
    visualType: 'drawer',
    name: 'Utensil Drawer',
  });

  await repos.items.create({
    containerId: toolBox.id,
    name: 'Cordless Drill',
    category: 'Power Tools',
    tags: ['dewalt', '18v'],
  });
  await repos.items.create({ containerId: toolBox.id, name: 'Hammer', category: 'Hand Tools' });
  await repos.items.create({ containerId: drawer.id, name: 'Whisk', category: 'Utensils' });

  return { repos, garage, kitchen, toolBox, drawer };
}

describe('search', () => {
  it('returns nothing for an empty query', async () => {
    const { repos } = await seedInventory();
    const results = await repos.search.search('   ');
    expect(results).toEqual({ terms: [], locations: [], items: [] });
  });

  it('matches USB-C when the query omits the hyphen', async () => {
    const { repos, toolBox } = await seedInventory();
    await repos.items.create({
      containerId: toolBox.id,
      name: 'USB-C to USB-A cable',
      category: 'Cables',
    });

    expect((await repos.search.search('usbc')).items.map((item) => item.name)).toEqual([
      'USB-C to USB-A cable',
    ]);
    expect((await repos.search.search('usb-c')).items.map((item) => item.name)).toEqual([
      'USB-C to USB-A cable',
    ]);

    await repos.items.create({
      containerId: toolBox.id,
      name: 'Microusb cable',
      category: 'Cables',
    });
    expect((await repos.search.search('usbc')).items.map((item) => item.name)).toEqual([
      'USB-C to USB-A cable',
    ]);
  });

  it('matches an item by name, case-insensitively', async () => {
    const { repos } = await seedInventory();
    const results = await repos.search.search('DRILL');

    expect(results.items.map((item) => item.name)).toEqual(['Cordless Drill']);
    expect(results.items[0]?.matchKind).toBe('direct');
  });

  it('carries the space icon and colour so a result can be placed at a glance', async () => {
    const { repos } = await seedInventory();
    const results = await repos.search.search('DRILL');

    expect(results.items[0]?.spaceName).toBe('Garage');
    expect(results.items[0]?.spaceIcon).toBe('car');
    expect(results.items[0]?.spaceColor).toBe('#5B8DEF');
  });

  it('matches by category and by tag', async () => {
    const { repos } = await seedInventory();

    expect((await repos.search.search('power tools')).items).toHaveLength(1);
    expect((await repos.search.search('dewalt')).items.map((i) => i.name)).toEqual([
      'Cordless Drill',
    ]);
    expect((await repos.search.search('18v')).items).toHaveLength(1);
  });

  it('includes items found through their space and marks them as location matches', async () => {
    const { repos } = await seedInventory();
    const results = await repos.search.search('kitchen');

    expect(results.items.map((item) => item.name)).toEqual(['Whisk']);
    expect(results.items[0]?.matchKind).toBe('location');
  });

  it('lists matching spaces and containers in a separate locations section', async () => {
    const { repos } = await seedInventory();
    const results = await repos.search.search('garage');

    expect(results.locations.map((location) => location.kind)).toContain('space');
    expect(results.locations[0]?.title).toBe('Garage');
  });

  it('finds a container by its short code, with or without the dash', async () => {
    const { repos, toolBox } = await seedInventory();

    const withDash = await repos.search.search(toolBox.shortCode);
    const withoutDash = await repos.search.search(toolBox.shortCode.replace('-', ''));

    expect(withDash.locations.some((l) => l.id === toolBox.id)).toBe(true);
    expect(withoutDash.locations.some((l) => l.id === toolBox.id)).toBe(true);
  });

  it('combines an item term with a location term', async () => {
    const { repos } = await seedInventory();

    // "drill" matches the item; "garage" matches only its space.
    const results = await repos.search.search('garage drill');

    expect(results.items.map((item) => item.name)).toEqual(['Cordless Drill']);
  });

  it('requires every term to match somewhere', async () => {
    const { repos } = await seedInventory();
    const results = await repos.search.search('drill kitchen');
    expect(results.items).toEqual([]);
  });

  it('ranks direct item matches above location-only matches', async () => {
    const { repos, garage } = await seedInventory();
    const box = await repos.containers.create({
      spaceId: garage.id,
      visualType: 'bin',
      name: 'Spare Parts',
    });
    await repos.items.create({ containerId: box.id, name: 'Garage Door Remote' });

    const results = await repos.search.search('garage');

    expect(results.items[0]?.name).toBe('Garage Door Remote');
    expect(results.items[0]?.matchKind).toBe('direct');
  });

  it('treats LIKE wildcards in the query as literal characters', async () => {
    const { repos } = await seedInventory();
    // Without escaping, "%" would match every item in the inventory.
    expect((await repos.search.search('%')).items).toEqual([]);
    expect((await repos.search.search('_')).items).toEqual([]);
  });

  it('reflects edits and deletions without any cache to invalidate', async () => {
    const { repos, toolBox } = await seedInventory();
    const [item] = await repos.items.listByContainer(toolBox.id);

    await repos.items.update(item!.id, { name: 'Angle Grinder' });
    expect((await repos.search.search('grinder')).items).toHaveLength(1);

    await repos.items.delete(item!.id);
    expect((await repos.search.search('grinder')).items).toHaveLength(0);
  });

  it('formats the Space > Container path shown on each result', async () => {
    const { repos } = await seedInventory();
    const results = await repos.search.search('drill');
    expect(formatLocationPath(results.items[0]!)).toBe('Garage > Tool Box');
  });

  it('falls back to the short code when a container has no name', async () => {
    const { repos, garage } = await seedInventory();
    const unnamed = await repos.containers.create({ spaceId: garage.id, visualType: 'crate' });
    await repos.items.create({ containerId: unnamed.id, name: 'Tent Pegs' });

    const results = await repos.search.search('tent');
    expect(formatLocationPath(results.items[0]!)).toBe(`Garage > ${unnamed.shortCode}`);
  });
});

describe('search performance', () => {
  /**
   * Issue #14 requires search to stay responsive at 10,000 items. This is a
   * coarse guard against an accidental O(n) regression (a dropped index, a
   * per-row LOWER()), not a device benchmark.
   */
  it('stays responsive with 10,000 items', async () => {
    const repos: Repositories = await initializeRepositories(openNodeDatabase());
    const space = await repos.spaces.create({ name: 'Warehouse', icon: 'box', color: '#5B8DEF' });
    const container = await repos.containers.create({ spaceId: space.id, visualType: 'shelf' });

    await repos.db.withTransactionAsync(async () => {
      for (let i = 0; i < 10_000; i += 1) {
        await repos.db.runAsync(
          `INSERT INTO items (id, container_id, name, category, quantity, created_at,
                              updated_at, search_text)
           VALUES (?, ?, ?, ?, 1, ?, ?, ?)`,
          [
            `item-${i}`,
            container.id,
            `Widget ${i}`,
            'Parts',
            Date.now(),
            Date.now(),
            `widget ${i} parts`,
          ],
        );
      }
    });

    expect(await repos.items.countAll()).toBe(10_000);

    const started = process.hrtime.bigint();
    const results = await repos.search.search('widget 4242');
    const elapsedMs = Number(process.hrtime.bigint() - started) / 1_000_000;

    expect(results.items.map((item) => item.name)).toEqual(['Widget 4242']);
    expect(elapsedMs).toBeLessThan(1000);
  }, 60_000);
});
