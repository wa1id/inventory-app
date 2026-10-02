import { useEffect, useMemo, useSyncExternalStore } from 'react';

const SAVED_CATEGORIES_KEY = 'categories.recent.v1';
const MAX_SAVED = 20;
const MAX_SUGGESTIONS = 6;

/**
 * Categories the person has used, for the chips under the Category field.
 *
 * Two sources, neither of them a request of its own: categories seen in item
 * lists the app has already loaded (Home's recent items, search results,
 * container lists), and the last twenty saved on this phone. Fetching a list
 * just to read category names would download every item's photo when paired.
 */

// Saved on this phone, most recent first (persisted).
let saved: string[] = [];
// Seen in loaded lists this session, keyed case-insensitively.
const seen = new Map<string, string>();
let snapshot: readonly string[] = [];
let loading = false;
const listeners = new Set<() => void>();

function key(category: string): string {
  return category.trim().toLowerCase();
}

function publish(): void {
  const all = new Map<string, string>();
  for (const category of saved) all.set(key(category), category);
  const others = [...seen.entries()]
    .filter(([k]) => !all.has(k))
    .sort(([, a], [, b]) => a.localeCompare(b, 'en', { sensitivity: 'base' }));
  for (const [k, category] of others) all.set(k, category);
  snapshot = [...all.values()];
  listeners.forEach((listener) => listener());
}

// AsyncStorage is loaded on first use, so importing this module (and the form
// components that use it) never touches a native module.
async function storage() {
  return (await import('@react-native-async-storage/async-storage')).default;
}

function loadSaved(): void {
  if (loading) return;
  loading = true;
  void (async () => {
    try {
      const stored = await (await storage()).getItem(SAVED_CATEGORIES_KEY);
      const parsed: unknown = stored ? JSON.parse(stored) : [];
      if (!Array.isArray(parsed)) return;
      const restored = parsed.filter((entry): entry is string => typeof entry === 'string');
      // Anything saved while this read was in flight stays in front.
      saved = mergeSaved([...saved, ...restored]);
      publish();
    } catch {
      // No suggestions is fine: the field still takes typing.
    }
  })();
}

function mergeSaved(list: readonly string[]): string[] {
  const out: string[] = [];
  const keys = new Set<string>();
  for (const category of list) {
    const k = key(category);
    if (!k || keys.has(k)) continue;
    keys.add(k);
    out.push(category.trim());
  }
  return out.slice(0, MAX_SAVED);
}

/** Feeds the categories of a list that was loaded anyway. Cheap; call on every result. */
export function rememberCategories(items: readonly { category: string | null }[]): void {
  let changed = false;
  for (const item of items) {
    const category = item.category?.trim();
    if (!category || seen.has(key(category))) continue;
    seen.set(key(category), category);
    changed = true;
  }
  if (changed) publish();
}

/** After an item is saved with a category: it becomes the first suggestion. */
export function recordCategory(category: string | null | undefined): void {
  const trimmed = category?.trim();
  if (!trimmed) return;
  saved = mergeSaved([trimmed, ...saved]);
  publish();
  void (async () => {
    try {
      await (await storage()).setItem(SAVED_CATEGORIES_KEY, JSON.stringify(saved));
    } catch {
      // Only the suggestion is lost.
    }
  })();
}

/**
 * Known categories that start with `prefix` (case-insensitive), without an
 * exact match, each once and trimmed.
 */
export function suggestCategories(
  categories: readonly string[],
  prefix: string,
  max: number = MAX_SUGGESTIONS,
): string[] {
  const typed = key(prefix);
  const offered = new Set<string>();
  const matches: string[] = [];
  for (const category of categories) {
    const k = key(category);
    if (!k || k === typed || offered.has(k) || !k.startsWith(typed)) continue;
    offered.add(k);
    matches.push(category.trim());
    if (matches.length === max) break;
  }
  return matches;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Every known category: saved on this phone first, then the rest alphabetically. */
export function useKnownCategories(): readonly string[] {
  const categories = useSyncExternalStore(
    subscribe,
    () => snapshot,
    () => snapshot,
  );
  useEffect(loadSaved, []);
  return categories;
}

/** Up to six categories for the chips under a Category field holding `prefix`. */
export function useCategorySuggestions(prefix: string): string[] {
  const categories = useKnownCategories();
  return useMemo(() => suggestCategories(categories, prefix), [categories, prefix]);
}
