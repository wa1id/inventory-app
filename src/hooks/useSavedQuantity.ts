import { useCallback, useEffect, useRef, useState } from 'react';

import { ConflictError } from '@/core/conflict';
import { clampQuantity } from '@/core/quantity';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { logEvent } from '@/services/telemetry';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';

const MAX_CONFLICT_RETRIES = 3;

/** Why a quantity did not save: the network, the item vanished, or anything else. */
export type QuantityErrorKind = 'offline' | 'gone' | 'other';

const MESSAGES: Record<QuantityErrorKind, string> = {
  offline: strings.quantity.notSavedOffline,
  gone: strings.quantity.gone,
  other: strings.quantity.notSaved,
};

/**
 * Live quantity for one item: the number on screen moves immediately, and
 * writes are coalesced so tapping plus five times becomes one PATCH of the
 * final count rather than five stacked conflicts.
 *
 * `onError` lets a compact stepper, which has no room for a sentence under it,
 * report a failure elsewhere (a toast naming the item) so it is never silent.
 */
export function useSavedQuantity(
  item: { id: string; quantity: number; updatedAt: number },
  options?: { onError?: (kind: QuantityErrorKind) => void },
): {
  quantity: number;
  setQuantity: (next: number) => void;
  error: string | null;
  errorKind: QuantityErrorKind | null;
} {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const [boundId, setBoundId] = useState(item.id);
  const [quantity, setQuantityState] = useState(item.quantity);
  const [errorKind, setErrorKind] = useState<QuantityErrorKind | null>(null);

  const onErrorRef = useRef(options?.onError);
  useEffect(() => {
    onErrorRef.current = options?.onError;
  });

  const confirmedRef = useRef({ quantity: item.quantity, updatedAt: item.updatedAt });
  const pendingRef = useRef<number | null>(null);
  const inFlightRef = useRef(false);
  const retriesRef = useRef(0);

  if (item.id !== boundId) {
    setBoundId(item.id);
    setQuantityState(item.quantity);
    setErrorKind(null);
  }

  useEffect(() => {
    pendingRef.current = null;
    inFlightRef.current = false;
    retriesRef.current = 0;
    confirmedRef.current = { quantity: item.quantity, updatedAt: item.updatedAt };
    // Later quantity updates for this same item are handled by the effect below.
  }, [item.id]); // eslint-disable-line react-hooks/exhaustive-deps -- reset only on item identity

  useEffect(() => {
    if (pendingRef.current !== null || inFlightRef.current) return;
    confirmedRef.current = { quantity: item.quantity, updatedAt: item.updatedAt };
    setQuantityState(item.quantity);
  }, [item.quantity, item.updatedAt]);

  const fail = useCallback((kind: QuantityErrorKind) => {
    setErrorKind(kind);
    onErrorRef.current?.(kind);
  }, []);

  const flush = useCallback(async () => {
    if (inFlightRef.current) return;
    inFlightRef.current = true;
    try {
      while (pendingRef.current !== null && pendingRef.current !== confirmedRef.current.quantity) {
        const target = pendingRef.current;
        try {
          const updated = await repos.items.update(item.id, {
            quantity: target,
            expectedUpdatedAt: confirmedRef.current.updatedAt,
          });
          if (!updated) {
            pendingRef.current = null;
            setQuantityState(confirmedRef.current.quantity);
            fail('gone');
            break;
          }
          confirmedRef.current = {
            quantity: updated.quantity,
            updatedAt: updated.updatedAt,
          };
          retriesRef.current = 0;
          logEvent('item_updated');
          if (pendingRef.current === target) pendingRef.current = null;
          invalidate();
        } catch (cause) {
          if (cause instanceof ConflictError && retriesRef.current < MAX_CONFLICT_RETRIES) {
            retriesRef.current += 1;
            try {
              const fresh = await repos.items.getById(item.id);
              if (!fresh) {
                pendingRef.current = null;
                fail('gone');
                break;
              }
              confirmedRef.current = { quantity: fresh.quantity, updatedAt: fresh.updatedAt };
              continue;
            } catch {
              pendingRef.current = null;
              setQuantityState(confirmedRef.current.quantity);
              fail('other');
              break;
            }
          }
          pendingRef.current = null;
          retriesRef.current = 0;
          setQuantityState(confirmedRef.current.quantity);
          // Read like every other failure, so a home box that is down behind
          // Cloudflare (502, 520–530) also says "check the connection".
          const { kind } = describeError(cause, 'quantity', 'item');
          fail(kind === 'offline' ? 'offline' : kind === 'gone' ? 'gone' : 'other');
          haptics.error();
          break;
        }
      }
      if (pendingRef.current === confirmedRef.current.quantity) pendingRef.current = null;
    } finally {
      inFlightRef.current = false;
    }
  }, [fail, invalidate, item.id, repos]);

  const setQuantity = useCallback(
    (next: number) => {
      const clamped = clampQuantity(next);
      setQuantityState(clamped);
      setErrorKind(null);
      pendingRef.current = clamped;
      void flush();
    },
    [flush],
  );

  return { quantity, setQuantity, error: errorKind ? MESSAGES[errorKind] : null, errorKind };
}
