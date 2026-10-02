import { compact, filterPlaces, matchesPlace, placeTerms } from '@/ui/placeMatch';

const drawer = {
  id: 'c1',
  name: 'Drawer by the oven',
  shortCode: 'DRW-7K2M',
  spaceName: 'Kitchen',
  visualType: 'drawer',
};
const toolChest = {
  id: 'c2',
  name: 'Tool chest',
  shortCode: 'CAB-J92R',
  spaceName: 'Garage',
  visualType: 'cabinet',
};
const unnamedBox = {
  id: 'c3',
  name: null,
  shortCode: 'BOX-4F2A',
  spaceName: 'Loft',
  visualType: 'box',
};

describe('compact', () => {
  it('drops case, spaces and punctuation', () => {
    expect(compact('DRW-7K2M')).toBe('drw7k2m');
    expect(compact(' Tool  chest! ')).toBe('toolchest');
  });
});

describe('placeTerms', () => {
  it('splits on whitespace and drops terms that compact to nothing', () => {
    expect(placeTerms('  drw-7k  garage - ')).toEqual(['drw7k', 'garage']);
    expect(placeTerms('')).toEqual([]);
  });
});

describe('matchesPlace', () => {
  it('finds a label code typed without its hyphen', () => {
    expect(matchesPlace(drawer, placeTerms('drw7k'))).toBe(true);
    expect(matchesPlace(drawer, placeTerms('DRW-7K2M'))).toBe(true);
  });

  it('matches the space name and the type name', () => {
    expect(matchesPlace(toolChest, placeTerms('garage'))).toBe(true);
    expect(matchesPlace(toolChest, placeTerms('cabinet'))).toBe(true);
    expect(matchesPlace(unnamedBox, placeTerms('loft box'))).toBe(true);
  });

  it('needs every term to match', () => {
    expect(matchesPlace(drawer, placeTerms('kitchen oven'))).toBe(true);
    expect(matchesPlace(drawer, placeTerms('kitchen garage'))).toBe(false);
  });

  it('matches everything when nothing is typed', () => {
    expect(matchesPlace(unnamedBox, [])).toBe(true);
  });
});

describe('filterPlaces', () => {
  it('keeps the matching options in their order', () => {
    const options = [drawer, toolChest, unnamedBox];
    expect(filterPlaces(options, 'o').map((option) => option.id)).toEqual(['c1', 'c2', 'c3']);
    expect(filterPlaces(options, 'box').map((option) => option.id)).toEqual(['c3']);
    expect(filterPlaces(options, '  ')).toEqual(options);
  });
});
