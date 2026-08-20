import { newId } from '@/core/id';
import type { Repositories } from '@/db/repositories';
import type { ContainerVisualType, ItemWithContext, SqlDatabase } from '@/db/types';
import type { CreateContainerInput, UpdateContainerInput } from '@/repositories/containers';
import type { ItemDraft, UpdateItemInput } from '@/repositories/items';
import type { CreateSpaceInput, UpdateSpaceInput } from '@/repositories/spaces';

import { HouseholdHttpError, householdRequest, type HouseholdSession } from './client';
import { rememberHouseholdPhoto, resolveHouseholdPhoto } from './photoCache';

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
  readPhoto?: (uri: string) => Promise<Uint8Array | null>,
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

  async function callIgnoring404(
    path: string,
    init: { method?: string; json?: unknown } = {},
  ): Promise<Record<string, unknown> | null> {
    try {
      return await call(path, init);
    } catch (error) {
      if (error instanceof HouseholdHttpError && error.status === 404) return null;
      throw error;
    }
  }

  /**
   * Photo bytes go as raw octets — the same path import already used on device.
   * React Native cannot build a `File`/`Blob` from an ArrayBuffer view, and its
   * FormData `{ uri, name, type }` descriptor still fails under `fetch`.
   */
  async function uploadHouseholdPhoto(
    uri: string,
    read: (uri: string) => Promise<Uint8Array | null>,
  ) {
    const bytes = await read(uri);
    if (!bytes) throw new HouseholdHttpError(0, 'photo_missing');
    const uploaded = await householdRequest({
      origin: session.origin,
      token: session.token,
      path: `/v1/photos/${encodeURIComponent(newId())}`,
      method: 'PUT',
      bytes,
      fetchImpl,
      timeoutMs: 60_000,
    });
    if (typeof uploaded.id !== 'string' || typeof uploaded.uri !== 'string') {
      throw new HouseholdHttpError(500, 'invalid_response');
    }
    return {
      id: uploaded.id,
      uri: uploaded.uri,
      thumbUri: typeof uploaded.thumbUri === 'string' ? uploaded.thumbUri : undefined,
      width: typeof uploaded.width === 'number' ? uploaded.width : undefined,
      height: typeof uploaded.height === 'number' ? uploaded.height : undefined,
      byteSize: typeof uploaded.byteSize === 'number' ? uploaded.byteSize : undefined,
    };
  }

  async function hydrateItem(item: ItemWithContext): Promise<ItemWithContext> {
    if (!item.photoId) return item;
    if (item.photoUri?.startsWith('file:')) return item;
    const [full, thumb] = await Promise.all([
      resolveHouseholdPhoto({ session, photoId: item.photoId, kind: 'full', fetchImpl }),
      resolveHouseholdPhoto({ session, photoId: item.photoId, kind: 'thumb', fetchImpl }),
    ]);
    return {
      ...item,
      photoUri: full ?? item.photoUri,
      photoThumbUri: thumb ?? item.photoThumbUri,
    };
  }

  async function hydrateItems(items: ItemWithContext[]): Promise<ItemWithContext[]> {
    return Promise.all(items.map((item) => hydrateItem(item)));
  }

  return {
    db: unsupportedDb(),

    spaces: {
      async listWithCounts() {
        const body = await call('/v1/spaces');
        return (body.spaces as never) ?? [];
      },
      async getById(id) {
        const body = await callIgnoring404(`/v1/spaces/${id}`);
        return (body as never) ?? null;
      },
      async create(input: CreateSpaceInput) {
        return (await call('/v1/spaces', { method: 'POST', json: input })) as never;
      },
      async update(id, input: UpdateSpaceInput) {
        const body = await callIgnoring404(`/v1/spaces/${id}`, { method: 'PATCH', json: input });
        return (body as never) ?? null;
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
        const body = await callIgnoring404(`/v1/spaces/${id}`, { method: 'DELETE' });
        if (!body) return { deleted: false, orphanedPhotoUris: [] };
        return {
          deleted: true,
          orphanedPhotoUris: (body.orphanedPhotoUris as string[]) ?? [],
        };
      },
    },

    containers: {
      async listBySpace(spaceId) {
        const body = await call(`/v1/containers?spaceId=${encodeURIComponent(spaceId)}`);
        return (body.containers as never) ?? [];
      },
      async getById(id) {
        const body = await callIgnoring404(`/v1/containers/${id}`);
        return (body as never) ?? null;
      },
      async getWithCounts(id) {
        const body = await callIgnoring404(`/v1/containers/${id}`);
        return (body as never) ?? null;
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
        const body = await callIgnoring404(`/v1/containers/${id}`, {
          method: 'PATCH',
          json: {
            name: input.name,
            visualType: input.visualType as ContainerVisualType | undefined,
            spaceId: input.spaceId,
          },
        });
        return (body as never) ?? null;
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
        const body = await callIgnoring404(`/v1/containers/${id}`, { method: 'DELETE' });
        if (!body) return { deleted: false, orphanedPhotoUris: [] };
        return {
          deleted: true,
          orphanedPhotoUris: (body.orphanedPhotoUris as string[]) ?? [],
        };
      },
      async listAllWithSpace() {
        const body = await call('/v1/containers');
        return (body.containers as never) ?? [];
      },
    },

    items: {
      async listByContainer(containerId) {
        const body = await call(`/v1/items?containerId=${encodeURIComponent(containerId)}`);
        return hydrateItems(
          ((body.items as ItemWithContext[]) ?? []) as ItemWithContext[],
        ) as never;
      },
      async listUnsorted() {
        const body = await call('/v1/items?unsorted=1');
        return hydrateItems(
          ((body.items as ItemWithContext[]) ?? []) as ItemWithContext[],
        ) as never;
      },
      async listRecent(limit = 40) {
        const body = await call(`/v1/items?recent=1&limit=${encodeURIComponent(String(limit))}`);
        return hydrateItems(
          ((body.items as ItemWithContext[]) ?? []) as ItemWithContext[],
        ) as never;
      },
      async countUnsorted() {
        const items = await this.listUnsorted();
        return items.length;
      },
      async getById(id) {
        const body = await callIgnoring404(`/v1/items/${id}`);
        if (!body) return null;
        return (await hydrateItem(body as unknown as ItemWithContext)) as never;
      },
      async create(draft: ItemDraft) {
        const photo = draft.photo?.uri
          ? await uploadHouseholdPhoto(draft.photo.uri, readPhoto ?? readStoredPhoto)
          : null;
        const created = await call('/v1/items', {
          method: 'POST',
          json: {
            containerId: draft.containerId,
            name: draft.name,
            category: draft.category,
            quantity: draft.quantity,
            notes: draft.notes,
            tags: draft.tags,
            ...(photo ? { photo } : {}),
          },
        });
        const photoId = typeof created.photoId === 'string' ? created.photoId : (photo?.id ?? null);
        if (photoId && draft.photo?.uri) {
          await rememberHouseholdPhoto(photoId, draft.photo.uri, draft.photo.thumbUri);
        }
        return created as never;
      },
      async update(id, input: UpdateItemInput) {
        const body = await callIgnoring404(`/v1/items/${id}`, {
          method: 'PATCH',
          json: {
            containerId: input.containerId,
            name: input.name,
            category: input.category,
            quantity: input.quantity,
            notes: input.notes,
            tags: input.tags,
            ...(input.expectedUpdatedAt !== undefined
              ? { updatedAt: input.expectedUpdatedAt }
              : {}),
          },
        });
        return (body as never) ?? null;
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
        const body = await callIgnoring404(`/v1/items/${id}`, { method: 'DELETE' });
        if (!body) return { deleted: false, orphanedPhotoUris: [] };
        return {
          deleted: true,
          orphanedPhotoUris: (body.orphanedPhotoUris as string[]) ?? [],
        };
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
        const container = (await callIgnoring404(`/v1/containers/${containerId}`)) as {
          id: string;
          qrToken: string | null;
          createdAt: number;
          updatedAt: number;
        } | null;
        if (!container?.qrToken) return null;
        return {
          id: container.id,
          token: container.qrToken,
          containerId,
          createdAt: container.createdAt,
          updatedAt: container.updatedAt,
        };
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
        const body = await callIgnoring404(`/v1/containers/${containerId}/qr`, {
          method: 'DELETE',
        });
        return body !== null;
      },
    },

    search: {
      async search(rawQuery) {
        const body = await call(`/v1/search?q=${encodeURIComponent(rawQuery)}`);
        const items = Array.isArray(body.items) ? (body.items as ItemWithContext[]) : [];
        return { ...body, items: await hydrateItems(items) } as never;
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

async function readStoredPhoto(uri: string): Promise<Uint8Array | null> {
  const { readStoredPhoto: read } = await import('@/services/capture/imageStore');
  return read(uri);
}
