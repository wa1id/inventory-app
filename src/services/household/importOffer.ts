import AsyncStorage from '@react-native-async-storage/async-storage';

import type { Repositories } from '@/db/repositories';

const IMPORT_OFFER_KEY = 'household.importOffer.v1';
const JOINED_BEFORE_KEY = 'household.joinedBefore.v1';

/** What this phone had of its own before it first joined, offered for copying in. */
export interface ImportOffer {
  spaces: number;
  items: number;
}

/**
 * Records what this phone holds on its own, just before it joins.
 *
 * The offer to copy a phone's own inventory into the household is decided
 * here, before joining, because once joined every household write is mirrored
 * into the same local database: counting afterwards would offer to "import"
 * shadow copies of the household's own data, and copying them back could
 * overwrite newer household edits (spec R19). A phone that has joined before
 * is never offered again, so leaving and rejoining cannot trigger it either.
 */
export async function snapshotBeforeJoin(
  local: Pick<Repositories, 'spaces' | 'items'>,
): Promise<void> {
  try {
    if ((await AsyncStorage.getItem(JOINED_BEFORE_KEY)) === 'true') return;
    const [spaces, items] = await Promise.all([
      local.spaces.listWithCounts(),
      local.items.countAll(),
    ]);
    if (spaces.length === 0 && items === 0) {
      await AsyncStorage.removeItem(IMPORT_OFFER_KEY);
      return;
    }
    const offer: ImportOffer = { spaces: spaces.length, items };
    await AsyncStorage.setItem(IMPORT_OFFER_KEY, JSON.stringify(offer));
  } catch {
    // No offer is the safe failure: nothing gets copied that should not be.
  }
}

/** Set on joining and on every start with a session, so phones paired before this existed count too. */
export async function markJoinedBefore(): Promise<void> {
  try {
    await AsyncStorage.setItem(JOINED_BEFORE_KEY, 'true');
  } catch {
    // Retried on the next start with a session.
  }
}

export async function readImportOffer(): Promise<ImportOffer | null> {
  try {
    const stored = await AsyncStorage.getItem(IMPORT_OFFER_KEY);
    if (!stored) return null;
    const parsed: unknown = JSON.parse(stored);
    if (
      typeof parsed === 'object' &&
      parsed !== null &&
      'spaces' in parsed &&
      'items' in parsed &&
      typeof parsed.spaces === 'number' &&
      typeof parsed.items === 'number'
    ) {
      return { spaces: parsed.spaces, items: parsed.items };
    }
    return null;
  } catch {
    return null;
  }
}

/** After copying, or when the person says it is not needed. */
export async function clearImportOffer(): Promise<void> {
  try {
    await AsyncStorage.removeItem(IMPORT_OFFER_KEY);
  } catch {
    // The offer may show once more; copying again is an upsert by id.
  }
}
