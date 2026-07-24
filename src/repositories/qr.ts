import { newId, newQrToken } from '@/core/id';
import type { Container, QrBinding, SqlDatabase } from '@/db/types';

interface QrBindingRow {
  id: string;
  token: string;
  container_id: string;
  created_at: number;
  updated_at: number;
}

function toBinding(row: QrBindingRow): QrBinding {
  return {
    id: row.id,
    token: row.token,
    containerId: row.container_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

/**
 * URL form printed into a QR code.
 *
 * Using the app's own scheme means a scan from the system camera deep-links
 * into the app, while the payload still carries nothing but an opaque token.
 */
export const QR_URI_PREFIX = 'inventory://c/';

export function formatQrPayload(token: string): string {
  return `${QR_URI_PREFIX}${token}`;
}

/**
 * Extracts our token from a scanned string, or null if the code is not ours.
 *
 * Accepts both the deep-link form and a bare token so labels printed by other
 * tooling still work, but rejects anything that is not 32 hex characters.
 */
export function parseQrPayload(raw: string): string | null {
  const value = raw.trim();
  const candidate = value.startsWith(QR_URI_PREFIX) ? value.slice(QR_URI_PREFIX.length) : value;

  return /^[0-9a-f]{32}$/i.test(candidate) ? candidate.toLowerCase() : null;
}

export type ScanOutcome =
  | { kind: 'bound'; container: Container; token: string }
  | { kind: 'unknown'; token: string }
  | { kind: 'invalid'; raw: string };

export function createQrRepository(db: SqlDatabase) {
  return {
    /** Resolves a raw scan into something the Scan screen can act on. */
    async resolveScan(raw: string): Promise<ScanOutcome> {
      const token = parseQrPayload(raw);
      if (!token) return { kind: 'invalid', raw };

      const row = await db.getFirstAsync<{
        id: string;
        space_id: string;
        name: string | null;
        visual_type: string;
        short_code: string;
        created_at: number;
        updated_at: number;
      }>(
        `SELECT c.* FROM containers c
           JOIN qr_bindings q ON q.container_id = c.id
          WHERE q.token = ?`,
        [token],
      );

      if (!row) return { kind: 'unknown', token };

      return {
        kind: 'bound',
        token,
        container: {
          id: row.id,
          spaceId: row.space_id,
          name: row.name,
          visualType: row.visual_type as Container['visualType'],
          shortCode: row.short_code,
          createdAt: row.created_at,
          updatedAt: row.updated_at,
        },
      };
    },

    async getByContainer(containerId: string): Promise<QrBinding | null> {
      const row = await db.getFirstAsync<QrBindingRow>(
        'SELECT * FROM qr_bindings WHERE container_id = ? ORDER BY created_at DESC LIMIT 1',
        [containerId],
      );
      return row ? toBinding(row) : null;
    },

    async getByToken(token: string): Promise<QrBinding | null> {
      const row = await db.getFirstAsync<QrBindingRow>(
        'SELECT * FROM qr_bindings WHERE token = ?',
        [token],
      );
      return row ? toBinding(row) : null;
    },

    /**
     * Binds a token to a container, replacing any previous binding on either
     * side.
     *
     * A container has at most one active label and a token points at exactly
     * one container, so both directions are cleared in the same transaction —
     * otherwise a rebind could briefly leave one printed label resolving to two
     * containers.
     */
    async bind(token: string, containerId: string): Promise<QrBinding> {
      const now = Date.now();
      const binding: QrBinding = {
        id: newId(),
        token,
        containerId,
        createdAt: now,
        updatedAt: now,
      };

      await db.withTransactionAsync(async () => {
        await db.runAsync('DELETE FROM qr_bindings WHERE token = ?', [token]);
        await db.runAsync('DELETE FROM qr_bindings WHERE container_id = ?', [containerId]);
        await db.runAsync(
          `INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?)`,
          [binding.id, binding.token, binding.containerId, binding.createdAt, binding.updatedAt],
        );
      });

      return binding;
    },

    /** Generates a fresh token and binds it — used for on-screen QR codes. */
    async createAndBind(containerId: string): Promise<QrBinding> {
      return this.bind(newQrToken(), containerId);
    },

    /** Removes the label association only; the container and items survive. */
    async unbind(containerId: string): Promise<boolean> {
      const result = await db.runAsync('DELETE FROM qr_bindings WHERE container_id = ?', [
        containerId,
      ]);
      return result.changes > 0;
    },
  };
}

export type QrRepository = ReturnType<typeof createQrRepository>;
