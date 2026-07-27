/**
 * Minimal async SQL surface shared by every persistence backend.
 *
 * `expo-sqlite` implements this shape natively on device; the Node adapter used
 * by the test suite implements the same contract on top of `node:sqlite`. Every
 * repository is written against this interface only, so persistence logic is
 * exercised against a real SQL engine in tests instead of a hand-written mock.
 */
export interface SqlDatabase {
  execAsync(sql: string): Promise<void>;
  runAsync(sql: string, params?: SqlParams): Promise<{ changes: number }>;
  getAllAsync<T>(sql: string, params?: SqlParams): Promise<T[]>;
  getFirstAsync<T>(sql: string, params?: SqlParams): Promise<T | null>;
  withTransactionAsync(task: () => Promise<void>): Promise<void>;
  closeAsync(): Promise<void>;
}

export type SqlValue = string | number | null;
export type SqlParams = SqlValue[];

/** Broad area where things are stored: a room, a garage, an attic. */
export interface Space {
  id: string;
  name: string;
  icon: string;
  color: string;
  createdAt: number;
  updatedAt: number;
}

/** A box, drawer, shelf, or cabinet living inside exactly one space. */
export interface Container {
  id: string;
  spaceId: string;
  name: string | null;
  visualType: ContainerVisualType;
  /** Human-friendly, unique, printed on labels. e.g. "BOX-4F2A". */
  shortCode: string;
  createdAt: number;
  updatedAt: number;
}

export const CONTAINER_VISUAL_TYPES = [
  'box',
  'drawer',
  'shelf',
  'cabinet',
  'bin',
  'bag',
  'crate',
  'other',
] as const;

export type ContainerVisualType = (typeof CONTAINER_VISUAL_TYPES)[number];

/** A single physical thing stored in a container. */
export interface Item {
  id: string;
  containerId: string;
  name: string;
  category: string | null;
  quantity: number;
  estimatedValue: number | null;
  currency: string | null;
  notes: string | null;
  createdAt: number;
  updatedAt: number;
}

/** MVP stores at most one photo per item, but the relation is already 1:N. */
export interface ItemPhoto {
  id: string;
  itemId: string;
  uri: string;
  width: number | null;
  height: number | null;
  byteSize: number | null;
  createdAt: number;
}

export interface Tag {
  id: string;
  name: string;
  normalizedName: string;
  createdAt: number;
}

/** Binds an opaque printed QR token to exactly one container. */
export interface QrBinding {
  id: string;
  token: string;
  containerId: string;
  createdAt: number;
  updatedAt: number;
}

/** Space enriched with the counts the dashboard renders. */
export interface SpaceWithCounts extends Space {
  containerCount: number;
  itemCount: number;
}

/** Container enriched with its item count and QR binding status. */
export interface ContainerWithCounts extends Container {
  itemCount: number;
  qrToken: string | null;
}

/** Item plus the derived data every list row needs. */
export interface ItemWithContext extends Item {
  photoUri: string | null;
  tags: string[];
  spaceId: string;
  spaceName: string;
  spaceIcon: string;
  spaceColor: string;
  containerName: string | null;
  containerShortCode: string;
}
