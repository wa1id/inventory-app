import { randomFillSync } from 'node:crypto';

import { configureRandomBytes } from '@/core/id';

/**
 * Persistence and ID tests run in plain Node. Wire the same CSPRNG the
 * home-server process will use so `newId` / `newQrToken` exercise their real
 * code path without `expo-crypto`.
 */
configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));
