import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { summarizeSession } from '@/services/capture/fastReview';
import {
  containerLabel,
  expectedStillShown,
  fastStatus,
  hideRow,
  intoA11y,
  isPermissionError,
  leaveCamera,
  reviewDoneToast,
  reviewStatus,
  reviewStatusText,
  reviewTitle,
  sessionSignature,
  visibleRows,
  withLanded,
} from '@/ui/capture/captureFlow';

const place = {
  containerId: 'c1',
  containerName: 'Tool chest',
  containerShortCode: 'CAB-J92R',
  spaceId: 's1',
  spaceName: 'Garage',
  spaceColor: '#5B8DEF',
};

describe('fastStatus', () => {
  it('counts what is still on its way first', () => {
    expect(fastStatus({ captured: 3, completed: 1, recognized: 1 })).toEqual({
      text: 'Identifying 2…',
      settled: false,
    });
  });

  it('keeps identified, unnamed and saved apart once everything has landed', () => {
    expect(fastStatus({ captured: 3, completed: 3, recognized: 3 }).text).toBe('3 identified');
    expect(fastStatus({ captured: 3, completed: 3, recognized: 1 }).text).toBe(
      '1 identified · 2 to name',
    );
    expect(fastStatus({ captured: 2, completed: 2, recognized: 0 }).text).toBe(
      '2 saved · name them later',
    );
    expect(fastStatus({ captured: 1, completed: 1, recognized: 0 }).text).toBe(
      '1 saved · name it later',
    );
  });

  it('never shows a tick the font does not have', () => {
    expect(fastStatus({ captured: 2, completed: 2, recognized: 2 }).text).not.toContain('✓');
    expect(fastStatus({ captured: 2, completed: 2, recognized: 2 }).settled).toBe(true);
  });
});

describe('leaveCamera', () => {
  it('sends a fast set with shots to the review, so it cannot be skipped', () => {
    expect(leaveCamera('fast', 2)).toBe('review');
  });

  it('just closes otherwise', () => {
    expect(leaveCamera('fast', 0)).toBe('back');
    expect(leaveCamera('single', 0)).toBe('back');
    expect(leaveCamera('single', 3)).toBe('back');
  });
});

describe('intoA11y', () => {
  it('names the container, its space and its spelled label', () => {
    expect(intoA11y('c1', place)).toBe(
      'Photos go into Tool chest, in Garage, label C A B, J 9 2 R',
    );
  });

  it('falls back to the label for an unnamed container', () => {
    expect(intoA11y('c1', { ...place, containerName: null })).toBe(
      'Photos go into the container in Garage, label C A B, J 9 2 R',
    );
  });

  it('says drop zone for the drop zone and while the place is unknown', () => {
    expect(intoA11y(DROP_ZONE_CONTAINER_ID, null)).toBe('Photos go into the drop zone');
    expect(intoA11y(DROP_ZONE_CONTAINER_ID, place)).toBe('Photos go into the drop zone');
  });
});

describe('isPermissionError', () => {
  it('spots a refused photo library by code or message', () => {
    const coded = Object.assign(new Error('Nope'), { code: 'ERR_NO_PERMISSIONS' });
    expect(isPermissionError(coded)).toBe(true);
    expect(isPermissionError(new Error('Missing photo library permission'))).toBe(true);
  });

  it('treats anything else as a photo that could not be opened', () => {
    expect(isPermissionError(new Error('Could not decode'))).toBe(false);
    expect(isPermissionError('permission')).toBe(false);
    expect(isPermissionError(null)).toBe(false);
  });
});

function row(id: string, name: string, createdAt = 1, updatedAt = createdAt) {
  return {
    id,
    name,
    updatedAt,
    createdAt,
    containerName: 'Tool chest' as string | null,
    containerShortCode: 'CAB-J92R',
  };
}

describe('reviewStatus', () => {
  it('says "Saving N more…" while photos are still landing', () => {
    const summary = { saved: 1, named: 1, unnamed: 0, pending: 2 };
    expect(reviewStatus(summary, false)).toBe('pending');
    expect(reviewStatusText('pending', summary)).toBe('Saving 2 more…');
  });

  it('stops promising once the set has gone quiet', () => {
    const summary = { saved: 1, named: 1, unnamed: 0, pending: 2 };
    expect(reviewStatus(summary, true)).toBe('maybeLost');
    expect(reviewStatusText('maybeLost', summary)).toBe('Some photos may not have been saved.');
  });

  it('counts what still needs a name, or says all are named', () => {
    const two = { saved: 3, named: 1, unnamed: 2, pending: 0 };
    expect(reviewStatus(two, true)).toBe('toName');
    expect(reviewStatusText('toName', two)).toBe('2 still need a name');
    expect(reviewStatusText('toName', { ...two, unnamed: 1 })).toBe('1 still needs a name');
    const named = { saved: 3, named: 3, unnamed: 0, pending: 0 };
    expect(reviewStatus(named, false)).toBe('allNamed');
    expect(reviewStatusText('allNamed', named)).toBe('All named');
  });

  it('works on what summarizeSession reports', () => {
    const items = [row('a', 'Drill'), row('b', '')] as never[];
    expect(reviewStatus(summarizeSession(items, 2), false)).toBe('toName');
  });
});

describe('review title and toast', () => {
  it('names the container by name, or by its code when unnamed', () => {
    expect(containerLabel([row('a', 'Drill')])).toBe('Tool chest');
    expect(containerLabel([{ ...row('a', 'Drill'), containerName: null }])).toBe('CAB-J92R');
    expect(containerLabel([])).toBeNull();
  });

  it('says where the set went', () => {
    const four = { saved: 4, named: 3, unnamed: 1, pending: 0 };
    expect(reviewTitle(four, 'toName', DROP_ZONE_CONTAINER_ID, null)).toBe(
      '4 saved to the drop zone',
    );
    const one = { saved: 1, named: 1, unnamed: 0, pending: 0 };
    expect(reviewTitle(one, 'allNamed', 'c1', 'Tool chest')).toBe('1 saved to Tool chest');
  });

  it('says what is happening, never "0 saved", until the first row lands', () => {
    const none = { saved: 0, named: 0, unnamed: 0, pending: 2 };
    expect(reviewTitle(none, 'pending', DROP_ZONE_CONTAINER_ID, null)).toBe('Saving 2 photos…');
    expect(reviewTitle({ ...none, pending: 1 }, 'pending', 'c1', null)).toBe('Saving 1 photo…');
    expect(reviewStatusText('pending', none)).toBe('They appear here as they are saved.');
    const some = { saved: 1, named: 1, unnamed: 0, pending: 1 };
    expect(reviewTitle(some, 'pending', DROP_ZONE_CONTAINER_ID, null)).toBe(
      '1 saved to the drop zone',
    );
  });

  it('never says "the drop zone" for a container whose rows have not landed yet', () => {
    const none = { saved: 0, named: 0, unnamed: 0, pending: 0 };
    expect(reviewTitle(none, 'allNamed', 'c1', null)).toBeNull();
    expect(reviewDoneToast(2, 'c1', null)).toBeNull();
  });

  it('offers to view the drop zone, but not a container the person is back on', () => {
    expect(reviewDoneToast(4, DROP_ZONE_CONTAINER_ID, 'Drop zone')).toEqual({
      message: '4 items are in the drop zone.',
      viewDropZone: true,
    });
    expect(reviewDoneToast(1, DROP_ZONE_CONTAINER_ID, null)?.message).toBe(
      '1 item is in the drop zone.',
    );
    expect(reviewDoneToast(2, 'c1', 'Tool chest')).toEqual({
      message: '2 items added to Tool chest.',
      viewDropZone: false,
    });
  });

  it('says nothing when nothing was saved', () => {
    expect(reviewDoneToast(0, DROP_ZONE_CONTAINER_ID, null)).toBeNull();
  });
});

describe('sessionSignature', () => {
  it('changes when a row lands or is named, not when it is read again', () => {
    const before = sessionSignature([row('a', '', 1, 1)]);
    expect(sessionSignature([row('a', '', 1, 1)])).toBe(before);
    expect(sessionSignature([row('a', 'Drill', 1, 2)])).not.toBe(before);
    expect(sessionSignature([row('a', '', 1, 1), row('b', '', 2, 2)])).not.toBe(before);
  });
});

describe('hidden rows', () => {
  const list = [row('a', 'A'), row('b', 'B'), row('c', 'C')];

  it('hides filed or deleted rows from the list they were hidden in', () => {
    const hidden = hideRow(hideRow(null, list, 'a'), list, 'c');
    expect(visibleRows(list, hidden).map((item) => item.id)).toEqual(['b']);
  });

  it('lets a fresh read decide, so an item moved back by Undo shows again', () => {
    const hidden = hideRow(null, list, 'a');
    const fresh = [row('a', 'A'), row('b', 'B')];
    expect(visibleRows(fresh, hidden)).toBe(fresh);
    expect(hideRow(hidden, fresh, 'b').ids).toEqual(new Set(['b']));
  });

  it('shows everything when nothing is hidden', () => {
    expect(visibleRows(list, null)).toBe(list);
  });
});

describe('rows that landed and left', () => {
  it('remembers every row the set has shown, and keeps the same set when nothing is new', () => {
    const first = withLanded(new Set(), [row('a', ''), row('b', '')]);
    expect(first).toEqual(new Set(['a', 'b']));
    expect(withLanded(first, [row('b', 'Drill')])).toBe(first);
    expect(withLanded(first, [row('c', '')])).toEqual(new Set(['a', 'b', 'c']));
  });

  it('does not count a filed or deleted row as a photo still on its way', () => {
    // Four shots; all four landed, then one was filed out of the drop zone.
    const expected = expectedStillShown(4, 4, 3);
    expect(expected).toBe(3);
    expect(
      summarizeSession([row('a', 'A'), row('b', 'B'), row('c', 'C')] as never[], expected).pending,
    ).toBe(0);
  });

  it('still counts photos that never landed', () => {
    // Four shots; three landed, one of those was deleted.
    expect(expectedStillShown(4, 3, 2)).toBe(3);
    expect(summarizeSession([row('a', 'A'), row('b', 'B')] as never[], 3).pending).toBe(1);
    expect(expectedStillShown(0, 2, 0)).toBe(0);
  });
});
