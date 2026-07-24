import { createContainersRepository } from '@/repositories/containers';
import { createItemsRepository } from '@/repositories/items';
import { createQrRepository } from '@/repositories/qr';
import { createSearchRepository } from '@/repositories/search';
import { createSpacesRepository } from '@/repositories/spaces';

import { migrate } from './migrations';
import type { SqlDatabase } from './types';

export interface Repositories {
  db: SqlDatabase;
  spaces: ReturnType<typeof createSpacesRepository>;
  containers: ReturnType<typeof createContainersRepository>;
  items: ReturnType<typeof createItemsRepository>;
  qr: ReturnType<typeof createQrRepository>;
  search: ReturnType<typeof createSearchRepository>;
}

export function createRepositories(db: SqlDatabase): Repositories {
  return {
    db,
    spaces: createSpacesRepository(db),
    containers: createContainersRepository(db),
    items: createItemsRepository(db),
    qr: createQrRepository(db),
    search: createSearchRepository(db),
  };
}

/** Migrates the database to the latest schema, then wires up repositories. */
export async function initializeRepositories(db: SqlDatabase): Promise<Repositories> {
  await migrate(db);
  return createRepositories(db);
}
