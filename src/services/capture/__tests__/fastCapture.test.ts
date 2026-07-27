import { captureFastItem, type FastCaptureDeps } from '@/services/capture/fastCapture';
import type { RecognitionResult } from '@/services/ai/contract';

const NAMES = { pending: 'Identifying…', fallback: 'Unnamed item' };

function makeDeps(recognition: RecognitionResult | (() => Promise<RecognitionResult>)) {
  const calls = {
    created: [] as unknown[],
    updated: [] as { id: string; input: unknown }[],
    stored: [] as string[],
  };

  const deps: FastCaptureDeps = {
    storePhoto: async (uri) => {
      calls.stored.push(uri);
      return { uri: `stored://${uri}`, width: 100, height: 200, byteSize: 4242 };
    },
    createItem: async (draft) => {
      calls.created.push(draft);
      return { id: 'item-1' };
    },
    updateItem: async (id, input) => {
      calls.updated.push({ id, input });
    },
    recognize: typeof recognition === 'function' ? recognition : async () => recognition,
  };

  return { deps, calls };
}

const SUCCESS: RecognitionResult = {
  status: 'success',
  contractVersion: 1,
  suggestion: {
    name: 'Cordless drill',
    category: 'Tools',
    tags: ['dewalt', 'power tool'],
    estimatedValue: 89.5,
    currency: 'EUR',
    confidence: 0.9,
  },
};

describe('captureFastItem', () => {
  it('persists the item with its photo before recognition runs', async () => {
    const order: string[] = [];
    const { deps } = makeDeps(async () => {
      order.push('recognize');
      return SUCCESS;
    });
    const createItem = deps.createItem;
    deps.createItem = async (draft) => {
      order.push('create');
      return createItem(draft);
    };

    await captureFastItem({
      containerId: 'c1',
      photoUri: 'file://a.jpg',
      deps,
      names: NAMES,
    });

    expect(order).toEqual(['create', 'recognize']);
  });

  it('stores the photo and attaches it to the created item', async () => {
    const { deps, calls } = makeDeps(SUCCESS);

    await captureFastItem({ containerId: 'c1', photoUri: 'file://a.jpg', deps, names: NAMES });

    expect(calls.stored).toEqual(['file://a.jpg']);
    expect(calls.created[0]).toMatchObject({
      containerId: 'c1',
      name: NAMES.pending,
      photo: { uri: 'stored://file://a.jpg', width: 100, height: 200, byteSize: 4242 },
    });
  });

  it('fills the row in from a successful suggestion', async () => {
    const { deps, calls } = makeDeps(SUCCESS);

    const outcome = await captureFastItem({
      containerId: 'c1',
      photoUri: 'file://a.jpg',
      deps,
      names: NAMES,
    });

    expect(outcome).toEqual({ status: 'recognized', itemId: 'item-1', name: 'Cordless drill' });
    expect(calls.updated).toEqual([
      {
        id: 'item-1',
        input: {
          name: 'Cordless drill',
          category: 'Tools',
          tags: ['dewalt', 'power tool'],
          estimatedValue: 89.5,
          currency: 'EUR',
        },
      },
    ]);
  });

  it('keeps the photographed item and names it plainly when recognition fails', async () => {
    const { deps, calls } = makeDeps({ status: 'failed', reason: 'offline' });

    const outcome = await captureFastItem({
      containerId: 'c1',
      photoUri: 'file://a.jpg',
      deps,
      names: NAMES,
    });

    expect(outcome).toEqual({ status: 'unrecognized', itemId: 'item-1', reason: 'offline' });
    expect(calls.updated).toEqual([{ id: 'item-1', input: { name: NAMES.fallback } }]);
  });

  it.each(['not_configured', 'timeout', 'rate_limited', 'low_confidence'] as const)(
    'treats %s as a nameable item rather than an error',
    async (reason) => {
      const { deps } = makeDeps({ status: 'failed', reason });

      const outcome = await captureFastItem({
        containerId: 'c1',
        photoUri: 'file://a.jpg',
        deps,
        names: NAMES,
      });

      expect(outcome.status).toBe('unrecognized');
      expect(outcome.itemId).toBe('item-1');
    },
  );

  it('survives a recognizer that throws instead of resolving', async () => {
    const { deps, calls } = makeDeps(async () => {
      throw new Error('boom');
    });

    const outcome = await captureFastItem({
      containerId: 'c1',
      photoUri: 'file://a.jpg',
      deps,
      names: NAMES,
    });

    expect(outcome.status).toBe('unrecognized');
    expect(calls.updated).toEqual([{ id: 'item-1', input: { name: NAMES.fallback } }]);
  });

  it('falls back when the suggestion carries a blank name', async () => {
    const { deps } = makeDeps({
      status: 'success',
      contractVersion: 1,
      suggestion: { ...SUCCESS.suggestion, name: '   ' },
    } as RecognitionResult);

    const outcome = await captureFastItem({
      containerId: 'c1',
      photoUri: 'file://a.jpg',
      deps,
      names: NAMES,
    });

    expect(outcome).toMatchObject({ status: 'recognized', name: NAMES.fallback });
  });

  it('propagates a storage failure so the camera can surface it', async () => {
    const { deps } = makeDeps(SUCCESS);
    deps.storePhoto = async () => {
      throw new Error('No space left');
    };

    await expect(
      captureFastItem({ containerId: 'c1', photoUri: 'file://a.jpg', deps, names: NAMES }),
    ).rejects.toThrow('No space left');
  });
});
