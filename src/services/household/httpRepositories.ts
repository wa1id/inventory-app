import type { Repositories } from '@/db/repositories';
import type { ContainerVisualType, SqlDatabase } from '@/db/types';
import type { CreateContainerInput, UpdateContainerInput } from '@/repositories/containers';
import type { ItemDraft, UpdateItemInput } from '@/repositories/items';
import type { CreateSpaceInput, UpdateSpaceInput } from '@/repositories/spaces';

import { householdRequest, type HouseholdSession } from './client';

function unsupportedDb(): SqlDatabase {
  const fail = () => {
    throw new Error('Local SQLite is not used while paired with the household server.');
  };
  return {
    execAsync: fail,
    runAsync: fail,
    getAllAsync: fail,
    getFirstAsync: fail,
    withTransactionAsync: fail,
    closeAsync: fail,
  };
}

export function createHttpRepositories(
  session: HouseholdSession,
  fetchImpl?: typeof fetch,
): Repositories {
  const call = (
    path: string,
    init: { method?: string; json?: unknown } = {},
  ): Promise<Record<string, unknown>> =>
    householdRequest({
      origin: session.origin,
      token: session.token,
      path,
      fetchImpl,
      ...init,
    });

  return {
    db: unsupportedDb(),

    spaces: {
      async listWithCounts() {
        const body = await call('/v1/spaces');
        return (body.spaces as never) ?? [];
      },
      async getById(id) {
        try {
          return (await call(`/v1/spaces/${id}`)) as never;
        } catch {
          return null;
        }
      },
      async create(input: CreateSpaceInput) {
        return (await call('/v1/spaces', { method: 'POST', json: input })) as never;
      },
      async update(id, input: UpdateSpaceInput) {
        try {
          return (await call(`/v1/spaces/${id}`, { method: 'PATCH', json: input })) as never;
        } catch {
          return null;
        }
      },
      async deletionImpact(id) {
        const space = await this.getById(id);
        const containers = space ? await this.listWithCounts() : [];
        const row = containers.find((item: { id: string }) => item.id === id) as
          { containerCount?: number; itemCount?: number } | undefined;
        return {
          containerCount: row?.containerCount ?? 0,
          itemCount: row?.itemCount ?? 0,
          photoCount: 0,
          qrBindingCount: 0,
        };
      },
      async delete(id) {
        try {
          const body = await call(`/v1/spaces/${id}`, { method: 'DELETE' });
          return {
            deleted: true,
            orphanedPhotoUris: (body.orphanedPhotoUris as string[]) ?? [],
          };
        } catch {
          return { deleted: false, orphanedPhotoUris: [] };
        }
      },
    },

    containers: {
      async listBySpace(spaceId) {
        const body = await call(`/v1/containers?spaceId=${encodeURIComponent(spaceId)}`);
        return (body.containers as never) ?? [];
      },
      async getById(id) {
        try {
          return (await call(`/v1/containers/${id}`)) as never;
        } catch {
          return null;
        }
      },
      async getWithCounts(id) {
        try {
          return (await call(`/v1/containers/${id}`)) as never;
        } catch {
          return null;
        }
      },
      async create(input: CreateContainerInput) {
        return (await call('/v1/containers', {
          method: 'POST',
          json: {
            spaceId: input.spaceId,
            visualType: input.visualType,
            name: input.name,
          },
        })) as never;
      },
      async update(id, input: UpdateContainerInput) {
        try {
          return (await call(`/v1/containers/${id}`, {
            method: 'PATCH',
            json: {
              name: input.name,
              visualType: input.visualType as ContainerVisualType | undefined,
              spaceId: input.spaceId,
            },
          })) as never;
        } catch {
          return null;
        }
      },
      async deletionImpact(id) {
        const container = await this.getWithCounts(id);
        return {
          itemCount: container?.itemCount ?? 0,
          photoCount: 0,
          hasQrBinding: Boolean(container?.qrToken),
        };
      },
      async delete(id) {
        try {
          const body = await call(`/v1/containers/${id}`, { method: 'DELETE' });
          return {
            deleted: true,
            orphanedPhotoUris: (body.orphanedPhotoUris as string[]) ?? [],
          };
        } catch {
          return { deleted: false, orphanedPhotoUris: [] };
        }
      },
      async listAllWithSpace() {
        const body = await call('/v1/containers');
        return (body.containers as never) ?? [];
      },
    },

    items: {
      async listByContainer(containerId) {
        const body = await call(`/v1/items?containerId=${encodeURIComponent(containerId)}`);
        return (body.items as never) ?? [];
      },
      async listUnsorted() {
        const body = await call('/v1/items?unsorted=1');
        return (body.items as never) ?? [];
      },
      async countUnsorted() {
        const items = await this.listUnsorted();
        return items.length;
      },
      async getById(id) {
        try {
          return (await call(`/v1/items/${id}`)) as never;
        } catch {
          return null;
        }
      },
      async create(draft: ItemDraft) {
        return (await call('/v1/items', {
          method: 'POST',
          json: {
            containerId: draft.containerId,
            name: draft.name,
            category: draft.category,
            quantity: draft.quantity,
            notes: draft.notes,
            tags: draft.tags,
          },
        })) as never;
      },
      async update(id, input: UpdateItemInput) {
        try {
          return (await call(`/v1/items/${id}`, { method: 'PATCH', json: input })) as never;
        } catch {
          return null;
        }
      },
      async getPhotos(itemId) {
        const item = await this.getById(itemId);
        if (!item?.photoId || !item.photoUri) return [];
        return [
          {
            id: item.photoId,
            itemId,
            uri: item.photoUri,
            thumbUri: item.photoThumbUri,
            width: null,
            height: null,
            byteSize: null,
            createdAt: item.createdAt,
          },
        ];
      },
      async delete(id) {
        try {
          const body = await call(`/v1/items/${id}`, { method: 'DELETE' });
          return {
            deleted: true,
            orphanedPhotoUris: (body.orphanedPhotoUris as string[]) ?? [],
          };
        } catch {
          return { deleted: false, orphanedPhotoUris: [] };
        }
      },
      async countAll() {
        const spaces = await call('/v1/spaces');
        const list = (spaces.spaces as { itemCount?: number }[]) ?? [];
        return list.reduce((total, space) => total + (space.itemCount ?? 0), 0);
      },
    },

    qr: {
      async resolveScan(raw) {
        return (await call('/v1/qr/scan', { method: 'POST', json: { raw } })) as never;
      },
      async getByContainer(containerId) {
        try {
          const container = (await call(`/v1/containers/${containerId}`)) as {
            id: string;
            qrToken: string | null;
            createdAt: number;
            updatedAt: number;
          };
          if (!container.qrToken) return null;
          return {
            id: container.id,
            token: container.qrToken,
            containerId,
            createdAt: container.createdAt,
            updatedAt: container.updatedAt,
          };
        } catch {
          return null;
        }
      },
      async getByToken() {
        return null;
      },
      async bind(token, containerId) {
        return (await call('/v1/qr/bind', {
          method: 'POST',
          json: { token, containerId },
        })) as never;
      },
      async createAndBind(containerId) {
        return (await call(`/v1/containers/${containerId}/qr`, { method: 'POST' })) as never;
      },
      async unbind(containerId) {
        try {
          await call(`/v1/containers/${containerId}/qr`, { method: 'DELETE' });
          return true;
        } catch {
          return false;
        }
      },
    },

    search: {
      async search(rawQuery) {
        const q = encodeURIComponent(rawQuery);
        return (await call(`/v1/search?q=${q}`)) as never;
      },
      async searchSpaces() {
        return [];
      },
      async searchContainers() {
        return [];
      },
    },
  };
}
