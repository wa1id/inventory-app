import * as SQLite from 'expo-sqlite';

import type { SqlDatabase, SqlParams } from './types';

/**
 * `expo-sqlite` already exposes the async shape we need; this wrapper pins it to
 * the `SqlDatabase` contract so repositories cannot accidentally depend on
 * Expo-only methods that the Node test adapter does not provide.
 */
function wrap(db: SQLite.SQLiteDatabase): SqlDatabase {
  return {
    execAsync: (sql) => db.execAsync(sql),
    runAsync: async (sql, params: SqlParams = []) => {
      const result = await db.runAsync(sql, params);
      return { changes: result.changes };
    },
    getAllAsync: <T>(sql: string, params: SqlParams = []) => db.getAllAsync<T>(sql, params),
    getFirstAsync: <T>(sql: string, params: SqlParams = []) => db.getFirstAsync<T>(sql, params),
    withTransactionAsync: (task) => db.withTransactionAsync(task),
    closeAsync: () => db.closeAsync(),

    /**
     * Snapshot for backup.
     *
     * The checkpoint first is what makes the result trustworthy: in WAL mode
     * recent commits live in `inventory.db-wal` until something folds them
     * back, and a snapshot taken without it can be missing the writes the user
     * just made — a backup that silently lags reality is worse than none,
     * because it is believed.
     */
    snapshotAsync: async () => {
      await db.execAsync('PRAGMA wal_checkpoint(TRUNCATE)');
      return db.serializeAsync();
    },

    /**
     * Replaces every table with the snapshot's, in place.
     *
     * Uses SQLite's own online backup API rather than overwriting the file.
     * Writing bytes over a live database means the open connection, its page
     * cache, and the `-wal` and `-shm` sidecars all still describe the old
     * database — the classic way to turn a restore into corruption. Going
     * through `backupDatabaseAsync` keeps the connection valid throughout, so
     * there is no window where the app holds a handle to something that no
     * longer exists.
     */
    restoreAsync: async (snapshot) => {
      const source = await SQLite.deserializeDatabaseAsync(snapshot);
      try {
        await SQLite.backupDatabaseAsync({
          sourceDatabase: source,
          sourceDatabaseName: 'main',
          destDatabase: db,
          destDatabaseName: 'main',
        });
      } finally {
        await source.closeAsync();
      }
    },
  };
}

export const DATABASE_NAME = 'inventory.db';

/**
 * Opens the on-device database with the pragmas the app relies on.
 *
 * `foreign_keys` is what actually enforces the referential integrity the schema
 * declares — SQLite leaves it off by default, and without it deleting a space
 * would silently orphan its containers and items.
 */
export async function openExpoDatabase(name: string = DATABASE_NAME): Promise<SqlDatabase> {
  const db = await SQLite.openDatabaseAsync(name);
  await db.execAsync('PRAGMA journal_mode = WAL');
  await db.execAsync('PRAGMA foreign_keys = ON');
  return wrap(db);
}
