import type { Container } from '@/db/types';
import { HouseholdHttpError } from '@/services/household/client';
import {
  FRESH_ARRIVAL_MS,
  isFreshArrival,
  labelFailureMessage,
  labelOf,
  planSticker,
  settleWrittenLabel,
  shareText,
  sortContents,
  titleOf,
  typeNameOf,
} from '@/ui/container/containerRules';

const TOKEN = 'a'.repeat(32);
const OTHER_TOKEN = 'b'.repeat(32);

function container(overrides: Partial<Container> = {}): Container {
  return {
    id: 'c-1',
    spaceId: 's-1',
    name: 'Tool chest',
    visualType: 'cabinet',
    shortCode: 'CAB-J92R',
    createdAt: 1,
    updatedAt: 1,
    ...overrides,
  };
}

const target = { id: 'c-1', name: 'Tool chest', shortCode: 'CAB-J92R', qrToken: null };

describe('labelOf and titleOf', () => {
  it('uses the name, or else the code on the label', () => {
    expect(labelOf({ name: 'Tool chest', shortCode: 'CAB-J92R' })).toBe('Tool chest');
    expect(labelOf({ name: null, shortCode: 'BOX-7K2M' })).toBe('BOX-7K2M');
    expect(labelOf({ name: '  ', shortCode: 'BOX-7K2M' })).toBe('BOX-7K2M');
  });

  it('titles an unnamed container by its type, as the desk does', () => {
    expect(titleOf({ name: null, visualType: 'box' })).toBe('Unnamed box');
    expect(titleOf({ name: '', visualType: 'drawer' })).toBe('Unnamed drawer');
    expect(titleOf({ name: 'Tool chest', visualType: 'box' })).toBe('Tool chest');
  });

  it('reads an unknown stored type as a container', () => {
    expect(typeNameOf('shelf')).toBe('Shelf');
    expect(typeNameOf('suitcase')).toBe('Container');
    expect(titleOf({ name: null, visualType: 'suitcase' })).toBe('Unnamed container');
  });
});

describe('sortContents', () => {
  it('sorts by name without case or accents, unnamed last by when they were added', () => {
    const items = [
      { id: 'u2', name: '', createdAt: 20 },
      { id: 'b', name: 'batteries', createdAt: 5 },
      { id: 'e', name: 'Éclairs', createdAt: 6 },
      { id: 'u1', name: '  ', createdAt: 10 },
      { id: 'a', name: 'Allen keys', createdAt: 7 },
      { id: 'z', name: 'Zip ties', createdAt: 1 },
    ];
    expect(sortContents(items).map((item) => item.id)).toEqual(['a', 'b', 'e', 'z', 'u1', 'u2']);
  });

  it('keeps two items of the same name in the order they were added', () => {
    const items = [
      { id: 'later', name: 'Screws', createdAt: 9 },
      { id: 'first', name: 'screws', createdAt: 3 },
    ];
    expect(sortContents(items).map((item) => item.id)).toEqual(['first', 'later']);
  });

  it('does not reorder the list it was given', () => {
    const items = [
      { name: 'b', createdAt: 1 },
      { name: 'a', createdAt: 2 },
    ];
    sortContents(items);
    expect(items[0]?.name).toBe('b');
  });
});

describe('isFreshArrival', () => {
  it('counts the last ten seconds, either side of a slightly different clock', () => {
    expect(isFreshArrival(1_000, 1_000)).toBe(true);
    expect(isFreshArrival(1_000, 1_000 + FRESH_ARRIVAL_MS - 1)).toBe(true);
    expect(isFreshArrival(1_000, 1_000 + FRESH_ARRIVAL_MS)).toBe(false);
    expect(isFreshArrival(5_000, 1_000)).toBe(true);
    expect(isFreshArrival(1_000 + FRESH_ARRIVAL_MS * 3, 1_000)).toBe(false);
  });
});

describe('planSticker', () => {
  it('ignores codes that are not ours', () => {
    expect(planSticker({ kind: 'invalid', raw: 'https://example.com' }, target)).toEqual({
      kind: 'invalid',
    });
  });

  it('links a new sticker straight away when the container has no label', () => {
    expect(planSticker({ kind: 'unknown', token: TOKEN }, target)).toEqual({
      kind: 'link',
      token: TOKEN,
      confirm: null,
    });
  });

  it('asks before replacing the label a container already has', () => {
    const plan = planSticker(
      { kind: 'unknown', token: TOKEN },
      { ...target, qrToken: OTHER_TOKEN },
    );
    expect(plan).toEqual({
      kind: 'link',
      token: TOKEN,
      confirm: {
        title: 'Replace the label on Tool chest?',
        body: 'Tool chest already has a label. Its old sticker will stop opening it.',
        confirmLabel: 'Replace',
      },
    });
  });

  it('says so when the sticker already opens this container', () => {
    const outcome = { kind: 'bound' as const, token: TOKEN, container: container() };
    expect(planSticker(outcome, { ...target, qrToken: TOKEN })).toEqual({ kind: 'already' });
  });

  it('asks before moving a sticker from another container, naming both', () => {
    const outcome = {
      kind: 'bound' as const,
      token: TOKEN,
      container: container({ id: 'c-2', name: 'Shelf A' }),
    };
    expect(planSticker(outcome, target)).toEqual({
      kind: 'link',
      token: TOKEN,
      confirm: {
        title: 'Move this sticker to Tool chest?',
        body: 'It opens Shelf A now. After this it opens Tool chest instead.',
        confirmLabel: 'Move sticker',
      },
    });
  });

  it('also says the old sticker stops working when the container had its own', () => {
    const outcome = {
      kind: 'bound' as const,
      token: TOKEN,
      container: container({ id: 'c-2', name: null, shortCode: 'SHL-4QW8' }),
    };
    const plan = planSticker(outcome, { ...target, name: null, qrToken: OTHER_TOKEN });
    expect(plan.kind === 'link' ? plan.confirm : null).toEqual({
      title: 'Move this sticker to CAB-J92R?',
      body: 'It opens SHL-4QW8 now. After this it opens CAB-J92R instead. CAB-J92R already has a label. Its old sticker will stop opening it.',
      confirmLabel: 'Move sticker',
    });
  });
});

describe('settleWrittenLabel', () => {
  const idle = { loading: false, failed: false };
  const reading = { loading: true, failed: false };

  it('has nothing to hold before a write', () => {
    expect(settleWrittenLabel(null, reading)).toBeNull();
  });

  it('holds a fresh write until a read starts, then until it comes back', () => {
    const written = { token: TOKEN, reloading: false };
    expect(settleWrittenLabel(written, idle)).toBe(written);
    const started = settleWrittenLabel(written, reading);
    expect(started).toEqual({ token: TOKEN, reloading: true });
    expect(settleWrittenLabel(started, reading)).toBe(started);
    expect(settleWrittenLabel(started, idle)).toBeNull();
  });

  it('keeps showing the write when the read after it fails, until a later one succeeds', () => {
    const removed = { token: null, reloading: true };
    const kept = settleWrittenLabel(removed, { loading: false, failed: true });
    expect(kept).toEqual({ token: null, reloading: false });
    expect(settleWrittenLabel(kept, { loading: false, failed: true })).toBe(kept);
    const retried = settleWrittenLabel(kept, reading);
    expect(retried).toEqual({ token: null, reloading: true });
    expect(settleWrittenLabel(retried, idle)).toBeNull();
  });
});

describe('labelFailureMessage', () => {
  const offline = new HouseholdHttpError(0, 'offline');
  const server = new HouseholdHttpError(500, 'http_500');

  it('says the old sticker still works when a replace or remove did not happen', () => {
    expect(labelFailureMessage('replace', offline)).toBe(
      'The label was not replaced, so the old sticker still works. Check the connection and try again.',
    );
    expect(labelFailureMessage('remove', server)).toBe(
      'The label was not removed, so the sticker still opens this container. Try again.',
    );
    expect(labelFailureMessage('make', new Error('SQLITE_BUSY'))).toBe(
      'The label was not made. Try again.',
    );
  });

  it('says when the container was deleted elsewhere', () => {
    expect(labelFailureMessage('make', new HouseholdHttpError(404, 'not_found'))).toBe(
      'This container is not in the household any more. Nothing else changed.',
    );
  });

  it('never shows a raw code', () => {
    for (const action of ['make', 'replace', 'remove'] as const) {
      expect(labelFailureMessage(action, new HouseholdHttpError(530, 'http_530'))).not.toMatch(
        /http_|offline|timeout/,
      );
    }
  });
});

describe('shareText', () => {
  it('names the container by label and code, adding the link only where no picture goes', () => {
    const payload = `inventory://c/${TOKEN}`;
    expect(shareText(target, payload, { withPayload: false })).toBe('Tool chest (CAB-J92R)');
    expect(shareText({ name: null, shortCode: 'BOX-7K2M' }, payload, { withPayload: true })).toBe(
      `BOX-7K2M (BOX-7K2M)\n${payload}`,
    );
  });
});
