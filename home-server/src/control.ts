import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

import { newId } from '../../src/core/id.ts';
import { openNodeDatabase } from '../../src/db/nodeDatabase.ts';
import type { SqlDatabase } from '../../src/db/types.ts';

import { decodeBase32, encodeBase32, formatSecret } from './base32.ts';

import { BOOTSTRAP_SECRET_BYTES, DEVICE_TOKEN_BYTES, HOUSEHOLD_NAME } from './contract.ts';

export interface Device {
  id: string;
  name: string;
  createdAt: number;
  lastSeenAt: number | null;
}

export interface PairingResult {
  deviceId: string;
  token: string;
  householdName: string;
}

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS household (
    id              TEXT PRIMARY KEY NOT NULL,
    name            TEXT NOT NULL,
    bootstrap_hash  TEXT NOT NULL,
    created_at      INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS devices (
    id            TEXT PRIMARY KEY NOT NULL,
    name          TEXT NOT NULL,
    token_hash    TEXT NOT NULL UNIQUE,
    created_at    INTEGER NOT NULL,
    last_seen_at  INTEGER
  );
`;

function sha256Hex(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function hashesEqual(leftHex: string, rightHex: string): boolean {
  const left = Buffer.from(leftHex, 'hex');
  const right = Buffer.from(rightHex, 'hex');
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

export function normalizeBootstrapSecret(input: string): Uint8Array | null {
  const decoded = decodeBase32(input);
  if (!decoded || decoded.length !== BOOTSTRAP_SECRET_BYTES) return null;
  return decoded;
}

export interface ControlStore {
  /** Plaintext secret, formatted, only when this process created the household. */
  bootstrapSecretToPrint: string | null;
  pair(bootstrapSecret: string, deviceName: string): Promise<PairingResult | null>;
  listDevices(): Promise<Device[]>;
  getDevice(id: string): Promise<Device | null>;
  findDeviceByToken(token: string): Promise<Device | null>;
  touch(deviceId: string): Promise<void>;
  revoke(deviceId: string): Promise<boolean>;
  /** Consistent SQLite snapshot via VACUUM INTO. Never includes BOOTSTRAP.txt. */
  snapshot(): Promise<Uint8Array>;
  close(): Promise<void>;
}

export async function openControlStore(dbPath: string): Promise<ControlStore> {
  const db = openNodeDatabase(dbPath);
  await db.execAsync(SCHEMA);
  const bootstrapSecretToPrint = await ensureHousehold(db);

  return {
    bootstrapSecretToPrint,

    async pair(bootstrapSecret, deviceName) {
      const secret = normalizeBootstrapSecret(bootstrapSecret);
      if (!secret) return null;

      const household = await db.getFirstAsync<{ bootstrap_hash: string; name: string }>(
        'SELECT bootstrap_hash, name FROM household LIMIT 1',
      );
      if (!household) return null;
      if (!hashesEqual(household.bootstrap_hash, sha256Hex(secret))) return null;

      const name = deviceName.trim();
      if (!name) return null;

      const tokenBytes = randomBytes(DEVICE_TOKEN_BYTES);
      const token = tokenBytes.toString('hex');
      const now = Date.now();
      const deviceId = newId();

      await db.runAsync(
        `INSERT INTO devices (id, name, token_hash, created_at, last_seen_at)
         VALUES (?, ?, ?, ?, ?)`,
        [deviceId, name, sha256Hex(tokenBytes), now, now],
      );

      return { deviceId, token, householdName: household.name };
    },

    async listDevices() {
      const rows = await db.getAllAsync<{
        id: string;
        name: string;
        created_at: number;
        last_seen_at: number | null;
      }>('SELECT id, name, created_at, last_seen_at FROM devices ORDER BY created_at ASC');
      return rows.map(toDevice);
    },

    async getDevice(id) {
      const row = await db.getFirstAsync<{
        id: string;
        name: string;
        created_at: number;
        last_seen_at: number | null;
      }>('SELECT id, name, created_at, last_seen_at FROM devices WHERE id = ?', [id]);
      return row ? toDevice(row) : null;
    },

    async findDeviceByToken(token) {
      const bytes = parseToken(token);
      if (!bytes) return null;
      const row = await db.getFirstAsync<{
        id: string;
        name: string;
        created_at: number;
        last_seen_at: number | null;
      }>('SELECT id, name, created_at, last_seen_at FROM devices WHERE token_hash = ?', [
        sha256Hex(bytes),
      ]);
      return row ? toDevice(row) : null;
    },

    async touch(deviceId) {
      await db.runAsync('UPDATE devices SET last_seen_at = ? WHERE id = ?', [Date.now(), deviceId]);
    },

    async revoke(deviceId) {
      const result = await db.runAsync('DELETE FROM devices WHERE id = ?', [deviceId]);
      return result.changes > 0;
    },

    async snapshot() {
      if (!db.snapshotAsync) {
        throw new Error('Control store cannot snapshot on this backend.');
      }
      return db.snapshotAsync();
    },

    async close() {
      await db.closeAsync();
    },
  };
}

async function ensureHousehold(db: SqlDatabase): Promise<string | null> {
  const existing = await db.getFirstAsync<{ id: string }>('SELECT id FROM household LIMIT 1');
  if (existing) return null;

  const secret = randomBytes(BOOTSTRAP_SECRET_BYTES);
  await db.runAsync(
    `INSERT INTO household (id, name, bootstrap_hash, created_at) VALUES (?, ?, ?, ?)`,
    [newId(), HOUSEHOLD_NAME, sha256Hex(secret), Date.now()],
  );
  return formatSecret(encodeBase32(secret));
}

function parseToken(token: string): Uint8Array | null {
  const normalized = token.trim().toLowerCase();
  if (!/^[0-9a-f]+$/.test(normalized) || normalized.length !== DEVICE_TOKEN_BYTES * 2) {
    return null;
  }
  return Buffer.from(normalized, 'hex');
}

function toDevice(row: {
  id: string;
  name: string;
  created_at: number;
  last_seen_at: number | null;
}): Device {
  return {
    id: row.id,
    name: row.name,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
  };
}
