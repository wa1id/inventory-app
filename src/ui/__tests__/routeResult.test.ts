import { abandonResult, deliverResult, openForResult } from '@/ui/routeResult';

function open<T>(): { requestId: string; result: Promise<T | undefined> } {
  let requestId = '';
  const result = openForResult<T>((id) => {
    requestId = id;
  });
  return { requestId, result };
}

describe('routeResult', () => {
  it('passes a request id to the opener and resolves with the delivered value', async () => {
    const { requestId, result } = open<{ containerId: string }>();
    expect(requestId).not.toBe('');
    expect(deliverResult(requestId, { containerId: 'c1' })).toBe(true);
    await expect(result).resolves.toEqual({ containerId: 'c1' });
  });

  it('resolves only once', async () => {
    const { requestId, result } = open<number>();
    expect(deliverResult(requestId, 1)).toBe(true);
    expect(deliverResult(requestId, 2)).toBe(false);
    await expect(result).resolves.toBe(1);
  });

  it('resolves undefined when abandoned, and ignores a delivery after that', async () => {
    const { requestId, result } = open<number>();
    abandonResult(requestId);
    abandonResult(requestId);
    expect(deliverResult(requestId, 3)).toBe(false);
    await expect(result).resolves.toBeUndefined();
  });

  it('keeps concurrent requests apart', async () => {
    const first = open<string>();
    const second = open<string>();
    expect(first.requestId).not.toBe(second.requestId);
    deliverResult(second.requestId, 'second');
    deliverResult(first.requestId, 'first');
    await expect(first.result).resolves.toBe('first');
    await expect(second.result).resolves.toBe('second');
  });

  it('ignores a missing or unknown request id', () => {
    expect(deliverResult(undefined, 1)).toBe(false);
    expect(deliverResult('nobody', 1)).toBe(false);
    expect(() => abandonResult(null)).not.toThrow();
  });
});
