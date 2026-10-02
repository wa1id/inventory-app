import {
  compact,
  joinPlaceOptions,
  matchesPlace,
  placeTerms,
  toPlaceOption,
} from '@/ui/placeMatch';

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

  it('folds accents and keeps letters of any script, like Home search', () => {
    expect(compact('Küche')).toBe('kuche');
    expect(compact('Кухня')).toBe('кухня');
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

describe('matchesPlace beyond ASCII', () => {
  const kitchen = { name: 'Küche', shortCode: 'DRW-1K2M', spaceName: 'Haus', visualType: 'drawer' };
  const cyrillic = { name: 'Кухня', shortCode: 'BOX-4F2A', spaceName: 'Дом', visualType: 'box' };

  it('finds an accented name typed with or without the accent', () => {
    expect(matchesPlace(kitchen, placeTerms('kuche'))).toBe(true);
    expect(matchesPlace(kitchen, placeTerms('Küche'))).toBe(true);
  });

  it('finds a name in another script, and does not match everything', () => {
    expect(placeTerms('кухня')).not.toEqual([]);
    expect(matchesPlace(cyrillic, placeTerms('кух'))).toBe(true);
    expect(matchesPlace(drawer, placeTerms('кухня'))).toBe(false);
  });
});

describe('joinPlaceOptions', () => {
  it('adds each container’s space colour and icon', () => {
    const [joined] = joinPlaceOptions(
      [
        {
          id: 'c1',
          spaceId: 's1',
          name: null,
          visualType: 'drawer',
          shortCode: 'DRW-1',
          createdAt: 0,
          updatedAt: 0,
          spaceName: 'Kitchen',
          itemCount: 3,
        },
      ],
      [{ id: 's1', color: '#2E9E4F', icon: '🍳' }],
    );
    expect(joined).toEqual({
      id: 'c1',
      name: null,
      shortCode: 'DRW-1',
      visualType: 'drawer',
      spaceId: 's1',
      spaceName: 'Kitchen',
      spaceColor: '#2E9E4F',
      spaceIcon: '🍳',
      itemCount: 3,
    });
  });
});

describe('toPlaceOption', () => {
  it('gives no colour or icon for a space not known yet', () => {
    const option = toPlaceOption(
      {
        id: 'c9',
        name: 'Crate',
        shortCode: 'CRT-9X',
        visualType: 'crate',
        spaceId: 's9',
        spaceName: 'Shed',
        itemCount: 0,
      },
      undefined,
    );
    expect(option.spaceColor).toBe('');
    expect(option.spaceIcon).toBe('');
    expect(option.spaceName).toBe('Shed');
  });
});
