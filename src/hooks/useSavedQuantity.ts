import { useCallback, useEffect, useRef, useState } from 'react';
import * as Haptics from 'expo-haptics';

import { ConflictError } from '@/core/conflict';
import { clampQuantity } from '@/core/quantity';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { HouseholdHttpError } from '@/services/household/client';
import { logEvent } from '@/services/telemetry';

const MAX_CONFLICT_RETRIES = 3;

/**
 * Live quantity for one item: the number on screen moves immediately, and
 * writes are coalesced so tapping plus five times becomes one PATCH of the
 * final count rather than five stacked conflicts.
 */
export function useSavedQuantity(item: { id: string; quantity: number; updatedAt: number }): {
  quantity: number;
  setQuantity: (next: number) => void;
  error: string | null;
} {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const [boundId, setBoundId] = useState(item.id);
  const [quantity, setQuantityState] = useState(item.quantity);
  const [error, setError] = useState<string | null>(null);

  const confirmedRef = useRef({ quantity: item.quantity, updatedAt: item.updatedAt });
  const pendingRef = useRef<number | null>(null);
  const inFlightRef = useRef(false);
  const retriesRef = useRef(0);

  if (item.id !== boundId) {
    setBoundId(item.id);
    setQuantityState(item.quantity);
    setError(null);
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
            setError(strings.items.quantitySaveFailed);
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
                setError(strings.items.quantitySaveFailed);
                break;
              }
              confirmedRef.current = { quantity: fresh.quantity, updatedAt: fresh.updatedAt };
              continue;
            } catch {
              pendingRef.current = null;
              setQuantityState(confirmedRef.current.quantity);
              setError(strings.items.quantitySaveFailed);
              break;
            }
          }
          pendingRef.current = null;
          retriesRef.current = 0;
          setQuantityState(confirmedRef.current.quantity);
          setError(
            cause instanceof HouseholdHttpError &&
              (cause.code === 'offline' || cause.code === 'timeout')
              ? strings.household.offline
              : strings.items.quantitySaveFailed,
          );
          void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error).catch(
            () => undefined,
          );
          break;
        }
      }
      if (pendingRef.current === confirmedRef.current.quantity) pendingRef.current = null;
    } finally {
      inFlightRef.current = false;
    }
  }, [invalidate, item.id, repos]);

  const setQuantity = useCallback(
    (next: number) => {
      const clamped = clampQuantity(next);
      setQuantityState(clamped);
      setError(null);
      pendingRef.current = clamped;
      void flush();
    },
    [flush],
  );

  return { quantity, setQuantity, error };
}
