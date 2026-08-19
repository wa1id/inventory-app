import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import type { SqlDatabase, SqlParams } from './types';

/**
 * File-backed `SqlDatabase` on Node's built-in SQLite.
 *
 * The phone still uses `expo-sqlite`. The home server (and the Jest persistence
 * suite) use this adapter so repositories stay on one SQL dialect. `:memory:`
 * remains valid for tests; a filesystem path is what the household process
 * opens.
 */
function sqlLiteral(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function applyPragmas(db: DatabaseSync, fileBacked: boolean): void {
  db.exec('PRAGMA foreign_keys = ON');
  if (fileBacked) {
    db.exec('PRAGMA journal_mode = WAL');
  }
}

function unlinkIfPresent(path: string): void {
  try {
    unlinkSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
  }
}

export function openNodeDatabase(path = ':memory:'): SqlDatabase {
  const fileBacked = path !== ':memory:';
  if (fileBacked) {
    mkdirSync(dirname(path), { recursive: true });
  }

  const handle = { db: new DatabaseSync(path) };
  applyPragmas(handle.db, fileBacked);

  let depth = 0;

  return {
    async execAsync(sql) {
      handle.db.exec(sql);
    },

    async runAsync(sql, params: SqlParams = []) {
      const result = handle.db.prepare(sql).run(...params);
      return { changes: Number(result.changes) };
    },

    async getAllAsync<T>(sql: string, params: SqlParams = []) {
      return handle.db.prepare(sql).all(...params) as T[];
    },

    async getFirstAsync<T>(sql: string, params: SqlParams = []) {
      const row = handle.db.prepare(sql).get(...params);
      return (row as T | undefined) ?? null;
    },

    async withTransactionAsync(task) {
      // expo-sqlite flattens nested withTransactionAsync calls onto the
      // outermost transaction; SAVEPOINTs reproduce that here so repository
      // code composes identically in tests and on the home server.
      const isOutermost = depth === 0;
      const savepoint = `sp_${depth}`;
      handle.db.exec(isOutermost ? 'BEGIN' : `SAVEPOINT ${savepoint}`);
      depth += 1;
      try {
        await task();
        depth -= 1;
        handle.db.exec(isOutermost ? 'COMMIT' : `RELEASE ${savepoint}`);
      } catch (error) {
        depth -= 1;
        handle.db.exec(isOutermost ? 'ROLLBACK' : `ROLLBACK TO ${savepoint}`);
        throw error;
      }
    },

    async closeAsync() {
      handle.db.close();
    },

    /**
     * Consistent snapshot of the live database.
     *
     * File-backed connections run `VACUUM INTO` so WAL pages are folded into
     * the copy rather than relying on a checkpoint that another writer could
     * race. In-memory databases serialize in-process.
     */
    snapshotAsync: async () => {
      if (!fileBacked) {
        // `serialize` landed after Node 22's type definitions. File-backed
        // snapshots use VACUUM INTO below, which is what the home server runs.
        const serialize = (handle.db as { serialize?: () => Uint8Array }).serialize;
        if (!serialize) {
          throw new Error('In-memory snapshot requires DatabaseSync.serialize');
        }
        return serialize.call(handle.db);
      }
      const snapshotPath = `${path}.snapshot`;
      unlinkIfPresent(snapshotPath);
      handle.db.exec(`VACUUM INTO ${sqlLiteral(snapshotPath)}`);
      try {
        return readFileSync(snapshotPath);
      } finally {
        unlinkIfPresent(snapshotPath);
      }
    },

    restoreAsync: async (snapshot) => {
      handle.db.close();
      depth = 0;
      if (!fileBacked) {
        handle.db = new DatabaseSync(':memory:');
        const deserialize = (handle.db as { deserialize?: (data: Uint8Array) => void }).deserialize;
        if (!deserialize) {
          throw new Error('In-memory restore requires DatabaseSync.deserialize');
        }
        deserialize.call(handle.db, snapshot);
        applyPragmas(handle.db, false);
        return;
      }
      writeFileSync(path, snapshot);
      unlinkIfPresent(`${path}-wal`);
      unlinkIfPresent(`${path}-shm`);
      handle.db = new DatabaseSync(path);
      applyPragmas(handle.db, true);
    },
  };
}
