import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import type { SqlDatabase, SqlParams } from './types';

/**
 * File-backed `SqlDatabase` on Node's built-in SQLite.
 *
 * The phone still uses `expo-sqlite`. The home server (and the Jest persistence
 * suite) use this adapter so repositories stay on one SQL dialect. `:memory:`
 * remains valid for tests; a filesystem path is what the household process
 * opens.
 *
 * Snapshots use `VACUUM INTO` rather than `serialize()`, which Node 22 (CI
 * and the Docker image) does not ship.
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

function scratchFile(kind: string): string {
  return join(
    tmpdir(),
    `inventory-${kind}-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}.db`,
  );
}

export function openNodeDatabase(path = ':memory:'): SqlDatabase {
  const fileBacked = path !== ':memory:';
  if (fileBacked) {
    mkdirSync(dirname(path), { recursive: true });
  }

  const handle: { db: DatabaseSync; scratch: string | null } = {
    db: new DatabaseSync(path),
    scratch: null,
  };
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
      if (handle.scratch) {
        unlinkIfPresent(handle.scratch);
        unlinkIfPresent(`${handle.scratch}-wal`);
        unlinkIfPresent(`${handle.scratch}-shm`);
        handle.scratch = null;
      }
    },

    /**
     * Consistent snapshot of the live database.
     *
     * `VACUUM INTO` folds WAL pages into a new file. Works for both a path
     * and `:memory:`, and does not need `DatabaseSync.serialize` (Node 22).
     */
    snapshotAsync: async () => {
      const snapshotPath = scratchFile('snap');
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

      const target = fileBacked ? path : scratchFile('restore');
      writeFileSync(target, snapshot);
      unlinkIfPresent(`${target}-wal`);
      unlinkIfPresent(`${target}-shm`);
      if (!fileBacked) {
        if (handle.scratch) {
          unlinkIfPresent(handle.scratch);
          unlinkIfPresent(`${handle.scratch}-wal`);
          unlinkIfPresent(`${handle.scratch}-shm`);
        }
        handle.scratch = target;
      }
      handle.db = new DatabaseSync(target);
      applyPragmas(handle.db, true);
    },
  };
}
