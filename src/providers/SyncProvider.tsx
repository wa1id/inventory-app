import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import type { ReactNode } from 'react';
import { AppState } from 'react-native';

import { useDatabase } from '@/providers/DatabaseProvider';
import { createAccount, importAccount, loadAccount } from '@/services/account/identity';
import type { Account } from '@/services/account/identity';
import { appConfig } from '@/services/config';
import { lastBackupAt, maybeBackup, restoreBackup, runBackup } from '@/services/sync/backup';
import { createSyncClient } from '@/services/sync/client';
import type { SyncClient } from '@/services/sync/client';
import { syncPhotos } from '@/services/sync/photoSync';
import type { SyncFailureReason } from '@/services/sync/contract';

/**
 * Backup is opt-in and off until someone turns it on.
 *
 * The app worked entirely offline before this existed, and that is still a
 * legitimate way to run it. Uploading someone's photographs of the inside of
 * their home is not a default worth assuming — so `status` starts at `off`, and
 * only an explicit action moves it.
 */
export type SyncStatus =
  | { state: 'unavailable' }
  | { state: 'off' }
  | { state: 'idle'; account: Account; lastBackupAt: number | null }
  | { state: 'working'; account: Account }
  | { state: 'error'; account: Account | null; reason: SyncFailureReason };

interface SyncContextValue {
  status: SyncStatus;
  /** Creates an account and performs the first backup. */
  enable: () => Promise<{ ok: true; account: Account } | { ok: false; reason: SyncFailureReason }>;
  backupNow: () => Promise<void>;
  /** Adopts an existing account from a code, then pulls its newest snapshot. */
  restoreFromCode: (
    code: string,
  ) => Promise<{ ok: true } | { ok: false; reason: SyncFailureReason | 'malformed' }>;
  refresh: () => Promise<void>;
}

const SyncContext = createContext<SyncContextValue | null>(null);

export function SyncProvider({ children }: { children: ReactNode }) {
  const { state, invalidate } = useDatabase();
  const [account, setAccount] = useState<Account | null>(null);
  const [status, setStatus] = useState<SyncStatus>(
    appConfig.syncEndpoint ? { state: 'off' } : { state: 'unavailable' },
  );

  // A pass in flight, so foregrounding twice in a second does not start two.
  const running = useRef(false);

  const repos = state.status === 'ready' ? state.repos : null;

  const client: SyncClient | null = useMemo(
    () => (account ? createSyncClient({ recoveryCode: account.recoveryCode }) : null),
    [account],
  );

  useEffect(() => {
    if (!appConfig.syncEndpoint) return;

    let cancelled = false;
    (async () => {
      const existing = await loadAccount();
      if (cancelled || !existing) return;
      setAccount(existing);
      setStatus({ state: 'idle', account: existing, lastBackupAt: await lastBackupAt() });
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  /**
   * One background pass: photos first, then the database.
   *
   * Photos before the snapshot on purpose. The snapshot records which photos
   * have a remote copy, so running it last means the backup describes a state
   * that is actually true rather than one that was true a moment ago.
   */
  const runPass = useCallback(async () => {
    if (!repos || !client || running.current) return;
    running.current = true;

    try {
      await syncPhotos(repos.db, client);
      await maybeBackup(repos.db, client);
      if (account) {
        setStatus({ state: 'idle', account, lastBackupAt: await lastBackupAt() });
      }
    } finally {
      running.current = false;
    }
  }, [repos, client, account]);

  // Foregrounding is the natural moment: the user has just come back, the
  // network is usually available, and nothing is competing for the main thread.
  useEffect(() => {
    if (!client) return;

    void runPass();
    const subscription = AppState.addEventListener('change', (next) => {
      if (next === 'active') void runPass();
    });

    return () => subscription.remove();
  }, [client, runPass]);

  const enable = useCallback(async () => {
    if (!repos) return { ok: false as const, reason: 'not_configured' as const };

    const created = await createAccount();
    setAccount(created);
    setStatus({ state: 'working', account: created });

    const result = await runBackup(
      repos.db,
      createSyncClient({ recoveryCode: created.recoveryCode }),
    );

    if (result.status === 'failed') {
      setStatus({ state: 'error', account: created, reason: result.reason });
      return { ok: false as const, reason: result.reason };
    }

    setStatus({ state: 'idle', account: created, lastBackupAt: result.value.capturedAt });
    return { ok: true as const, account: created };
  }, [repos]);

  const backupNow = useCallback(async () => {
    if (!repos || !client || !account) return;

    setStatus({ state: 'working', account });
    const result = await runBackup(repos.db, client);

    setStatus(
      result.status === 'failed'
        ? { state: 'error', account, reason: result.reason }
        : { state: 'idle', account, lastBackupAt: result.value.capturedAt },
    );
  }, [repos, client, account]);

  const restoreFromCode = useCallback(
    async (code: string) => {
      if (!repos) return { ok: false as const, reason: 'not_configured' as const };

      const imported = await importAccount(code);
      if (!imported.ok) {
        return {
          ok: false as const,
          reason:
            imported.reason === 'malformed' ? ('malformed' as const) : ('not_configured' as const),
        };
      }

      const adopted = imported.account;
      setAccount(adopted);
      setStatus({ state: 'working', account: adopted });

      const adoptedClient = createSyncClient({ recoveryCode: adopted.recoveryCode });
      const result = await restoreBackup(repos.db, adoptedClient);

      if (result.status === 'failed') {
        setStatus({ state: 'error', account: adopted, reason: result.reason });
        return { ok: false as const, reason: result.reason };
      }

      // Every screen is reading from SQLite, so the restored rows have to be
      // announced before the photos start arriving behind them.
      invalidate();
      await syncPhotos(repos.db, adoptedClient);
      invalidate();

      setStatus({ state: 'idle', account: adopted, lastBackupAt: await lastBackupAt() });
      return { ok: true as const };
    },
    [repos, invalidate],
  );

  const refresh = useCallback(async () => {
    if (!account) return;
    setStatus({ state: 'idle', account, lastBackupAt: await lastBackupAt() });
  }, [account]);

  const value = useMemo(
    () => ({ status, enable, backupNow, restoreFromCode, refresh }),
    [status, enable, backupNow, restoreFromCode, refresh],
  );

  return <SyncContext.Provider value={value}>{children}</SyncContext.Provider>;
}

export function useSync(): SyncContextValue {
  const context = useContext(SyncContext);
  if (!context) {
    throw new Error('useSync must be used inside a SyncProvider');
  }
  return context;
}
