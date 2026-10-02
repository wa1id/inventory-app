import { HouseholdHttpError } from '@/services/household/client';
import {
  byContainerLabel,
  containerDeleteBody,
  containerLabel,
  containerValuesChanged,
  isNameTaken,
  isOffline,
  labelsInSpace,
  needsRefreshBanner,
  spaceDeleteBody,
  spaceValuesChanged,
  takenSpaceNames,
} from '@/ui/spaces/spaceSetup';

describe('containerLabel and byContainerLabel', () => {
  it('reads a container by its name, or by its code when it has none', () => {
    expect(containerLabel({ name: 'Tool chest', shortCode: 'CAB-J92R' })).toBe('Tool chest');
    expect(containerLabel({ name: null, shortCode: 'CAB-J92R' })).toBe('CAB-J92R');
  });

  it('sorts by label without regard to case or accents, codes alongside names', () => {
    const containers = [
      { name: 'drawer by the oven', shortCode: 'DRW-7K2M' },
      { name: null, shortCode: 'BOX-4F2A' },
      { name: 'Étagère', shortCode: 'SHF-2222' },
      { name: 'Attic box', shortCode: 'BOX-9999' },
    ];
    expect([...containers].sort(byContainerLabel).map(containerLabel)).toEqual([
      'Attic box',
      'BOX-4F2A',
      'drawer by the oven',
      'Étagère',
    ]);
  });
});

describe('taken space names', () => {
  it('finds a preset name already used, ignoring case and surrounding spaces', () => {
    const taken = takenSpaceNames([{ name: ' garage ' }, { name: 'Kitchen' }]);
    expect(isNameTaken('Garage', taken)).toBe(true);
    expect(isNameTaken('KITCHEN', taken)).toBe(true);
    expect(isNameTaken('Loft', taken)).toBe(false);
  });
});

describe('labelsInSpace', () => {
  it('counts linked containers when the impact reports none (paired)', () => {
    expect(labelsInSpace(0, [{ qrToken: 'a' }, { qrToken: null }, { qrToken: 'b' }])).toBe(2);
  });

  it('keeps the impact count when it is the larger (local)', () => {
    expect(labelsInSpace(3, [{ qrToken: 'a' }])).toBe(3);
  });
});

describe('delete confirm bodies', () => {
  it('spells out what a space takes with it', () => {
    expect(spaceDeleteBody({ containerCount: 3, itemCount: 21 }, 2)).toBe(
      'This also deletes 3 containers and 21 items, and unlinks 2 QR labels. This cannot be undone.',
    );
    expect(spaceDeleteBody({ containerCount: 1, itemCount: 1 }, 0)).toBe(
      'This also deletes 1 container and 1 item. This cannot be undone.',
    );
    expect(spaceDeleteBody({ containerCount: 1, itemCount: 0 }, 1)).toBe(
      'This also deletes 1 container and 0 items, and unlinks 1 QR label. This cannot be undone.',
    );
  });

  it('says so when a space is empty', () => {
    expect(spaceDeleteBody({ containerCount: 0, itemCount: 0 }, 0)).toBe('This space is empty.');
  });

  it('spells out what a container takes with it', () => {
    expect(containerDeleteBody({ itemCount: 5, hasQrBinding: true })).toBe(
      'This also deletes 5 items and unlinks its QR label. This cannot be undone.',
    );
    expect(containerDeleteBody({ itemCount: 1, hasQrBinding: false })).toBe(
      'This also deletes 1 item. This cannot be undone.',
    );
    expect(containerDeleteBody({ itemCount: 0, hasQrBinding: true })).toBe(
      'This container is empty. Its QR label will be unlinked.',
    );
    expect(containerDeleteBody({ itemCount: 0, hasQrBinding: false })).toBe(
      'This container is empty.',
    );
  });
});

describe('spaceValuesChanged', () => {
  const initial = { name: 'Garage', icon: '🚗', color: '#5B8DEF' };

  it('ignores spaces the repository would trim anyway', () => {
    expect(spaceValuesChanged({ ...initial, name: ' Garage ' }, initial)).toBe(false);
  });

  it('notices any real change', () => {
    expect(spaceValuesChanged({ ...initial, name: 'Shed' }, initial)).toBe(true);
    expect(spaceValuesChanged({ ...initial, icon: '🧰' }, initial)).toBe(true);
    expect(spaceValuesChanged({ ...initial, color: '#2E9E4F' }, initial)).toBe(true);
  });
});

describe('containerValuesChanged', () => {
  const initial = { name: 'Tool chest', visualType: 'cabinet', spaceId: 'garage' };

  it('ignores surrounding spaces in the name', () => {
    expect(containerValuesChanged({ ...initial, name: 'Tool chest ' }, initial)).toBe(false);
  });

  it('notices a new name, an emptied name, a new type and a new space', () => {
    expect(containerValuesChanged({ ...initial, name: 'Red chest' }, initial)).toBe(true);
    expect(containerValuesChanged({ ...initial, name: '' }, initial)).toBe(true);
    expect(containerValuesChanged({ ...initial, visualType: 'box' }, initial)).toBe(true);
    expect(containerValuesChanged({ ...initial, spaceId: 'loft' }, initial)).toBe(true);
  });
});

describe('needsRefreshBanner and isOffline', () => {
  const offline = new HouseholdHttpError(0, 'offline');
  const removed = new HouseholdHttpError(401, 'unauthorized');
  const server = new HouseholdHttpError(500, 'http_500');

  it('leaves offline and removed phones to their own banner and layer', () => {
    expect(needsRefreshBanner(true, offline)).toBe(false);
    expect(needsRefreshBanner(true, removed)).toBe(false);
  });

  it('explains any other failed refresh, and nothing when the refresh worked', () => {
    expect(needsRefreshBanner(true, server)).toBe(true);
    expect(needsRefreshBanner(true, new Error('disk I/O error'))).toBe(true);
    expect(needsRefreshBanner(false, server)).toBe(false);
  });

  it('tells a connection failure from any other', () => {
    expect(isOffline(offline)).toBe(true);
    expect(isOffline(new HouseholdHttpError(530, 'http_530'))).toBe(true);
    expect(isOffline(server)).toBe(false);
    expect(isOffline(new Error('constraint failed'))).toBe(false);
  });
});
