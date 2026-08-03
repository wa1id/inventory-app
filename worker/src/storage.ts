import {
  BACKUP_RETENTION,
  MAX_ACCOUNT_BYTES,
  accountPrefixes,
  backupPrefix,
  usageKey,
} from './contract.ts';

export interface Usage {
  bytes: number;
  objects: number;
}

/**
 * Per-account usage, kept as a counter object rather than recomputed per write.
 *
 * Summing a full listing on every upload would cost a paginated scan per photo.
 * The counter is one small read and one small write instead. It can drift if
 * two writes race — realistic only if someone runs the same recovery code on
 * two devices at once — so it is treated as advisory: it gates new writes and
 * is rebuilt from the authoritative listing whenever it is missing.
 */
export async function readUsage(env: Env, accountId: string): Promise<Usage> {
  const object = await env.BUCKET.get(usageKey(accountId));
  if (!object) return recomputeUsage(env, accountId);

  try {
    const parsed = (await object.json()) as Partial<Usage>;
    if (typeof parsed.bytes !== 'number' || typeof parsed.objects !== 'number') {
      return recomputeUsage(env, accountId);
    }
    return { bytes: parsed.bytes, objects: parsed.objects };
  } catch {
    return recomputeUsage(env, accountId);
  }
}

/** Rebuilds the counter from what is actually stored. */
export async function recomputeUsage(env: Env, accountId: string): Promise<Usage> {
  let bytes = 0;
  let objects = 0;

  for (const prefix of accountPrefixes(accountId)) {
    let cursor: string | undefined;
    do {
      const page = await env.BUCKET.list({ prefix, cursor, limit: 1000 });
      for (const object of page.objects) {
        bytes += object.size;
        objects += 1;
      }
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  }

  const usage: Usage = { bytes, objects };
  await writeUsage(env, accountId, usage);
  return usage;
}

async function writeUsage(env: Env, accountId: string, usage: Usage): Promise<void> {
  await env.BUCKET.put(usageKey(accountId), JSON.stringify(usage), {
    httpMetadata: { contentType: 'application/json' },
  });
}

export async function applyUsageDelta(
  env: Env,
  accountId: string,
  deltaBytes: number,
  deltaObjects: number,
): Promise<void> {
  const current = await readUsage(env, accountId);
  await writeUsage(env, accountId, {
    // Clamp at zero: a drifted counter should not go negative and hand out
    // unlimited quota.
    bytes: Math.max(0, current.bytes + deltaBytes),
    objects: Math.max(0, current.objects + deltaObjects),
  });
}

export type QuotaResult = { ok: true } | { ok: false; error: string };

/** Checks a pending write against the account's remaining quota. */
export async function checkQuota(
  env: Env,
  accountId: string,
  incomingBytes: number,
  replacingBytes: number,
): Promise<QuotaResult> {
  const usage = await readUsage(env, accountId);
  const projected = usage.bytes - replacingBytes + incomingBytes;

  if (projected > MAX_ACCOUNT_BYTES) {
    return { ok: false, error: 'Storage limit reached for this account.' };
  }
  return { ok: true };
}

/** Size of an existing object, or 0 when there is nothing to replace. */
export async function existingSize(env: Env, key: string): Promise<number> {
  const head = await env.BUCKET.head(key);
  return head?.size ?? 0;
}

/**
 * Drops snapshots beyond the retention window, oldest first.
 *
 * Sorted numerically rather than lexicographically: the ids are epoch millis,
 * and string ordering would silently break the day the digit count changes.
 */
export async function pruneBackups(
  env: Env,
  accountId: string,
  retention: number = BACKUP_RETENTION,
): Promise<number> {
  const prefix = backupPrefix(accountId);
  const listed: { key: string; size: number; id: number }[] = [];

  let cursor: string | undefined;
  do {
    const page = await env.BUCKET.list({ prefix, cursor, limit: 1000 });
    for (const object of page.objects) {
      const id = Number(object.key.slice(prefix.length).replace(/\.db$/, ''));
      if (Number.isFinite(id)) listed.push({ key: object.key, size: object.size, id });
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);

  listed.sort((a, b) => b.id - a.id);
  const expired = listed.slice(retention);
  if (expired.length === 0) return 0;

  await env.BUCKET.delete(expired.map((object) => object.key));
  await applyUsageDelta(
    env,
    accountId,
    -expired.reduce((total, object) => total + object.size, 0),
    -expired.length,
  );

  return expired.length;
}
