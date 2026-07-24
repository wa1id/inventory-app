import { DatabaseSync } from 'node:sqlite';

import type { SqlDatabase, SqlParams } from '../types';

/**
 * Test-only `SqlDatabase` backed by Node's built-in SQLite.
 *
 * This exists so persistence tests exercise the real repository SQL — including
 * foreign keys, CHECK constraints, and transaction rollback — against an actual
 * SQL engine. It is never imported by application code.
 */
export function openNodeDatabase(path = ':memory:'): SqlDatabase {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys = ON');

  let depth = 0;

  return {
    async execAsync(sql) {
      db.exec(sql);
    },

    async runAsync(sql, params: SqlParams = []) {
      const result = db.prepare(sql).run(...params);
      return { changes: Number(result.changes) };
    },

    async getAllAsync<T>(sql: string, params: SqlParams = []) {
      return db.prepare(sql).all(...params) as T[];
    },

    async getFirstAsync<T>(sql: string, params: SqlParams = []) {
      const row = db.prepare(sql).get(...params);
      return (row as T | undefined) ?? null;
    },

    async withTransactionAsync(task) {
      // expo-sqlite flattens nested withTransactionAsync calls onto the
      // outermost transaction; SAVEPOINTs reproduce that here so repository
      // code composes identically in tests and on device.
      const isOutermost = depth === 0;
      const savepoint = `sp_${depth}`;
      db.exec(isOutermost ? 'BEGIN' : `SAVEPOINT ${savepoint}`);
      depth += 1;
      try {
        await task();
        depth -= 1;
        db.exec(isOutermost ? 'COMMIT' : `RELEASE ${savepoint}`);
      } catch (error) {
        depth -= 1;
        db.exec(isOutermost ? 'ROLLBACK' : `ROLLBACK TO ${savepoint}`);
        throw error;
      }
    },

    async closeAsync() {
      db.close();
    },
  };
}
