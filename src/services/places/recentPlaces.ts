import AsyncStorage from '@react-native-async-storage/async-storage';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';

const RECENT_PLACES_KEY = 'places.recent.v1';

/** How many recent containers are kept; pickers show fewer. */
export const MAX_RECENT_PLACES = 6;

/**
 * `id` moved to the front of `list`, without duplicates, capped at `max`.
 *
 * The drop zone is never a recent place: it is always offered on its own, so
 * remembering it would only push a real container out of the list.
 */
export function mergeRecent(
  list: readonly string[],
  id: string,
  max: number = MAX_RECENT_PLACES,
): string[] {
  const rest = list.filter((entry) => entry !== id && entry !== DROP_ZONE_CONTAINER_ID);
  return (id === DROP_ZONE_CONTAINER_ID ? rest : [id, ...rest]).slice(0, max);
}

// Kept in memory once read, so every picker on screen agrees without each
// re-reading storage, and a place remembered now shows up in the next picker.
let cache: string[] | null = null;
const listeners = new Set<() => void>();

function publish(next: string[]): void {
  cache = next;
  listeners.forEach((listener) => listener());
}

/**
 * Containers this phone last added to, moved to, filed in or bound a label
 * to, most recent first. A preference, not inventory, so it lives in
 * AsyncStorage per phone; anything unreadable is simply an empty list.
 */
export async function readRecentPlaces(): Promise<string[]> {
  if (cache) return cache;
  try {
    const stored = await AsyncStorage.getItem(RECENT_PLACES_KEY);
    const parsed: unknown = stored ? JSON.parse(stored) : [];
    const ids = Array.isArray(parsed)
      ? parsed.filter((entry): entry is string => typeof entry === 'string')
      : [];
    // A place remembered while this read was in flight wins over storage.
    if (!cache) publish(ids.slice(0, MAX_RECENT_PLACES));
  } catch {
    if (!cache) publish([]);
  }
  return cache ?? [];
}

/** Call after a successful Add, Move, File, label bind or new-container pick. */
export async function rememberPlace(containerId: string): Promise<void> {
  if (containerId === DROP_ZONE_CONTAINER_ID) return;
  const next = mergeRecent(cache ?? (await readRecentPlaces()), containerId);
  publish(next);
  try {
    await AsyncStorage.setItem(RECENT_PLACES_KEY, JSON.stringify(next));
  } catch {
    // Only the shortcut is lost; the write it followed already succeeded.
  }
}

/** The list as last read, or null before the first read finishes. */
export function peekRecentPlaces(): string[] | null {
  return cache;
}

export function subscribeRecentPlaces(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
