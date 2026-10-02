import { createContext, useContext, useMemo, type ReactNode } from 'react';

import type { ItemWithContext } from '@/db/types';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useRepositories } from '@/providers/DatabaseProvider';

interface DropZoneContextValue {
  /** Waiting items, newest first; empty until the first read finishes. */
  items: ItemWithContext[];
  count: number;
  /** No answer yet: badges and cards stay hidden rather than showing 0. */
  loading: boolean;
  cause: unknown;
  /** A refresh failed while earlier items are still shown (the Drop zone's banner). */
  refreshFailed: boolean;
  /** A read is in flight, first or not (the Drop zone's pull-to-refresh spinner). */
  reading: boolean;
  reload: () => void;
}

const DropZoneContext = createContext<DropZoneContextValue | null>(null);

/**
 * One read of the drop zone shared by the tab badge, Home's card and the Drop
 * zone list, instead of a count query per screen. When paired, counting
 * downloaded the whole list anyway, so the list itself is shared.
 *
 * Mounted in the tabs layout, a screen of the root stack, so it refreshes
 * when the tabs come back into view like any other screen's query.
 */
export function DropZoneProvider({ children }: { children: ReactNode }) {
  const repos = useRepositories();
  const { data, loading, cause, refreshFailed, reload } = useInventoryQuery(
    () => repos.items.listUnsorted(),
    'drop-zone',
  );

  const value = useMemo(
    () => ({
      items: data ?? [],
      count: data?.length ?? 0,
      loading: loading && data === null,
      cause,
      refreshFailed,
      reading: loading,
      reload,
    }),
    [cause, data, loading, refreshFailed, reload],
  );

  return <DropZoneContext.Provider value={value}>{children}</DropZoneContext.Provider>;
}

export function useDropZone(): DropZoneContextValue {
  const context = useContext(DropZoneContext);
  if (!context) {
    throw new Error('useDropZone must be used inside a DropZoneProvider');
  }
  return context;
}
