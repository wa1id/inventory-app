import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import {
  containerTitle,
  formHasContent,
  hasDetails,
  initialAddState,
  joinPlaceOptions,
  photoFiles,
  photoFromParams,
  photoFromStored,
  resolvePlace,
  saveA11yLabel,
  savedMessage,
  toPositiveInt,
  whereEntries,
  type AddDraftState,
} from '@/ui/add/addSheet';
import type { ItemFormValues } from '@/ui/components/ItemForm';
import type { PlaceOption } from '@/ui/components/PlacePicker';

const EMPTY: ItemFormValues = { name: '', category: '', tags: '', quantity: '1', notes: '' };

function option(id: string, overrides: Partial<PlaceOption> = {}): PlaceOption {
  return {
    id,
    name: `Container ${id}`,
    shortCode: `BOX-${id.toUpperCase()}`,
    visualType: 'box',
    spaceId: 'kitchen',
    spaceName: 'Kitchen',
    spaceColor: '#5B8DEF',
    spaceIcon: '🍳',
    itemCount: 0,
    ...overrides,
  };
}

const drawer = option('drawer', { name: 'Drawer by the oven', shortCode: 'DRW-7K2M' });
const shelf = option('shelf', { name: 'Shelf A', spaceName: 'Garage' });

describe('params', () => {
  it('reads positive whole numbers only', () => {
    expect(toPositiveInt('1400')).toBe(1400);
    expect(toPositiveInt(undefined)).toBeUndefined();
    expect(toPositiveInt('')).toBeUndefined();
    expect(toPositiveInt('0')).toBeUndefined();
    expect(toPositiveInt('-3')).toBeUndefined();
    expect(toPositiveInt('2.5')).toBeUndefined();
    expect(toPositiveInt('wide')).toBeUndefined();
  });

  it('turns capture params into a photo', () => {
    expect(photoFromParams({})).toBeNull();
    expect(
      photoFromParams({
        photoUri: 'file:///p.webp',
        photoThumbUri: 'file:///p-thumb.webp',
        photoWidth: '1400',
        photoHeight: '1050',
        photoBytes: 'x',
      }),
    ).toEqual({
      uri: 'file:///p.webp',
      thumbUri: 'file:///p-thumb.webp',
      width: 1400,
      height: 1050,
      byteSize: undefined,
    });
  });

  it('takes a stored camera photo, dropping an unknown size', () => {
    expect(
      photoFromStored({ uri: 'a', thumbUri: 'b', width: 10, height: 20, byteSize: null }),
    ).toEqual({ uri: 'a', thumbUri: 'b', width: 10, height: 20, byteSize: undefined });
  });

  it('lists both files of a photo, so the thumbnail is never left behind', () => {
    expect(photoFiles(null)).toEqual([]);
    expect(photoFiles({ uri: 'a', thumbUri: 'b' })).toEqual(['a', 'b']);
    expect(photoFiles({ uri: 'a' })).toEqual(['a', null]);
  });
});

describe('content', () => {
  it('counts typing, a changed quantity and a photo, not blanks', () => {
    expect(formHasContent(EMPTY, null, EMPTY)).toBe(false);
    expect(formHasContent({ ...EMPTY, name: '   ' }, null, EMPTY)).toBe(false);
    expect(formHasContent({ ...EMPTY, name: 'AA batteries' }, null, EMPTY)).toBe(true);
    expect(formHasContent({ ...EMPTY, notes: 'spare' }, null, EMPTY)).toBe(true);
    expect(formHasContent({ ...EMPTY, quantity: '0' }, null, EMPTY)).toBe(true);
    expect(formHasContent(EMPTY, { uri: 'a' }, EMPTY)).toBe(true);
  });

  it('opens the details when any of them holds something', () => {
    expect(hasDetails(EMPTY)).toBe(false);
    expect(hasDetails({ ...EMPTY, name: 'Drill' })).toBe(false);
    expect(hasDetails({ ...EMPTY, tags: 'garage' })).toBe(true);
  });
});

describe('initialAddState', () => {
  const draft: AddDraftState = {
    values: { ...EMPTY, name: 'Torch' },
    placeId: 'shelf',
    picked: shelf,
    photo: null,
    suggestion: { status: 'idle' },
    showMore: false,
  };

  it('starts empty in the drop zone from the tab bar', () => {
    expect(initialAddState({}, null, EMPTY)).toEqual({
      values: EMPTY,
      placeId: DROP_ZONE_CONTAINER_ID,
      picked: null,
      photo: null,
      suggestion: { status: 'idle' },
      showMore: false,
      restored: false,
      recognize: false,
    });
  });

  it('starts in the container it was opened for, with a name from search', () => {
    const state = initialAddState({ containerId: 'drawer', name: 'AA batteries' }, null, EMPTY);
    expect(state.placeId).toBe('drawer');
    expect(state.values.name).toBe('AA batteries');
  });

  it('recognises a photo from the camera on arrival', () => {
    const state = initialAddState({ containerId: 'drawer', photoUri: 'p' }, null, EMPTY);
    expect(state.photo).toEqual(expect.objectContaining({ uri: 'p' }));
    expect(state.suggestion).toEqual({ status: 'running' });
    expect(state.recognize).toBe(true);
  });

  it('restores a draft only on a plain open', () => {
    expect(initialAddState({}, draft, EMPTY)).toEqual({
      ...draft,
      restored: true,
      recognize: false,
    });
    expect(initialAddState({ containerId: 'drawer' }, draft, EMPTY).restored).toBe(false);
    expect(initialAddState({ name: 'Glue' }, draft, EMPTY).values.name).toBe('Glue');
  });

  it('restarts recognition that was cut off, and drops it without a photo', () => {
    const running = initialAddState(
      {},
      { ...draft, photo: { uri: 'p' }, suggestion: { status: 'refreshing' } },
      EMPTY,
    );
    expect(running.suggestion).toEqual({ status: 'running' });
    expect(running.recognize).toBe(true);

    const orphan = initialAddState({}, { ...draft, suggestion: { status: 'running' } }, EMPTY);
    expect(orphan.suggestion).toEqual({ status: 'idle' });
    expect(orphan.recognize).toBe(false);
  });

  it('keeps an applied suggestion as it was', () => {
    const applied = { status: 'applied', confidence: 0.8, forName: 'Torch' } as const;
    const state = initialAddState(
      {},
      { ...draft, photo: { uri: 'p' }, suggestion: applied },
      EMPTY,
    );
    expect(state.suggestion).toEqual(applied);
    expect(state.recognize).toBe(false);
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

describe('whereEntries', () => {
  const options = new Map(
    [drawer, shelf, option('bin'), option('bag'), option('crate')].map((o) => [o.id, o]),
  );
  const ids = (entries: ReturnType<typeof whereEntries>) =>
    entries.map((entry) =>
      entry.kind === 'dropZone' ? 'drop' : `${entry.source}:${entry.option.id}`,
    );

  it('offers the drop zone and up to three recent places that still exist', () => {
    expect(
      ids(
        whereEntries({
          param: null,
          recentIds: ['gone', 'shelf', DROP_ZONE_CONTAINER_ID, 'bin', 'bag', 'crate'],
          options,
          selectedId: DROP_ZONE_CONTAINER_ID,
          picked: null,
        }),
      ),
    ).toEqual(['drop', 'recent:shelf', 'recent:bin', 'recent:bag']);
  });

  it('puts the container it was opened for first, without repeating it', () => {
    expect(
      ids(
        whereEntries({
          param: drawer,
          recentIds: ['drawer', 'shelf'],
          options,
          selectedId: 'drawer',
          picked: null,
        }),
      ),
    ).toEqual(['param:drawer', 'drop', 'recent:shelf']);
  });

  it('shows a place picked from the full list on top', () => {
    const fresh = option('new', { name: 'Just made' });
    expect(
      ids(
        whereEntries({
          param: null,
          recentIds: ['shelf'],
          options,
          selectedId: 'new',
          picked: fresh,
        }),
      ),
    ).toEqual(['picked:new', 'drop', 'recent:shelf']);
    expect(
      ids(whereEntries({ param: null, recentIds: [], options, selectedId: 'crate', picked: null })),
    ).toEqual(['picked:crate', 'drop']);
  });

  it('keeps a picked place listed after choosing another one', () => {
    const fresh = option('new', { name: 'Just made' });
    expect(
      ids(
        whereEntries({
          param: null,
          recentIds: ['shelf'],
          options,
          selectedId: DROP_ZONE_CONTAINER_ID,
          picked: fresh,
        }),
      ),
    ).toEqual(['picked:new', 'drop', 'recent:shelf']);
    expect(
      ids(
        whereEntries({ param: null, recentIds: [], options, selectedId: 'crate', picked: fresh }),
      ),
    ).toEqual(['picked:crate', 'picked:new', 'drop']);
  });

  it('does not repeat a picked place that is already listed', () => {
    expect(
      ids(
        whereEntries({
          param: null,
          recentIds: ['shelf'],
          options,
          selectedId: 'shelf',
          picked: shelf,
        }),
      ),
    ).toEqual(['drop', 'recent:shelf']);
  });
});

describe('resolvePlace', () => {
  const options = new Map([[drawer.id, drawer]]);

  it('knows the drop zone and listed containers', () => {
    expect(resolvePlace(DROP_ZONE_CONTAINER_ID, null, null)).toEqual({
      id: DROP_ZONE_CONTAINER_ID,
      option: null,
    });
    expect(resolvePlace('drawer', options, null)).toEqual({ id: 'drawer', option: drawer });
  });

  it('keeps the id while the list loads, and a container just made', () => {
    expect(resolvePlace('drawer', null, null)).toEqual({ id: 'drawer', option: null });
    const fresh = option('new');
    expect(resolvePlace('new', options, fresh)).toEqual({ id: 'new', option: fresh });
  });

  it('falls back to the drop zone for a container that is gone', () => {
    expect(resolvePlace('gone', options, null)).toEqual({
      id: DROP_ZONE_CONTAINER_ID,
      option: null,
    });
  });
});

describe('labels', () => {
  const unnamed = option('u', { name: null, shortCode: 'BIN-4F2A', spaceName: 'Loft' });

  it('names a container by its name, or the code on its label', () => {
    expect(containerTitle(drawer)).toBe('Drawer by the oven');
    expect(containerTitle(unnamed)).toBe('BIN-4F2A');
  });

  it('says where Save puts the item', () => {
    expect(saveA11yLabel({ id: DROP_ZONE_CONTAINER_ID, option: null })).toBe(
      'Save to the drop zone',
    );
    expect(saveA11yLabel({ id: 'drawer', option: drawer })).toBe(
      'Save in Drawer by the oven, Kitchen',
    );
    expect(saveA11yLabel({ id: 'u', option: unnamed })).toBe('Save in label B I N, 4 F 2 A, Loft');
    expect(saveA11yLabel({ id: 'drawer', option: null })).toBe('Save');
  });

  it('reports where it was saved', () => {
    expect(savedMessage({ id: DROP_ZONE_CONTAINER_ID, option: null })).toBe(
      'Saved in the drop zone.',
    );
    expect(savedMessage({ id: 'drawer', option: drawer })).toBe(
      'Saved in Drawer by the oven (Kitchen).',
    );
    expect(savedMessage({ id: 'u', option: unnamed })).toBe('Saved in BIN-4F2A (Loft).');
    expect(savedMessage({ id: 'drawer', option: null })).toBe('Saved.');
  });
});
