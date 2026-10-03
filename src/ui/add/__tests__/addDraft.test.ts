import {
  DRAFT_TTL_MS,
  clearDraft,
  discardStaleDraft,
  keepDraft,
  restorableDraft,
  type AddDraft,
} from '@/ui/add/addDraft';
import { deleteStoredPhotos } from '@/services/capture/imageStore';

jest.mock('@/services/capture/imageStore', () => ({ deleteStoredPhotos: jest.fn() }));

const deleted = deleteStoredPhotos as jest.MockedFunction<typeof deleteStoredPhotos>;

function draft(overrides: Partial<AddDraft> = {}): AddDraft {
  return {
    values: { name: 'Torch', category: '', tags: '', quantity: '1', notes: '' },
    placeId: 'drop-zone',
    picked: null,
    photo: null,
    suggestion: { status: 'idle' },
    showMore: false,
    savedAt: 1000,
    ...overrides,
  };
}

const photo = { uri: 'file:///p.webp', thumbUri: 'file:///p-thumb.webp' };

beforeEach(() => {
  // Empty the slot between tests: whoever wrote it clears it.
  keepDraft('reset', draft());
  clearDraft('reset');
  deleted.mockClear();
});

describe('addDraft', () => {
  it('restores a draft for half an hour, then not', () => {
    const kept = draft();
    keepDraft('a', kept);
    expect(restorableDraft(1000 + DRAFT_TTL_MS)).toBe(kept);
    expect(restorableDraft(1000 + DRAFT_TTL_MS + 1)).toBeNull();
  });

  it('deletes a stale draft’s photo, both files, and leaves a fresh one', () => {
    keepDraft('a', draft({ photo }));
    discardStaleDraft(2000);
    expect(deleted).not.toHaveBeenCalled();
    expect(restorableDraft(2000)).not.toBeNull();

    discardStaleDraft(1000 + DRAFT_TTL_MS + 1);
    expect(deleted).toHaveBeenCalledWith([photo.uri, photo.thumbUri]);
    expect(restorableDraft(1000)).toBeNull();
  });

  it('deletes a replaced draft’s photo unless the new draft carries it', () => {
    keepDraft('a', draft({ photo }));
    keepDraft('b', draft({ photo }));
    expect(deleted).not.toHaveBeenCalled();

    keepDraft('c', draft({ values: { ...draft().values, name: 'Glue' } }));
    expect(deleted).toHaveBeenCalledWith([photo.uri, photo.thumbUri]);
  });

  it('lets only the sheet that wrote the draft clear it', () => {
    keepDraft('a', draft());
    keepDraft('b', null);
    clearDraft('b');
    expect(restorableDraft(1000)).not.toBeNull();

    keepDraft('a', null);
    expect(restorableDraft(1000)).toBeNull();

    keepDraft('a', draft({ photo }));
    clearDraft('a');
    expect(restorableDraft(1000)).toBeNull();
    // After a save the item owns the photo.
    expect(deleted).not.toHaveBeenCalled();
  });
});
