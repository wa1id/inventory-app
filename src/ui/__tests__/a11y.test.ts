import { DROP_ZONE_CONTAINER_ID, DROP_ZONE_SPACE_ID } from '@/db/constants';
import { quantitySpoken, spellCode, whereSpoken, type PlaceLike } from '@/ui/a11y';

const filed: PlaceLike = {
  containerId: 'c1',
  containerName: 'Tool chest',
  containerShortCode: 'CAB-J92R',
  spaceId: 's1',
  spaceName: 'Garage',
  spaceColor: '#5B8DEF',
};

describe('spellCode', () => {
  it('spaces the characters and pauses between groups', () => {
    expect(spellCode('DRW-7K2M')).toBe('D R W, 7 K 2 M');
  });

  it('copes with a code without groups and with stray hyphens', () => {
    expect(spellCode('BOX1')).toBe('B O X 1');
    expect(spellCode('-AB--C-')).toBe('A B, C');
  });
});

describe('whereSpoken', () => {
  it('names the space, the container and the spelled label', () => {
    expect(whereSpoken(filed)).toBe('In Garage, Tool chest, label C A B, J 9 2 R');
  });

  it('leaves out an unnamed container', () => {
    expect(whereSpoken({ ...filed, containerName: null })).toBe('In Garage, label C A B, J 9 2 R');
  });

  it('never reads the drop zone’s internal code', () => {
    expect(
      whereSpoken({
        ...filed,
        containerId: DROP_ZONE_CONTAINER_ID,
        containerName: 'Drop zone',
        containerShortCode: 'DROP-ZONE',
        spaceId: DROP_ZONE_SPACE_ID,
        spaceName: 'Drop zone',
      }),
    ).toBe('In the drop zone, not filed yet');
  });
});

describe('quantitySpoken', () => {
  it('says "None left" at zero', () => {
    expect(quantitySpoken(0)).toBe('None left');
    expect(quantitySpoken(12)).toBe('Quantity 12');
  });
});
