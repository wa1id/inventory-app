# 03 — Personal backup / sync and the recovery-code account

Porting spec for the native iOS app (Swift 6, SwiftUI, iOS 26+, GRDB). It covers
the opt-in off-device backup: the recovery-code "account", the HTTP contract with
the Cloudflare Worker (`worker/`), whole-database snapshots, restore, the photo
upload/delete/rehydrate queue, the background pass that drives it, and the Backup
screen.

You should be able to implement everything here without reading the TypeScript.
Every behaviour cites `path:line`, relative to the repo root.

> **Status of the server side:** `worker/` does not change. The native app must
> stay byte-compatible with it. Section 4 is the contract. It includes the server
> behaviour that decides how each client error is classified.

---

## 0. Source files in scope

| File | Role |
| --- | --- |
| `src/services/sync/contract.ts` (76 lines) | Wire constants, `SyncFailureReason`, `SyncResult`, list-response validation |
| `src/services/sync/client.ts` (211) | HTTP client: one function per endpoint, failure classification |
| `src/services/sync/backup.ts` (159) | Snapshot + upload, 15-minute gate, restore |
| `src/services/sync/photoSync.ts` (192) | Photo upload queue, deletion tombstones, rehydration after restore |
| `src/services/account/base32.ts` (84) | Crockford base32 encode/decode/format (mirrors `worker/src/base32.ts`) |
| `src/services/account/identity.ts` (134) | Secret generation, keychain persistence, account-id derivation |
| `src/providers/SyncProvider.tsx` (233) | Sync state machine, triggers, actions exposed to the UI |
| `app/backup.tsx` (400) | Backup screen |
| `worker/src/index.ts` (458) | Worker router and handlers |
| `worker/src/contract.ts` (149) | Server constants, R2 key layout, id validators |
| `worker/src/auth.ts` (127) | `x-inventory-key` gate, bearer-code auth, account-id derivation |
| `worker/src/storage.ts` (142) | Usage counter, quota, backup retention |
| `worker/src/base32.ts` (83) | Server copy of the base32 codec |
| `worker/README.md` (115) | Service documentation |

Supporting files read because the area depends on them:

- `src/services/config.ts`
- `src/db/expoDatabase.ts`
- `src/db/types.ts`
- `src/db/migrations.ts`
- `src/services/capture/imageStore.ts`
- `src/core/bytes.ts`
- `src/core/id.ts`
- `src/ui/code.ts`
- `src/ui/household/join.ts`
- `src/ui/household/status.ts`
- `src/ui/a11y.ts`
- `src/ui/components/CodeInput.tsx`
- `src/ui/confirm.ts`
- `src/hooks/useNow.ts`
- `src/i18n/format.ts`
- `src/i18n/strings.ts`
- `app/settings.tsx`
- `app/_layout.tsx`
- `src/services/household/importHousehold.ts`
- `src/services/household/shadow.ts`
- `src/repositories/items.ts`
- `node_modules/expo-secure-store/ios/*.swift`
- `node_modules/@react-native-async-storage/async-storage/apple/legacy_storage/RNCAsyncStorage.mm`
- `node_modules/react-native/Libraries/Network/fetch.js`, `node_modules/whatwg-fetch/dist/fetch.umd.js` (RN `fetch` semantics: timeout window, error names)
- `src/providers/DatabaseProvider.tsx` (`repos` identity, `invalidate`)
- `src/services/telemetry/index.ts` (payload allowlist)
- `src/services/household/httpRepositories.ts`, `src/services/household/photoCache.ts` (shadow photo URIs)
- `src/db/nodeDatabase.ts`, `src/db/__tests__/nodeDatabase.test.ts`
- `ios/Inventory/Inventory.entitlements`, `app.json`
- `eas.json`
- `.env.example`

---

## 1. Overview

- **Opt-in.** Backup is off until the user taps "Turn on backup" (`src/providers/SyncProvider.tsx:28-35`, `:60-62`). With no endpoint configured, the feature is `unavailable` and the app is purely local.
- **No account system.** "Turn on" generates 16 random bytes and stores them in the keychain. They are shown to the user as a 26-character Crockford base32 **recovery code**. The code is the bearer credential on every request. The server hashes it into an account id, which becomes an R2 key prefix (`src/services/account/identity.ts:9-29`, `worker/README.md:15-42`). If the user loses the code, the backup is gone.
- **The device is authoritative.** Photos are always read from disk. Remote copies only matter when the disk is gone (`src/services/sync/photoSync.ts:11-23`).
- **Background pass** (on launch once both the account and the database are ready, after an account is created, and on every return to the foreground; there are no timers; §8.3):
  1. Upload up to 10 unsynced photos (rows whose file is missing are deleted and still count toward the 10).
  2. Process up to 10 deletion tombstones.
  3. Re-download up to 10 missing synced photos.
  4. Upload a whole-database snapshot if 15 minutes have passed since the last one.

  Source: `src/providers/SyncProvider.tsx:97-123`, `src/services/sync/photoSync.ts:171-192`, `src/services/sync/backup.ts:98-106`.
- **Failures are values.** Every network call resolves to `SyncResult<T>`, never a throw (`src/services/sync/contract.ts:31-53`, `src/services/sync/client.ts:20-30`).

Suggested native decomposition:

- `RecoveryCode`: pure codec.
- `AccountStore`: keychain.
- `SyncClient`: URLSession, `Sendable`.
- `BackupService`: snapshot, upload, restore.
- `PhotoSyncService`
- `SyncEngine`: an `actor` that owns the "pass in flight" guard, plus a `@MainActor @Observable` facade that publishes `SyncStatus`.
- `BackupView`

---

## 2. Configuration

| Setting | RN source | Value / rule |
| --- | --- | --- |
| `syncEndpoint` | `src/services/config.ts:69` | `EXPO_PUBLIC_SYNC_URL`, trimmed, trailing `/` stripped (`replace(/\/+$/, '')`). An empty value means `nil`, and backup is **unavailable**. Production: `https://inventory-sync.wyachou95.workers.dev` (`eas.json:35`). |
| `syncKey` | `src/services/config.ts:70` | `EXPO_PUBLIC_SYNC_KEY`, trimmed. Empty means `nil`, and the `x-inventory-key` header is omitted. The value is **not** in `eas.json`; see open question Q1. It ships in the bundle and is public (`src/services/config.ts:35-43`). |
| `syncTimeoutMs` | `src/services/config.ts:71` | `Number(EXPO_PUBLIC_SYNC_TIMEOUT_MS ?? 60_000)`, so the default is **60 000 ms** (`.env.example:43-45` sets the same value). Production `eas.json` does not set it. JS quirk not to copy: a variable that is defined but empty gives `Number("") = 0`, which aborts every request at once. Natively, use a constant 60 s, or a build setting that falls back to 60 s when it is missing or ≤ 0. |

Other configuration rules:

- **HTTPS required.** The endpoint must be HTTPS in any shipped build, because the recovery code travels as a bearer token (`.env.example:26-29`).
- **Local development** uses `http://localhost:8787`. Natively, allow it only in Debug via `NSAppTransportSecurity › NSAllowsLocalNetworking`.
- **No per-request override.** The RN client lets tests inject `endpoint`, `fetchImpl` and `timeoutMs` (`src/services/sync/client.ts:12-18`, `:31-34`). The native `SyncClient` should take an endpoint, a `URLSession`/transport and a timeout through its initializer so it can be tested.

---

## 3. Recovery code and account identity

### 3.1 Constants

| Name | Value | Source |
| --- | --- | --- |
| `SECRET_BYTES` | 16 | `src/services/sync/contract.ts:16`, `worker/src/contract.ts:17` |
| `RECOVERY_CODE_LENGTH` | 26 | `src/services/sync/contract.ts:17`, `worker/src/contract.ts:18` |
| Alphabet | `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (32 symbols; no I, L, O, U) | `src/services/account/base32.ts:15`, `worker/src/base32.ts:15` |
| UI code length | `CODE_LENGTH = 26` | `src/ui/household/join.ts:12` |

### 3.2 Encode (`encodeBase32`, `src/services/account/base32.ts:29-49`)

This is an MSB-first bit stream with no padding characters:

```
buffer = 0; bits = 0; out = ""
for byte in bytes:
    buffer = (buffer << 8) | byte; bits += 8
    while bits >= 5:
        bits -= 5
        out += ALPHABET[(buffer >> bits) & 0x1F]
if bits > 0:
    out += ALPHABET[(buffer << (5 - bits)) & 0x1F]   // left-align remainder
```

- 16 bytes is 128 bits. That makes 25 full symbols plus 1 symbol carrying the last 3 bits, shifted left 2. The result is always **26 characters**. The last character is one of `0 4 8 C G M R W` (value ≡ 0 mod 4).
- **Swift:** JavaScript's `<<` truncates to 32 bits, and only the low `bits` (≤ 12) are ever read. Use `UInt32` and mask with `buffer &= 0xFFF` after each extraction, or use `&<<`. Swift shifts do not trap, but keep the buffer bounded anyway.

### 3.3 Decode (`decodeBase32`, `src/services/account/base32.ts:58-79`)

The server copy is identical (`worker/src/base32.ts:57-78`). Normalisation happens in this exact order:

1. Remove **every** `-` (`replace(/-/g, '')`).
2. `trim()`, which strips leading and trailing whitespace only. Inner spaces are **invalid**. JS `trim()` strips Unicode white space **and line terminators** (`\n`, `\r`, U+2028/9) **and U+FEFF**. In Swift, use `.whitespacesAndNewlines` (and add U+FEFF for exact parity), not `.whitespaces`. Verified: `decode("\n" + code + "\n")`, `decode("\u{00A0}" + code)` and `decode("\u{FEFF}" + code)` all return 16 bytes in JS.
3. `toUpperCase()`.
4. If the result is empty, return `nil`.

Then, for each character:

- `digit = DECODE_MAP[c]`. The map is the 32 alphabet symbols plus three folds: **`I`→1, `L`→1, `O`→0** (`:18-27`).
- Any other character (including `U`, punctuation and inner whitespace) makes the whole decode return `nil`.
- `buffer = (buffer << 5) | digit; bits += 5; if bits >= 8 { bits -= 8; out.append((buffer >> bits) & 0xFF) }`
- Leftover bits (< 8) are **discarded silently**.

Consequences the Swift port must keep:

- **Output length.** A *non-empty* string of valid characters always decodes, to `floor(5·n / 8)` bytes. A 1-character input gives **0 bytes, not `nil`**. Length checks are the caller's job.
- **27 characters is accepted.** Both 26 and **27** characters decode to 16 bytes (130 and 135 bits). `importAccount` and the server's `authenticate` therefore accept a 27-character code. The UI rejects it, because `codeProblem` requires exactly 26.
- **Trailing-character aliases.** The low 2 bits of the 26th character are ignored, so `…8`, `…9`, `…A` and `…B` decode to the same secret. `importAccount` stores the canonical re-encoding (§3.7).
- **Case-insensitive** through upper-casing. JavaScript's `toUpperCase` is Unicode-aware (`'ı'.toUpperCase() === 'I'`). Swift's `uppercased()` behaves the same, which keeps parity. Consider restricting to ASCII after upper-casing; it makes no difference for real codes.

### 3.4 Display format

**Grouped code.** `formatRecoveryCode(code)` splits into chunks of 5 and joins them with `-` (`src/services/account/base32.ts:82-84`, `worker/src/base32.ts:81-83`).

- 26 characters become `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-X` (31 characters).
- An empty input gives `""`.

**Spoken form for VoiceOver.** `spellCode(formatted)` (`src/ui/a11y.ts:23-29`):

- Split on `-`.
- Within each group, trim and join the characters with a single space.
- Drop empty groups.
- Join the groups with `", "`.

Example: `89144-GJ289-…` becomes `"8 9 1 4 4, G J 2 8 9, …"`.

### 3.5 Normalisation and validation while typing (UI, not the codec)

These run on the Backup screen's code field, before the codec ever sees the input (`src/ui/code.ts`, `src/ui/household/join.ts`).

- **`normaliseCode(input)`** (`src/ui/code.ts:14-20`), applied to the input on **every change**:
  1. Remove all runs of whitespace or `-` (`/[\s-]+/g`). This includes pasted newlines and tabs.
  2. `toUpperCase()`.
  3. Replace `I` and `L` with `1`.
  4. Replace `O` with `0`.

  The field stores this normalised value. It displays `formatCode(normalised)`, which is the same 5-grouping as §3.4 (`src/ui/code.ts:28-30`, `src/ui/components/CodeInput.tsx:50-51`).
- **`invalidCodeChars(normalised)`** (`src/ui/code.ts:22-25`) returns the characters not matching `^[0-9A-HJKMNP-TV-Z]$`, de-duplicated, in first-seen order.
- **`codeProblem(normalised, length = 26)`** (`src/ui/household/join.ts:22-27`):
  - It checks characters first and returns `{kind:'chars', chars: bad.join(' ')}`.
  - Otherwise, if `normalised.length != 26`, it returns `{kind:'length', count}`.
  - Otherwise it returns `nil`.
- **No length cap.** The field never truncates input (`src/ui/components/CodeInput.tsx:32-72`).

### 3.6 Account id

**Formula.** `accountId = lowercaseHex(SHA256(secret16)[0..<16])`, which is 32 hex characters (`src/services/account/identity.ts:131-134`, `worker/src/auth.ts:97-108`, `src/core/bytes.ts:10-17`).

**Use.** The server computes it and uses it only as a key prefix. The client derives it but never sends it, and it is stored nowhere. The app never uses `Account.id` beyond equality in tests.

**Native.** `CryptoKit.SHA256.hash(data:)`, take the first 16 bytes, format each as `%02x`.

### 3.7 Persistence and lifecycle (`src/services/account/identity.ts`)

**Keychain key:** `SECRET_KEY = 'sync.accountSecret.v1'` (`:30`). The stored value is the **26-character unformatted canonical code** as a UTF-8 string. It is *not* raw bytes.

**Exact keychain item written by the Expo build (expo-secure-store 57.0.1, default options).** This is required for the in-place upgrade:

| Attribute | Value | Source |
| --- | --- | --- |
| `kSecClass` | `kSecClassGenericPassword` | `node_modules/expo-secure-store/ios/SecureStoreModule.swift:180-185` |
| `kSecAttrService` | **`"app:no-auth"`** (keychainService default `"app"` + `":no-auth"` because `requireAuthentication == false`) | `…SecureStoreModule.swift:172-176` |
| `kSecAttrAccount` | `Data("sync.accountSecret.v1".utf8)` — **as `Data`, not `String`** | `…:178-184` |
| `kSecAttrGeneric` | same `Data` | `…:182` |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlocked` (default `keychainAccessible = .whenUnlocked`) | `…SecureStoreOptions.swift`, `…SecureStoreModule.swift:95-98` |
| `kSecAttrAccessGroup` | not set (default group = app identifier `TEAMID.com.wystudio.inventory`) | `…:187-189` |
| `kSecValueData` | UTF-8 bytes of the code | `…:92-93` |

- **Read fallback order** in expo-secure-store (`…SecureStoreModule.swift:69-87`): service `"app:no-auth"`, then `"app:auth"`, then legacy `"app"`. The first item found wins. A query that fails with anything other than `errSecItemNotFound` **throws immediately** and the later variants are not tried (`:159-169`). Native should do the same, or at least read `"app:no-auth"` and then `"app"`.
- **Write** (`set`, `…:89-125`): `SecItemAdd` with the attributes above.
  - On `errSecSuccess`, it then deletes the legacy `"app"` item and the `"app:auth"` item (`:114-119`).
  - On `errSecDuplicateItem`, it calls `SecItemUpdate` with **only `kSecValueData`** (`:120-121`, `:127-144`). The existing item's `kSecAttrAccessible` is **not** changed.
  - Any other status throws `KeyChainException(status)`.
  - Native should mirror this add-then-update sequence. To change accessibility later (Q4), include `kSecAttrAccessible` in the `SecItemUpdate` attributes, or delete and re-add.
- **Delete** removes all three variants (`…:43-51`).
- **Access group.** The Expo build's entitlements are empty (`ios/Inventory/Inventory.entitlements`, no `keychain-access-groups`), so the item sits in the implicit app-identifier group `TEAMID.com.wystudio.inventory`. If the native target ever adds `keychain-access-groups` (for a widget or extension), new `SecItemAdd`s go to the *first listed* group, while reads without a group search all groups. That yields two items and an ambiguous `kSecMatchLimitOne` read. Either add no keychain group, or set `kSecAttrAccessGroup = "<TEAMID>.com.wystudio.inventory"` explicitly on every query.
- **Native:** keep writing the same item (same service, `Data` account, same accessibility). Otherwise a mismatch strands the account after the App Store update. The native build must ship under the **same Team ID**.

#### Lifecycle functions

**`loadAccount()`** (`:52-69`)

- Reads the key. If the keychain read **throws**, return `nil` rather than an error.
  - The reason: treating an error as "empty" must not mint a second account (`:56-60`).
  - The UI can still let the user "Turn on" in that state; see §13 B8.
- A missing or empty value returns `nil`.
- `decodeBase32(stored)`. If the result is `nil` or not 16 bytes, return `nil`.
- Otherwise return `{ id: deriveAccountId(secret), recoveryCode: stored }`. The stored string is returned as-is.

**`createAccount()`** (`:78-85`)

- It does not check for an existing item. Through the duplicate→update path above, it **overwrites** whatever code is already in the keychain (§13 B8).
- Get 16 bytes from a CSPRNG. RN uses `Crypto.getRandomBytesAsync` and explicitly avoids the sync variant because of a dev `Math.random` fallback (`:73-77`).
- Encode them, then `setItemAsync`. A write failure **throws** to the caller.
- Return the `Account`.
- **Native:** `SecRandomCopyBytes(kSecRandomDefault, 16, &buf)`. On a non-`errSecSuccess` result, **throw**. Never fall back to a weaker RNG.

**`importAccount(code)`** (`:95-112`)

- `secret = decodeBase32(code)`. If it is `nil` or not 16 bytes, return `{ok:false, reason:'malformed'}`. Nothing is written.
- `canonical = encodeBase32(secret[0..<16])`. Store **canonical**, never the typed form (`:101-103`).
- If the keychain write throws, return `{ok:false, reason:'unavailable'}`.
- Otherwise return `{ok:true, account:{id, recoveryCode: canonical}}`.

**`forgetAccount()`** (`:115-121`) deletes the key. Errors are swallowed. It does not touch the server.

**`isSecureStoreAvailable()`** (`:43-49`) is unused anywhere and does not need porting.

### 3.8 Test vectors (cross-implementation contract)

| Secret (16 bytes) | Code | Formatted | Account id | Source |
| --- | --- | --- | --- | --- |
| `0x42`×16 | `89144GJ289144GJ289144GJ288` | `89144-GJ289-144GJ-28914-4GJ28-8` | `900dfeb7f1b5e344209e2abce56c333d` | `src/services/account/__tests__/identity.test.ts:47-57`, `worker/test/base32.test.ts:41-47` |
| `0x00`×16 | `00000000000000000000000000` | `00000-00000-00000-00000-00000-0` | `374708fff7719dd5979ec875d56cd228` | computed for this spec |
| `0xFF`×16 | `ZZZZZZZZZZZZZZZZZZZZZZZZZW` | `ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-W` | `5ac6a5945f16500911219129984ba8b3` | computed |
| `01 02 … 10` | `041061050R3GG28A1C60T3GF20` | `04106-1050R-3GG28-A1C60-T3GF2-0` | `5dfbabeedf318bf33c0927c43d7630f5` | computed |
| `0x11`×16 | `248H248H248H248H248H248H24` | `248H2-48H24-8H248-H248H-248H2-4` | `b8f12ea8c9a95d4b4641b03d9fa5a71a` | computed |

---

## 4. Wire contract (sync Worker, contract v1)

`SYNC_CONTRACT_VERSION = 1` (`src/services/sync/contract.ts:9`, `worker/src/contract.ts:10`).

### 4.1 Common request rules (client)

These all come from `send()` in `src/services/sync/client.ts:36-66`.

- **URL:** `"\(endpoint)\(path)"`. The endpoint has no trailing slash and the path starts with `/v1/…`.
- **Not configured:** if the endpoint is `nil`, return `failed(.not_configured)` without a request (`:40`).
- **Headers on every request** (`:47-53`). Per-call headers are merged last, so they win.
  - `Authorization: Bearer <26-char canonical recovery code>`. This is the stored, unformatted code.
  - `X-Contract-Version: 1`. The Worker **never reads** this header; send it for parity.
  - `x-inventory-key: <syncKey>`, only when `syncKey` is non-empty.
- **Where the code may appear.** The recovery code appears **only** in `Authorization`. It must never be in a URL, a log or telemetry (`:27-30`). Natively, make sure no `URLSession` logging or metrics dump headers.
- **Path parameters** (photo id, backup id) are interpolated **without percent-encoding** (`:75`, `:98`, `:110`, `:177`). Ids are lowercase UUIDs, epoch-ms digits or `latest`, so encoding is a no-op.
- **Timeout:** an `AbortController` fires after `timeoutMs` (60 s). The timer is cleared in `finally` as soon as the `fetch` promise resolves (`:42-43`, `:64-65`).
  - **On the shipped RN app, that is after the *entire* response body has arrived.** React Native's `fetch` is the `whatwg-fetch` polyfill over `XMLHttpRequest` (`node_modules/react-native/Libraries/Network/fetch.js:15`). It resolves only in `xhr.onload`, with the fully buffered body (`node_modules/whatwg-fetch/dist/fetch.umd.js:546-562`).
  - So the 60 s window covers request upload, server time and **the full response download**, for example a 32 MiB `GET /v1/backups/latest`. The later `arrayBuffer()`/`json()` only reads an in-memory blob.
  - **Native:** enforce one 60 s total deadline from request start until the full body is in memory. For example, race `URLSession.data(for:)` / `upload(for:from:)` (both return only after the full body) against `Task.sleep(for: .seconds(60))` in a task group, and cancel the loser. `URLRequest.timeoutInterval` is an *idle* timeout and not equivalent.
- **No HTTP cache.** Photo GETs return `cache-control: private, max-age=31536000, immutable`. With `URLSession.shared` / the default configuration, those authenticated inventory photos (and possibly snapshots) would be written to the on-disk `URLCache` under `Library/Caches`. Use `URLSessionConfiguration.ephemeral` (or set `urlCache = nil` and `requestCachePolicy = .reloadIgnoringLocalCacheData`). `GET /v1/backups/latest` must never be answered from a cache.
- **Success** means `response.ok` (status 200–299). Anything else becomes `failed(classifyStatus(status))` (`:57-59`).

### 4.2 Failure classification

`SyncFailureReason` (`src/services/sync/contract.ts:39-50`) has these values:

- `not_configured`
- `no_account`
- `offline`
- `timeout`
- `unauthorized`
- `quota_exceeded`
- `too_large`
- `not_found`
- `corrupted`
- `server_error`
- `malformed_response`

`no_account` is **never produced** anywhere.

**HTTP status** (`classifyStatus`, `src/services/sync/client.ts:196-203`):

| Status | Reason |
| --- | --- |
| 401, 403 | `unauthorized` |
| 404 | `not_found` |
| 413 | `too_large` |
| 422 | `corrupted` |
| 507 | `quota_exceeded` |
| any other non-2xx (400, 405, 500, 503, …) | `server_error` |

**Thrown errors** (`classifyError`, `src/services/sync/client.ts:205-211`):

| JS condition | Reason | Native equivalent |
| --- | --- | --- |
| `error.name == 'AbortError'` (our 60 s deadline; `whatwg-fetch` rejects with `DOMException('Aborted','AbortError')`, whose prototype is `Error.prototype`, `fetch.umd.js:518-529`, `:577-581`) | `timeout` | our deadline fired (Swift `CancellationError` from the race) |
| message matches `/network\|fetch failed\|internet\|unreachable/i`. On RN iOS every transport failure is `TypeError('Network request failed')` (`xhr.onerror`), and a **native URLSession idle timeout** is `TypeError('Network request timed out')` (`xhr.ontimeout`, `fetch.umd.js:565-575`). Both contain "network". | `offline` | `URLError` `.notConnectedToInternet`, `.networkConnectionLost`, `.cannotFindHost`, `.cannotConnectToHost`, `.dnsLookupFailed`, `.internationalRoamingOff`, `.dataNotAllowed`, `.secureConnectionFailed` and the other TLS errors (see Q7), **and `.timedOut`**. In RN, a URLSession-level timeout surfaces as `offline`, not `timeout`. Mapping `.timedOut` to `timeout` is an acceptable copy-only divergence; decide explicitly. |
| anything else | `server_error` | everything else (e.g. `.badServerResponse`, `.cancelled` not caused by our deadline) |

**Body parsing.** Failures while decoding the body become `malformed_response` (`:104-106`, `:149-151`, `:162-164`, `:187-189`).

### 4.3 Endpoints the app calls

| # | Client method | Method + path | Request | Success response | Client result |
| --- | --- | --- | --- | --- | --- |
| E1 | `uploadPhoto(photoId, bytes)` (`client.ts:73-95`) | `PUT /v1/photos/{photoId}` | `Content-Type: image/jpeg` (**always**, even though files are WebP; see §13 B5). Body: raw file bytes. | `201` JSON `{"id": string, "size": number}` (ignored) | `success(())` |
| E2 | `downloadPhoto(photoId)` (`client.ts:97-107`) | `GET /v1/photos/{photoId}` | none | `200` raw bytes. Headers: `content-type` (stored type, or `image/jpeg`), `content-length`, `etag`, `cache-control: private, max-age=31536000, immutable` | `success(Data)` |
| E3 | `deletePhoto(photoId)` (`client.ts:109-113`) | `DELETE /v1/photos/{photoId}` | none | `204` empty, **whether or not it existed** | `success(())` |
| E4 | `uploadBackup(snapshot, schemaVersion, checksum?)` (`client.ts:115-152`) | `PUT /v1/backups` | `Content-Type: application/vnd.sqlite3`; `x-snapshot-schema-version: <int>`; `x-snapshot-sha256: <64 lowercase hex>` (the app always sends it). Body: snapshot bytes. | `201` JSON `BackupSummary` `{"id": "<epoch ms as string>", "size": int, "capturedAt": int (server epoch ms), "schemaVersion": int}` | `success(BackupSummary)`. The body is cast **without validation** (`:142`); see §13 B9. |
| E5 | `downloadBackup(backupId = "latest")` (`client.ts:174-190`) | `GET /v1/backups/{backupId}` (the app only ever uses `latest`) | none | `200` raw SQLite bytes. Headers: `content-type: application/vnd.sqlite3`, `content-length`, `etag`, **`x-snapshot-schema-version`** (string int, `'0'` if absent), `x-snapshot-captured-at` (backup id; unused) | `success((bytes, schemaVersion))` with `schemaVersion = Number(header ?? "0")`. A non-numeric header becomes `NaN` in JS (§13 B10). |
| — | `listBackups()` (`client.ts:154-165`) | `GET /v1/backups` | none | `200` `{"contractVersion": 1, "backups": [BackupSummary…]}`, newest first | Validated by `parseBackupList` (§4.5). **No caller in the app**; optional to port. |
| — | `configured` getter (`client.ts:69-71`) | — | — | — | Unused. |

`GET /v1/usage` and `GET /v1/health` exist server-side but the app never calls them (§4.6).

### 4.4 How the app reacts to each failure, per call site

| Call site | Reaction |
| --- | --- |
| `uploadPhoto` in `uploadPendingPhotos` | **Any** failure stops the upload loop: `interrupted = true`. The photo stays pending (`photoSync.ts:73-79`). |
| `deletePhoto` in `processPhotoDeletions` | Any failure: `interrupted = true`. The tombstone is kept (`photoSync.ts:111-114`). |
| `downloadPhoto` in `rehydrateMissingPhotos` | `not_found` skips that photo. Any other failure means `interrupted = true` (`photoSync.ts:149-155`). |
| `uploadBackup` in `runBackup` | Reason returned. The manual backup paths turn it into `SyncStatus.error(reason)`. The **automatic pass ignores it** (§8.4). |
| `downloadBackup` in `restoreBackup` | Reason returned to the UI and shown via `backupReason` (§9.6). A fresh 16-byte code with no backups produces `404 "No backups yet."`, then `not_found`, then `strings.backup.reasons.notFound`. |

### 4.5 Response validation (client)

- **`isBackupSummary(v)`** (`src/services/sync/contract.ts:55-64`): an object where `id` is a string and `size`, `capturedAt` and `schemaVersion` are numbers.
- **`parseBackupList(body)`** (`:67-76`): returns `nil` unless the body is an object with `contractVersion === 1` **and** `backups` is an array **and** every element passes `isBackupSummary`.
- **Swift:** use `Decodable` structs with strict types. Reject a `contractVersion` other than 1.

### 4.6 Server behaviour (for exact status codes and limits)

#### Router (`worker/src/index.ts:42-103`)

- **Trailing slashes** are stripped from the path (`:44`).
- **`/v1/health`**, any method, no auth: `200 {"ok":true,"contractVersion":1}` (`:46-48`).
- **Household routes are matched before personal auth** (`:50-68`; see §4.8). A personal recovery code cannot reach them.
- **Personal auth** (`authenticate`, `worker/src/auth.ts:28-55`) runs before any other route matching. A bad credential therefore yields **401 even for unknown paths**. The checks run in order, and each failure is a 401 with this JSON `error`:
  1. If `SYNC_SHARED_SECRET` is set, the `x-inventory-key` header must equal it (constant-time compare, `auth.ts:29-35`, `:116-127`). Otherwise: `"Invalid credentials."`
  2. `Authorization` must be present. Otherwise: `"Missing credentials."`
  3. The trimmed header must match `/^Bearer\s+(.+)$/i`. Otherwise: `"Malformed authorization header."`
  4. `decodeBase32(code)` must give exactly 16 bytes (`auth.ts:47-52`). Otherwise: `"Invalid recovery code."`
- **Photo routes** `/v1/photos/{id}`. The `{id}` is `decodeURIComponent`'d (a malformed `%` escape throws, and the top-level catch returns 500). It must match lowercase UUID `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`, otherwise **400 `"Invalid photo id."`** (`worker/src/contract.ts:80-84`, `index.ts:74-79`). **Native photo ids must be lowercase.** `UUID().uuidString` is uppercase; lowercase it. RN `newId()` emits lowercase hex v4 (`src/core/id.ts:41-54`).
  - `GET`: `404 {"error":"Not found."}`, or `200` streaming the object (`index.ts:113-126`).
  - `PUT` (`index.ts:128-144`):
    - `readBody(limit = 4 MiB)` (§4.7).
    - `replacing = HEAD size or 0`.
    - Quota: `usage.bytes − replacing + incoming > 2 GiB` gives **507 `"Storage limit reached for this account."`**
    - Store under `photos/<accountId>/<photoId>.jpg` with content type = the request `Content-Type`. Parameters are stripped and the value lowercased. It is kept only if it is in {`image/jpeg`, `image/webp`, `image/png`}, otherwise `image/jpeg` (`index.ts:420-425`).
    - Usage delta: `(+incoming − replacing, replacing > 0 ? 0 : +1)`.
    - **201** `{"id","size"}`.
  - `DELETE`: HEAD size, delete. If size > 0, apply usage delta `(−size, −1)`. Always **204** (`index.ts:146-153`).
  - Other methods: **405 `"Method not allowed."`**
- **`/v1/backups`**: `PUT` goes to `putBackup`, `GET` goes to `listBackups`, anything else is **405** (`index.ts:81-85`).
- **`/v1/backups/{id}`**: `GET` only. Other methods fall through to **404** (`index.ts:87-90`).
- **`/v1/usage`**: `GET` returns `200 {"contractVersion":1,"bytes":int,"objects":int,"limitBytes":2147483648}` (`index.ts:92-100`). Other methods return 404.
- **Anything else:** **404 `"Not found."`** (`index.ts:102`).
- **Any uncaught exception:** **500 `{"error":"Storage is temporarily unavailable."}`** (`index.ts:31-39`).
- **All JSON responses** carry `content-type: application/json; charset=utf-8` (`index.ts:453-458`). There are no CORS headers.

#### `putBackup` (`index.ts:299-351`)

1. `readBody(limit = 32 MiB)`: 413 or 400.
2. `schemaVersion = Number(header 'x-snapshot-schema-version' ?? '0')`. It must be an integer ≥ 1, otherwise **400 `"Missing or invalid schema version."`**
3. Quota check (`replacing = 0`): **507** if over.
4. **`capturedAt = server Date.now()`.** The snapshot id is server time, so a wrong phone clock cannot make the newest backup the oldest (`:311-319`).
5. The key is `backups/<accountId>/<capturedAt>.db`. Two uploads in the same millisecond overwrite each other.
6. `x-snapshot-sha256` is trimmed and lowercased. If it matches `^[0-9a-f]{64}$`, it is passed to R2, which verifies it. A malformed checksum header is silently ignored (`:322-329`).
7. Any R2 put failure (checksum mismatch or anything else) returns **422 `"Snapshot failed its integrity check."`** (`:331-337`).
8. Metadata: `httpMetadata.contentType = application/vnd.sqlite3`, `customMetadata.schemaVersion = "<int>"`.
9. Usage delta `(+size, +1)`, then prune to retention (§4.7).
10. Respond **201** `{"id": "<capturedAt>", "size", "capturedAt", "schemaVersion"}`.

#### `listBackups` (`index.ts:353-381`)

- Paginated R2 list of `backups/<accountId>/` (limit 1000, includes `customMetadata`).
- `id` = the key with the prefix and `.db` removed. Ids not matching `^[0-9]{10,16}$` are skipped.
- `{id, size, capturedAt: Number(id), schemaVersion: Number(meta.schemaVersion ?? 0)}`, sorted by `capturedAt` **descending**.

#### `getBackup` (`index.ts:383-409`)

- `latest`: the first entry from `listBackups`, or **404 `"No backups yet."`**
- Otherwise the id must match `^[0-9]{10,16}$`, or **400 `"Invalid backup id."`**
- A missing object returns **404 `"Not found."`**

### 4.7 Limits, quota and retention

| Limit | Value | Enforced | Source |
| --- | --- | --- | --- |
| Photo body | `MAX_PHOTO_BYTES = 4 × 1024 × 1024` | server (413) | `worker/src/contract.ts:26`; app constant `src/services/sync/contract.ts:19` (not checked client-side) |
| Snapshot body | `MAX_BACKUP_BYTES = 32 × 1024 × 1024` | **client** before upload (`too_large`, no request) **and** server (413) | `src/services/sync/backup.ts:81-86`, `worker/src/contract.ts:35` |
| Account total | `MAX_ACCOUNT_BYTES = 2 × 1024³` (2 147 483 648) | server (507) | `worker/src/contract.ts:38`, `worker/src/storage.ts:84-97` |
| Snapshots kept | `BACKUP_RETENTION = 5`, newest first | server, after every backup PUT | `worker/src/contract.ts:47`, `worker/src/storage.ts:111-142` |

**`readBody`** (`index.ts:436-451`):

- A **declared** `content-length` over the limit returns 413 before the body is read.
- A body of 0 bytes returns **400 `"Empty upload."`**
- A buffered body over the limit returns 413 `"Upload is too large."`

**Usage counter** (`worker/src/storage.ts`):

- Stored at `meta/<accountId>/usage.json` as `{bytes, objects}`.
- It is **recomputed** by listing `photos/<acct>/` and `backups/<acct>/` when the object is missing, unparsable or has non-number fields (`:23-58`).
- Deltas are clamped at ≥ 0 (`:66-79`).
- It is advisory and can drift under concurrent writes (`:14-22`).

**Retention** (`pruneBackups`): list the account's backups, parse ids as numbers, sort **numerically** descending, delete everything after index 5, and apply a negative usage delta (`:111-142`).

**R2 key layout** (`worker/src/contract.ts:91-149`, `worker/README.md:24-28`):

```
photos/<accountId>/<photoId>.jpg      (extension is always .jpg regardless of real format)
backups/<accountId>/<epochMillis>.db
meta/<accountId>/usage.json
household/primary/photos/<id>.webp | <id>-thumb.webp     (household; not reachable by a code)
household/primary/db/<YYYY-MM-DDTHH-MM-SSZ>/{inventory.db|control.db}
```

### 4.8 Household routes on the same Worker (the phone never calls these)

These are documented for completeness only. The home server is the caller (`worker/README.md:60-66`).

- **Auth.** `Authorization: Bearer <HOUSEHOLD_PHOTO_SECRET>` with a constant-time compare. If the secret is unset, the response is **503 `"Storage is temporarily unavailable."`**. Missing, malformed or wrong credentials return 401 (`worker/src/auth.ts:66-87`).
- **`/v1/household/photos/{uuid}?kind=full|thumb`** (default `full`; any other kind is 400) (`index.ts:158-203`):
  - `GET` returns the object (default type `image/webp`).
  - `PUT`: 4 MiB limit, allowlisted type (default `image/webp`), no quota, **201**.
  - `DELETE`: **204**.
- **`GET /v1/household/db`** returns `{snapshots:[{id, files[], bytes}]}`, sorted by id descending (`index.ts:205-210`, `:272-297`).
- **`/v1/household/db/{snapshotId}`**:
  - `GET` returns that entry, or 404.
  - `DELETE` removes every key under the prefix and returns 204 (`index.ts:212-230`, `:259-270`).
  - `snapshotId` must match `^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z$` (`contract.ts:127-129`).
- **`/v1/household/db/{snapshotId}/{inventory.db|control.db}`**:
  - `GET` returns bytes.
  - `PUT`: 32 MiB limit, **201** `{id, file, size}`.
  - Any other file name is 400 (`index.ts:232-256`).

---

## 5. Backup: producing and uploading a snapshot

### 5.1 How the Expo build snapshots the live DB

`snapshotAsync` is in `src/db/expoDatabase.ts:31-34`:

1. `PRAGMA wal_checkpoint(TRUNCATE)`. This folds committed WAL frames into the main file so the snapshot cannot lag recent writes (`:22-30`).
2. `db.serializeAsync()`. This is `sqlite3_serialize` of schema `main` and returns the in-memory image of the whole database file (including free pages and the WAL-mode header bytes).

The DB is opened with `PRAGMA journal_mode = WAL` and `PRAGMA foreign_keys = ON` (`src/db/expoDatabase.ts:72-77`). The file is `inventory.db` (`:63`). On iOS, expo-sqlite puts it in `<Documents>/SQLite/inventory.db` (`node_modules/expo-sqlite/ios/SQLiteModule.swift:24-28`); this is owned by the DB area spec.

The Node test adapter uses `VACUUM INTO <tmpfile>` and then reads the file (`src/db/nodeDatabase.ts:107-121`). That is the same idea as the native recommendation below.

**Native replacement (GRDB).** Produce a consistent, self-contained SQLite file, then read it into `Data`. Either approach works:

- **(a)** Run `VACUUM INTO ?` (bind a path in `FileManager.temporaryDirectory`) **outside a transaction**. `VACUUM` refuses to run inside one, so use GRDB's non-transactional access (e.g. `writeWithoutTransaction`). This reads a consistent snapshot that includes WAL content, so no checkpoint is needed.
- **(b)** Back up the live database (a single GRDB `DatabaseQueue`, `01-data.md` §2.2) into a temporary `DatabaseQueue(path:)` with GRDB's backup API.

Either way, delete the temp file in `defer`. Do this off the main actor. The server never parses the bytes, so byte-for-byte identity with `sqlite3_serialize` is **not** required. Any valid SQLite database file whose `user_version` and schema match is fine. (Household dumps are a different area.)

**Cross-platform restores.** Snapshots are not iOS-only. The same recovery code can be typed into the **Android RN app**, which stays on React Native. That app restores with `SQLite.deserializeDatabaseAsync(bytes)` followed by `backupDatabaseAsync` (`src/db/expoDatabase.ts:47-59`), and it refuses `x-snapshot-schema-version > its LATEST_SCHEMA_VERSION` (`src/services/sync/backup.ts:134-137`). The reverse also happens: native iOS restores Android RN snapshots. Therefore:

1. A native-produced snapshot must be restorable through expo-sqlite's deserialize and backup path. Add a cross-platform fixture test: take a `VACUUM INTO` / GRDB-backup output, then restore it with the RN path (or `sqlite3_deserialize` plus the backup API in a test harness).
2. The native app must never ship a schema version that Android has not shipped. Otherwise every Android restore of an iOS backup fails as `corrupted` / `newer_schema`. This is a migration-governance dependency on the DB spec.

### 5.2 `runBackup(db, client)` (`src/services/sync/backup.ts:61-95`)

1. If the backend cannot snapshot (`db.snapshotAsync` absent), return `failed(.not_configured)` (`:65-67`). Natively this cannot happen, so drop the branch or keep it for a test double.
2. Take the snapshot **completely before any network I/O** (`:54-60`). If it throws, log `backup_snapshot_failed {durationMs, errorClass}` and return `failed(.server_error)` (`:71-79`).
3. If `snapshot.count > MAX_BACKUP_BYTES` (strictly greater than 33 554 432), log `backup_too_large {byteSize}` and return `failed(.too_large)` without uploading (`:81-86`).
4. `schemaVersion = PRAGMA user_version` read from the **live** DB after the snapshot (`:24-27`, `:88`). Today `LATEST_SCHEMA_VERSION = 7` (`src/db/migrations.ts:265`, migrations 1–7).
5. `checksum = lowercaseHex(SHA256(snapshot))` (64 characters) (`:48-52`). Use `CryptoKit.SHA256`.
6. Call `uploadBackup(snapshot, schemaVersion, checksum)` (E4).
7. On success, write `lastBackupAt = result.capturedAt` (**server** time) (`:91-93`). On failure, nothing is recorded.

### 5.3 The `lastBackupAt` marker

- **Key:** `sync.lastBackupAt.v1` in AsyncStorage (`src/services/sync/backup.ts:12`). The value is `String(epochMillis)`, e.g. `"1760870400000"`.
- **Read** (`:29-37`): if stored and non-empty, `Number(stored)`; return it if finite, else `nil`. A read error returns `nil`.
- **Write** (`:39-46`): errors are swallowed, because the worst case is one extra upload.
- **Where the Expo build stored it.** It uses the **legacy (v2) store**: the package default export is `getLegacyStorage()` (`node_modules/@react-native-async-storage/async-storage/src/index.tsx`). The file is `<Library/Application Support>/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json`, a JSON object `{ key: value }`. Values of 1024 characters or fewer are inline; larger values live in a file named by the MD5 of the key, with a `null` entry in the manifest (`RNCAsyncStorage.mm:17-21`, `:129-150`, `:507-509`, `:633`). This value is always inline.
- **Not per account.** The marker is one global key, not keyed by account. A restore or adoption under a different code inherits whatever marker is already on the device (`src/providers/SyncProvider.tsx:205`, `backup.ts:103-104`). Parity: keep it global.
- **iCloud/Finder backup.** By default the RN storage directory is marked `NSURLIsExcludedFromBackupKey` (`RNCAsyncStorage.mm:527-535`, unless Info.plist sets `RCTAsyncStorageExcludeFromBackup`; `app.json` does not). So after a device restore from an iCloud backup, the Expo build had **no** `lastBackupAt`. `UserDefaults` *is* included in device backups, so native will remember it. That is a harmless improvement, but note it.
- **Native:** store it in `UserDefaults` under the same key **as a string**, exactly as `02-device-storage-migration.md` §5.3-5.4 specifies: the shared first-launch importer copies the RN string verbatim, native writes `String(Int64(capturedAt))` (no `".0"`), and the reader applies the JS-`Number` rule above (trim; empty → `nil`; finite → value). Do not switch the stored type to `Int64`/`Double`, because the imported value is a string and the readers must handle both the same way (09 §4.4). If the import fails, the cost is one extra backup. *(Consistency pass: previously said "an `Int64` or `Double`".)*

### 5.4 Automatic gate: `maybeBackup(db, client, now)` (`src/services/sync/backup.ts:98-106`)

- `MIN_BACKUP_INTERVAL_MS = 15 * 60 * 1000` (900 000) (`:14-22`).
- If `last != nil && now - last < MIN_BACKUP_INTERVAL_MS`, return `nil` (skipped). Otherwise return `runBackup(...)`.
- `now` is the **device** clock and `last` is **server** time. Clock skew shifts the gate. A device clock behind the server suppresses automatic backups until it catches up, because a negative difference is less than 15 minutes.
- User-facing statement: `strings.backup.automatic` ("…at most once every 15 minutes").

---

## 6. Restore, end to end

### 6.1 `restoreBackup(db, client, backupId = "latest")` (`src/services/sync/backup.ts:119-159`)

1. If restore is unsupported, return `failed(.not_configured)` (`:124-126`).
2. `downloadBackup("latest")` (E5). On failure, pass the reason through and **leave local data untouched** (`:129-130`).
3. **Schema gate:** if `schemaVersion > LATEST_SCHEMA_VERSION`, log `restore_rejected {schemaVersion, outcome:'newer_schema'}` and return `failed(.corrupted)` (`:134-137`). Older versions are allowed and expected (`:116-117`).
4. `db.restoreAsync(bytes)`, then `migrate(db)` (`:139-143`). If **either** throws, log `restore_failed {durationMs, errorClass}` and return `failed(.corrupted)` (`:144-150`). If `migrate` fails after the swap, local data **has** been replaced; see §13 B11.
5. Log `restore_succeeded {durationMs, byteSize, schemaVersion}` and return `success(schemaVersion)`.

### 6.2 How the Expo build swaps the DB

`restoreAsync` is in `src/db/expoDatabase.ts:47-59`:

1. `SQLite.deserializeDatabaseAsync(bytes)` loads the bytes into an in-memory connection. Garbage bytes throw here, which becomes `corrupted`.
2. `SQLite.backupDatabaseAsync({source: main, dest: live main})` uses SQLite's **online backup API** to copy every page into the open connection.
3. Close the source.

The file is never overwritten underneath an open connection, so there are no stale `-wal`/`-shm` files or page cache (`:36-46`). The `AFTER DELETE` tombstone trigger does **not** fire, because no row-level deletes happen.

**Native replacement (GRDB):**

1. Write the bytes to a temp file and open it as a `DatabaseQueue`. Open it read-write, because the header may say WAL.
2. Recommended addition: run `PRAGMA quick_check` and read `PRAGMA user_version` **from the file**. Reject it if the result is greater than latest, even when the header said otherwise.
3. Use GRDB's backup API into the live database, which is a single `DatabaseQueue` (`01-data.md` §2.2, `02-device-storage-migration.md` §2.3). Page sizes must match for a WAL destination; both default to 4096.
4. Re-assert `PRAGMA journal_mode = WAL` and `PRAGMA foreign_keys = ON`.
5. Run the ported `migrate()`.
6. **Explicitly notify all observers.** Do not rely on GRDB `ValueObservation` firing after a page-level backup.

Delete the temp file in every path.

### 6.3 The orchestration: `restoreFromCode(code)` (`src/providers/SyncProvider.tsx:159-212`)

1. If the DB is not ready, return `{ok:false, reason:'not_configured'}` (`:161`).
2. `importAccount(code)` (§3.7). A `malformed` result returns `{ok:false, reason:'malformed'}`. A keychain write failure (`unavailable`) is reported as **`not_configured`** (`:163-170`). The keychain is written **before** the download, overwriting any existing item; see §13 B8 for the case where one exists but could not be read.
3. Set `running = true`. This blocks the automatic pass that adopting an account would otherwise start. That pass would back up this phone's current data under the code being restored (`:173-177`).
4. Publish the account and set `status = .working(adopted)` (`:179-180`).
5. Create a client for the adopted code and call `restoreBackup(db, client)` (`:182-183`).
6. **On failure** (`:185-194`):
   - `forgetAccount()` deletes the keychain item again, and the published account is cleared.
   - `status = .off`.
   - Return `{ok:false, reason}`.
   - Restore is only offered while backup is off, so a failed code must not become this phone's account.
7. **On success** (`:196-206`):
   - `invalidate()` so every screen re-reads SQLite.
   - `syncPhotos(db, adoptedClient)`, with errors swallowed (`.catch(() => undefined)`).
   - `invalidate()` again.
   - `status = .idle(adopted, lastBackupAt: <read from storage>)`. On a fresh phone that is usually `nil`, so the screen shows "No backup has finished yet."
   - Return `{ok:true}`.
8. `finally`: `running = false` (`:207-209`). No pass is started here. The next one happens on the next foreground.

**What happens to photos after a restore.** This all happens inside the `syncPhotos` call in step 7:

- **Rows synced at snapshot time** (`remote_synced_at` set) whose file is missing are re-downloaded. Their row is re-pointed by `rehydrateMissingPhotos` (§7.4), but only the **10 newest**; see §13 B1.
- **Rows unsynced at snapshot time** whose file is missing are **deleted** by `uploadPendingPhotos` (§7.2). Their bytes were never uploaded.
- **Restored `sync_deletions` tombstones** are processed, which deletes those remote photos.
- **Photo files** that were on this phone before the restore are not deleted. They become orphans on disk.

**Next foreground pass after restore.** `lastBackupAt` is `nil` (fresh device), so `maybeBackup` immediately uploads the restored DB.

---

## 7. Photo sync queue (`src/services/sync/photoSync.ts`)

### 7.1 Queue state lives in the schema

The schema comes from migration 4, `src/db/migrations.ts:144-182`, and is owned by the DB area. It must be preserved exactly.

- **`item_photos.remote_synced_at INTEGER`** (`:152`): `NULL` means not yet confirmed remotely; otherwise it is the device epoch ms when the upload was confirmed.
- **Partial index:** `CREATE INDEX idx_item_photos_unsynced ON item_photos(created_at) WHERE remote_synced_at IS NULL;` (`:157-159`)
- **Tombstones:** `CREATE TABLE sync_deletions (photo_id TEXT PRIMARY KEY NOT NULL, deleted_at INTEGER NOT NULL);` (`:167-170`)
- **Trigger** (`:174-180`):

  ```sql
  CREATE TRIGGER item_photos_tombstone
  AFTER DELETE ON item_photos
  WHEN OLD.remote_synced_at IS NOT NULL
  BEGIN
    INSERT OR REPLACE INTO sync_deletions (photo_id, deleted_at)
    VALUES (OLD.id, CAST(strftime('%s','now') AS INTEGER) * 1000);
  END;
  ```

  This fires for cascaded deletes too (item, container or space deleted) and when an item's photo is replaced. `items.update` deletes all photo rows of the item and inserts a new row with a **new id** (`src/repositories/items.ts:353-370`).

Per-photo state is derived, not stored:

| State | Condition | Transition |
| --- | --- | --- |
| Pending upload | row exists, `remote_synced_at IS NULL` | upload OK sets `remote_synced_at = now`. File missing **deletes the row**. |
| Synced | row exists, `remote_synced_at IS NOT NULL` | row deleted creates a tombstone. File missing triggers rehydration. |
| Pending remote delete | `sync_deletions` row | DELETE OK removes the tombstone. |

**`BATCH_SIZE = 10`** applies per direction per pass (`photoSync.ts:24`). All loops are **sequential**: one request at a time, with no parallelism. No transaction is held across network calls (`:19-23`).

### 7.2 `uploadPendingPhotos(db, client, limit = 10)` (`photoSync.ts:47-89`)

```sql
SELECT id, uri, thumb_uri FROM item_photos
 WHERE remote_synced_at IS NULL
 ORDER BY created_at
 LIMIT ?                       -- [limit]
```

For each row, in order (oldest first):

1. `bytes = readStoredPhoto(uri)`. This returns `nil` if the file is absent or unreadable, **or if `File(uri)` throws**, for example on a non-`file:` URI (`src/services/capture/imageStore.ts:137-145`).
   - **Zero-byte file:** the check is `if (!bytes)`, and an empty `Uint8Array` is **truthy** in JS. So a 0-byte file is *not* treated as missing. It is uploaded, and the Worker rejects it with **400 "Empty upload."** (`worker/src/index.ts:443-445`). That is `server_error`, so the loop is interrupted, on every pass; see §13 B2.
   - Swift parity means "missing" is `nil` (no file / unreadable), not `data.isEmpty`.
2. **If `nil`:**
   - Delete the thumbnail file (best-effort).
   - Run `DELETE FROM item_photos WHERE id = ?`. No tombstone is created, because the row was unsynced.
   - Continue (`:65-71`).

   The doc comment says "marked synced-with-nothing" but the **code deletes the row**, and the test asserts deletion.
3. `uploadPhoto(id, bytes)`. On any failure, return `{uploaded, interrupted: true}` (`:73-79`).
4. Run `UPDATE item_photos SET remote_synced_at = ? WHERE id = ?` with `[Date.now(), id]` (`:81-84`).
5. `uploaded += 1`.

The function returns `{uploaded, interrupted: false}`.

### 7.3 `processPhotoDeletions(db, client, limit = 10)` (`photoSync.ts:98-121`)

```sql
SELECT photo_id FROM sync_deletions ORDER BY deleted_at LIMIT ?
```

For each tombstone:

1. `deletePhoto(photo_id)`. On failure, return `{deleted, interrupted: true}`.
2. Run `DELETE FROM sync_deletions WHERE photo_id = ?`.
3. `deleted += 1`.

### 7.4 `rehydrateMissingPhotos(db, client, limit = 10)` (`photoSync.ts:131-168`)

```sql
SELECT id, uri, thumb_uri FROM item_photos
 WHERE remote_synced_at IS NOT NULL
 ORDER BY created_at DESC
 LIMIT ?
```

For each row:

1. If `readStoredPhoto(uri)` returns bytes, skip the row. That includes a 0-byte file, because an empty `Uint8Array` is truthy (`photoSync.ts:147`).
2. `downloadPhoto(id)` (E2). `not_found` skips the row. Any other failure returns `{restored, interrupted: true}`.
3. `stored = writeStoredPhoto(id, bytes)` (`src/services/capture/imageStore.ts:161-178`):
   - Write the bytes verbatim to `<Documents>/item-photos/<id>.webp` (the name uses the **row id**). The bytes may really be **JPEG**: photos uploaded before the WebP switch, served with `content-type: image/jpeg` (`worker/src/index.ts:118-120`). They are still written under a `.webp` name. Native decoding must sniff content (ImageIO does) and never trust the extension.
   - Decode the file and regenerate the thumbnail at 320 px max edge, quality 0.7, WebP (`src/services/capture/imageScaling.ts:32-33`) as `<id>-thumb.webp`.
   - Return `{uri, thumbUri, width, height, byteSize}`.
   - This call **can throw** (decode failure), and the throw propagates out of the pass; see §13 B3.
4. Run `UPDATE item_photos SET uri = ?, thumb_uri = ?, byte_size = ? WHERE id = ?` (`:158-163`). `width` and `height` are **not** updated.
5. `restored += 1`.

### 7.5 `syncPhotos(db, client)` (`photoSync.ts:171-192`)

Runs uploads, then deletions, then rehydration. The order is fixed and each step runs even if an earlier one was interrupted.

It returns `PhotoSyncOutcome {uploaded, deleted, restored, interrupted}`, where `interrupted` is the logical OR of the three steps. It logs `photo_sync_pass {durationMs, itemCount: uploaded+deleted+restored, outcome: 'interrupted'|'complete'}`.

### 7.6 Retry and backoff

There is **no** retry, backoff or timer anywhere in this area.

- A failed item stays queued and is retried on the next pass (next foreground).
- An interrupted pass stops that direction immediately, on the assumption that every other item would fail the same way (`photoSync.ts:75-78`).
- Permanent per-item failures (400, 413) therefore **block the queue forever**; see §13 B2.

---

## 8. Sync engine (`src/providers/SyncProvider.tsx`)

### 8.1 Published status

From `:36-41`:

```swift
enum SyncStatus {
  case unavailable                                  // no endpoint configured
  case off                                          // endpoint configured, no account on this device
  case idle(account: Account, lastBackupAt: Int64?) // ms; nil = no backup recorded on this device
  case working(account: Account)
  case error(account: Account?, reason: SyncFailureReason)
}
```

The provider exposes these actions (`:43-53`):

- `enable() -> Result<Account, SyncFailureReason>`
- `backupNow()`
- `restoreFromCode(code) -> Result<Void, SyncFailureReason | malformed>`
- `refresh()`. This re-reads `lastBackupAt` and sets `idle`. It has **no callers** (`:214-217`).

### 8.2 Initialisation

- **Initial state:** `syncEndpoint != nil ? .off : .unavailable` (`:60-62`).
- **On mount, if an endpoint exists** (`:74-88`):
  - `loadAccount()`. If it returns an account, publish it and set `.idle(account, lastBackupAt())`.
  - There is no transition for "no account"; the status stays `.off`.
- **Client lifetime:** a `SyncClient` is created whenever the published account changes (`:69-72`).
- **Mount point.** `SyncProvider` sits inside `DatabaseProvider`/`HouseholdProvider` but **above the onboarding gate** (`app/_layout.tsx:228-242`). `loadAccount()` and the passes therefore run on every launch, including while onboarding is still pending and before any screen that uses sync is shown. Native: start the engine at app launch (root `App`/scene), not from the Backup screen.

### 8.3 Triggers

The effect at `:114-123` has dependencies `[client, runPass]`, and `runPass` is a `useCallback` over `[repos, client, account]` (`:97-110`). So `void runPass()` is called:

1. **Every time `client`, `repos` or `account` changes**, as long as a client exists. In practice:
   - (a) when an account is loaded at launch or created by `enable()` (adoption by `restoreFromCode` also triggers it, but the `running` flag blocks it, §6.3);
   - (b) **when the database becomes ready** (`repos` goes from `null` to the repositories) while an account is already loaded. On a cold launch, whichever of "account loaded" and "DB opened" finishes **last** starts the first pass. The first call's `!repos` guard makes the earlier one a no-op.
   - `repos` changes identity only on DB open or `retry()` (`src/providers/DatabaseProvider.tsx:41-72`), **not** on `invalidate()`.
2. On every **`AppState` change to `active`**. On iOS, RN emits `active` on `UIApplicationDidBecomeActiveNotification`. So it also fires after a plain `inactive` interruption (Notification/Control Center, the app switcher, system permission alerts, Face ID prompts), not only after background.

There are **no timers, no reachability or network-change triggers, and no triggers on data change**.

**Native:** run a pass when all three conditions (`database ready`, `account loaded`, `!running`) first become true; after `enable()` (B6); and on `scenePhase == .active` (or `UIApplication.didBecomeActiveNotification`) on the root scene. BGTaskScheduler is out of scope for parity; see Q4.

### 8.4 The automatic pass, `runPass` (`:97-110`)

- **Guards:** the DB is ready, a client exists, and `running == false`. If any guard fails, return silently.
- **Body:** set `running = true`, then:
  1. `syncPhotos(db, client)`
  2. `maybeBackup(db, client)`
  3. If an account exists, set `status = .idle(account, lastBackupAt())`.

  `finally`: `running = false`.
- **Photos first, then the snapshot.** This makes the snapshot record the true `remote_synced_at` state (`:90-96`).
- **The automatic pass never shows `working` and never shows errors.** A failed automatic backup still ends in `.idle` with the old `lastBackupAt`. A pass also overwrites a prior `.error` from a manual backup with `.idle`. A throw inside `syncPhotos` aborts the pass before `maybeBackup` and leaves the status unchanged (`void runPass()`, unhandled).

### 8.5 `enable()` (`:125-144`)

1. If the DB is not ready, return `{ok:false, reason:'not_configured'}`. The status is unchanged.
2. `createAccount()`. A keychain write error **throws** to the caller.
3. Publish the account and set `status = .working(created)`.
4. `runBackup(db, newClient(created))`. This is forced and ignores the 15-minute gate.
5. On failure: `status = .error(created, reason)` and return `{ok:false, reason}`. The account **remains**, so backups keep retrying under it.
6. On success: `status = .idle(created, capturedAt)` and return `{ok:true, account}`.

> RN race: publishing the account in step 3 also triggers an immediate `runPass` (§8.3) that runs **concurrently** with the `runBackup` in step 4. It uploads photos and, since `lastBackupAt` is still `nil`, uploads a second snapshot. Native should not reproduce this (§13 B6).

### 8.6 `backupNow()` (`:146-157`)

1. Guards: DB ready, client exists, account exists.
2. `status = .working(account)`.
3. `runBackup` (forced, no photo sync).
4. The result sets `.error(account, reason)` or `.idle(account, capturedAt)`.

It does **not** check `running`, so it can overlap an automatic pass. The UI prevents double taps (§9.4).

### 8.7 Concurrency model to implement natively

- One `actor SyncEngine` owns the guard. `runPass`, `enable`, `backupNow` and `restore` are all serialized through it. `restore` additionally suppresses automatic passes until it finishes.
- Network calls run sequentially. No transaction is held across awaits.
- Status is published on the main actor.

---

## 9. Backup screen (`app/backup.tsx`) and the Settings entry

Navigation title: `strings.backup.title` (`app/_layout.tsx:169`).

### 9.1 Settings row (`app/settings.tsx:36-81`, `src/ui/household/status.ts:22-48`)

- **Section:** `strings.settings.onThisPhone`. **Label:** `strings.settings.backup`.
- **Value and tone** (`backupSummary`):

  | Status | Value | Tone |
  | --- | --- | --- |
  | `unavailable` | `strings.settings.backupSummary.notConfigured` | ink |
  | `off` | `.off` | ink |
  | `working` | `.working` | ink |
  | `error` | `.attention` | **signal** (accent / attention colour) |
  | `idle`, `lastBackupAt == nil` | `.notYetRun` | ink |
  | `idle`, otherwise | `.on` | ink |
- **Visibility** (`showBackupRow(paired, status)`):
  - Always shown when the phone is not in a household.
  - On a paired phone, shown only when the status is neither `off` nor `unavailable`.
- **Tap:** pushes the Backup screen, **except** in `unavailable`, where the row is static and not tappable.

### 9.2 Screen layout and branches (`app/backup.tsx:46-85`)

**Top banner.** If the phone is in a household (`session != nil`), always show an info banner with `strings.backup.pairedNote` above everything else (`:71`).

**Body, chosen in this order** (`:72-80`):

1. `status == .unavailable`: an info banner `strings.backup.unavailable` only.
2. `revealedCode != nil`: **Reveal code** (§9.5).
3. `account != nil && !restoring`: **Backup on** (§9.4). `account` is the status's account for `idle`, `working` and `error` (`:58`).
4. Otherwise: **Backup off** (§9.3). This also covers `error` with `account == nil`.

**Why the `restoring` flag exists.** It keeps the restore form visible while `restoreFromCode` runs. The provider publishes the adopted account during the download, which would otherwise switch the screen to "Backup on". That would lose the typed code and the failure message (`:52-56`). **Native:** simplest is for the engine **not to publish the adopted account until the restore succeeds**. Then this flag is unnecessary, though the auto-pass suppression is still needed.

### 9.3 Backup off (`app/backup.tsx:98-243`)

There are two sections: a heading, body text and actions each.

**A. "Keep a copy" section**

- **Heading** `strings.backup.keepTitle`. **Body** `strings.backup.keepBody` and `strings.backup.keepCode`.
- **Failure banner:** a warning banner with `enableFailure` text, when set.
- **Primary button** `strings.backup.turnOn`, full width.
  - Accessibility hint `strings.backup.turnOnHint`.
  - Shows loading while `busy == .enable`. Disabled while `busy == .restore`.
  - testID `backup-enable`.

**B. "Restore" section**

- **Heading** `strings.backup.restoreTitle`. **Body** `strings.backup.restoreBody`.
- **Code field** (§9.7): label `strings.backup.codeLabel`, hint `strings.backup.codeHint`, length 26, `error = codeError`, testID `backup-code-input`. Any edit clears `codeError` (`:219-230`).
- **Secondary button** `strings.backup.restore` ("Restore…"), full width.
  - Shows loading while `busy == .restore`.
  - Disabled when `code.isEmpty` (normalised) or `busy == .enable`.
  - testID `backup-restore`.

**`turnOn()`** (`:114-142`):

1. If busy, return. Set `busy = .enable` and clear `enableFailure`.
2. Call `enable()`.
   - **Success:** set `revealedCode = account.recoveryCode`. This shows the code once, immediately.
   - **Failure:** call `loadAccount()`.
     - If an account now exists (it was created but the first upload failed), **still reveal its code**. After "I have saved it", the Backup-on view shows the error banner and "Try again".
     - Otherwise (nothing was created, e.g. the DB was not ready): `enableFailure = backupReason(reason)`.
   - **Throws** (e.g. keychain write failure): log `backup_enable_failed {errorClass}` and set `enableFailure = backupReason(.server_error)`.
3. `finally`: clear `busy`.

**`restore()`** (`:144-192`):

1. If busy, return.
2. Run `codeProblem(code, 26)`:
   - `chars` problem: `codeError = strings.backup.badChars(chars)`, where chars are space-separated.
   - `length` problem: `codeError = backupReason(.malformed)`, i.e. `strings.backup.reasons.malformed`.
   - Either way, play an **error haptic** and return. A mistyped code never reaches the confirmation (`:146-156`).
3. Set the re-entry guard (`busyRef`) **before** showing the confirmation. This blocks re-taps of either button while the dialog is up (`:157`). The visible `busy` state is **not** set yet, so neither button shows loading or disabled during the dialog.
4. Show a destructive confirmation (`src/ui/confirm.ts:25-47`):
   - title `strings.backup.restoreConfirmTitle`, message `strings.backup.restoreConfirmBody`
   - destructive button `strings.backup.restoreConfirm`, cancel button `strings.common.cancel`
   - Dismissing it counts as Cancel. On Cancel, clear busy and return.
5. Set `busy = .restore`, clear `codeError`, set `restoring = true`. Call `restoreFromCode(code)`, passing the normalised code.
   - **Success:** clear the field, play a **success haptic**, show a toast `strings.backup.restored`. The screen then shows Backup on.
   - **Failure:** `codeError = backupReason(reason)` under the field, with the code left in place. Play an **error haptic**.
   - **Throws:** log `backup_restore_failed {errorClass}`, set `codeError = backupReason(.server_error)`, play an error haptic.
6. `finally`: clear busy and set `restoring = false`.

### 9.4 Backup on (`app/backup.tsx:280-378`)

**1. Error banner** (only when `status == .error`), shown above the card:

- Warning tone, title `strings.backup.errorTitle`, message `backupReason(reason)`.
- Action `strings.common.tryAgain`, which calls `runNow()`.

**2. Status card:**

- Heading `strings.backup.onTitle`.
- **Last line** (meta style) (`:298-305`):

  | Status | Last line |
  | --- | --- |
  | `working` | `strings.backup.working` |
  | `idle`, `lastBackupAt == nil` | `strings.backup.noBackupYet` |
  | `idle`, otherwise | `strings.backup.lastBackup(ago(lastBackupAt, now))` |
  | `error` | no line |

- Body `strings.backup.automatic`.
- Secondary button `strings.backup.backUpNow`, full width, testID `backup-now`. It shows loading while `working` and is **hidden when `error`**, because the banner has "Try again".

**3. Code section:**

- Heading `strings.backup.codeTitle`, body `strings.backup.codeBody`.
- Secondary button `strings.backup.showCode` (testID `backup-show-code`). It sets `revealedCode = account.recoveryCode`.

**Behaviour:**

- **Clock refresh.** `now` refreshes every **60 s** while the screen is focused, and once immediately on refocus (`src/hooks/useNow.ts:11-28`). Natively, use `TimelineView(.periodic(from: .now, by: 60))`.
- **`ago(ms, now)`** (`src/i18n/format.ts:34-44`):

  | Elapsed (`diff = max(0, now − ms)`) | Text |
  | --- | --- |
  | < 1 min | "just now" |
  | < 1 h | "N minute(s) ago" |
  | < 1 day | "N hour(s) ago" |
  | < 2 days | "yesterday" |
  | < 30 days | "N day(s) ago" |
  | < 365 days | "⌊days/30⌋ month(s) ago" |
  | otherwise | "⌊days/365⌋ year(s) ago" |

  A time in the future reads "just now". Port the function verbatim; do not use `RelativeDateTimeFormatter`, whose output differs.
- **Accessibility announcement.** On a transition from `working` to `idle`, announce the last line once. The line itself is not a live region (`:307-316`). Natively: `AccessibilityNotification.Announcement(text).post()`. A failure is announced by its banner.
- **`runNow()`** (`:318-331`): guarded against re-entry with `runningRef`. It calls `backupNow()`. Throws are logged as `backup_now_failed {errorClass}`.

### 9.5 Reveal code (`app/backup.tsx:246-277`)

- Heading `strings.backup.writeDownTitle`, body `strings.backup.writeDownBody`.
- **Code box:** `formatRecoveryCode(code)` in the code (monospaced) text style, centred, **selectable**. Its accessibility label is `spellCode(formatted)`.
- **Secondary button** `strings.backup.share` with a share icon (testID `backup-share-code`). It opens the system share sheet with `message = formatted` only. Errors and dismissal are ignored.
  - **Native:** `ShareLink(item: formatted)`.
  - The RN comment says there is no clipboard module (`:43-45`). A Copy action is now possible natively, but see Q9.
- **Primary button** `strings.backup.saved` dismisses the reveal (`revealedCode = nil`).
- **Persistence:** the reveal is local view state. Navigating away discards it. The code remains reachable via "Show recovery code".

**Actions that do not exist.** There is no "Turn off backup", "Forget this code", "Change code", backup list, per-snapshot restore or usage display anywhere in the UI. The only path that detaches an account is a *failed* restore (§6.3). Do not invent these for parity.

### 9.6 Failure copy (`backupReason`, `src/ui/household/status.ts:51-75`)

| Reason | Copy key |
| --- | --- |
| `malformed` | `strings.backup.reasons.malformed` |
| `offline` | `strings.backup.reasons.offline` |
| `timeout` | `strings.backup.reasons.timeout` |
| `unauthorized` | `strings.backup.reasons.unauthorized` |
| `not_found` | `strings.backup.reasons.notFound` |
| `quota_exceeded` | `strings.backup.reasons.quotaExceeded` |
| `too_large` | `strings.backup.reasons.tooLarge` |
| `corrupted` | `strings.backup.reasons.corrupted` |
| `not_configured` | `strings.backup.reasons.notConfigured` |
| `server_error`, `malformed_response`, `no_account` (default) | `strings.backup.reasons.other` |

### 9.7 Code field (`src/ui/components/CodeInput.tsx:32-72`)

- **Value handling.** The field holds the normalised value (§3.5) and displays it formatted in 5-groups. It wraps across lines at hyphens and never scrolls horizontally.
- **Counter.** `strings.forms.codeCounter(count, 26)` ("N of 26 characters") sits on the label row, **only when the value is non-empty**. It is announced once when the field loses focus, not live.
- **Text input traits:** auto-capitalise characters, no autocorrect, no spell-check, no autofill or content type. Return means Done and dismisses the keyboard; it never inserts a newline. Trailing lock icon.
- **Native:** a `TextField(axis: .vertical)` bound through a normalising `Binding`. Watch cursor jumps when reformatting; keep the formatted display separate from the stored value if needed. Use `.textInputAutocapitalization(.characters)`, `.autocorrectionDisabled()`, `.keyboardType(.asciiCapable)` and `.submitLabel(.done)`. A vertical-axis `TextField` inserts `\n` on Return. Normalisation strips it anyway (`\s`), but the setter must also drop focus when it sees a newline, to match "Return closes the keyboard" (`CodeInput.tsx:61-62`).
- **RN quirk (optional to copy):** because the value is re-normalised and re-formatted on every change, deleting a hyphen in the middle is a no-op; the hyphen reappears.

### 9.8 Copy keys used in this area (all in `src/i18n/strings.ts`)

- **`strings.backup.*`** (`:946-1004`):
  - Screen text: `title`, `unavailable`, `pairedNote`, `keepTitle`, `keepBody`, `keepCode`, `turnOn`, `turnOnHint`.
  - Restore section: `restoreTitle`, `restoreBody`, `codeLabel`, `codeHint`, `badChars(chars)`, `restore`, `restoreConfirmTitle`, `restoreConfirmBody`, `restoreConfirm`, `restored`.
  - Reveal: `writeDownTitle`, `writeDownBody`, `share`, `saved`.
  - Backup on: `onTitle`, `lastBackup(ago)`, `noBackupYet`, `working`, `automatic`, `backUpNow`, `errorTitle`, `codeTitle`, `codeBody`, `showCode`.
  - `reasons.{malformed, offline, timeout, unauthorized, notFound, quotaExceeded, tooLarge, corrupted, notConfigured, other}`.
- **Settings:** `strings.settings.backup` (`:859`), `strings.settings.onThisPhone`, `strings.settings.backupSummary.{off,on,notYetRun,working,attention,notConfigured}` (`:873-881`).
- **Shared:** `strings.common.tryAgain`, `strings.common.cancel` (`:13-16`), `strings.forms.codeCounter` (`:210`).
- **Privacy screen** (owned by another spec): `strings.privacy.backupOff`, `backupOffPaired`, `noBackupService`, `noBackupServicePaired`, `backupTitle`, `backupAccount`, `backupPassword`, `backupLocal`. These describe this feature (5 snapshots kept, deletes propagate) and must stay true.

---

## 10. Telemetry events (names and payload keys)

In RN the sink is console-only in development. Payload keys pass through an allowlist (`src/services/telemetry/index.ts`). **Never** include the recovery code, the account id, URIs or names. Native: use `os.Logger` with privacy annotations, or a seam with the same allowlist.

| Event | Kind | Payload | Source |
| --- | --- | --- | --- |
| `photo_uploaded` | event | `latencyMs`, `byteSize` | `src/services/sync/client.ts:90-93` |
| `photo_upload_failed` | error | `outcome` (reason), `latencyMs`, `byteSize` | `client.ts:81-87` |
| `backup_uploaded` | event | `latencyMs`, `byteSize`, `schemaVersion` | `client.ts:143-147` |
| `backup_upload_failed` | error | `outcome`, `latencyMs`, `byteSize`, `schemaVersion` | `client.ts:131-138` |
| `backup_snapshot_failed` | error | `durationMs`, `errorClass` | `src/services/sync/backup.ts:74-77` |
| `backup_too_large` | error | `byteSize` | `backup.ts:84` |
| `restore_rejected` | error | `schemaVersion`, `outcome: "newer_schema"` | `backup.ts:135` |
| `restore_failed` | error | `durationMs`, `errorClass` | `backup.ts:145-148` |
| `restore_succeeded` | event | `durationMs`, `byteSize`, `schemaVersion` | `backup.ts:152-156` |
| `photo_sync_pass` | event | `durationMs`, `itemCount`, `outcome: "complete"/"interrupted"` | `src/services/sync/photoSync.ts:185-189` |
| `backup_enable_failed` / `backup_restore_failed` / `backup_now_failed` | error | `errorClass` | `app/backup.tsx:134`, `:182`, `:325` |

---

## 11. RN/Expo workarounds that go away, and native replacements

| RN / Expo mechanism | Why it exists | Native replacement |
| --- | --- | --- |
| `expo-secure-store` (`identity.ts`) | JS has no keychain | Keychain Services, using the **same item attributes** (§3.7) |
| `expo-crypto.getRandomBytesAsync` / `digest` | JS has no CSPRNG or SHA | `SecRandomCopyBytes`; `CryptoKit.SHA256` |
| `asBufferSource` cast (`src/core/bytes.ts:19-31`) | TypeScript typing of `Uint8Array` | none (`Data`) |
| `AsyncStorage` for `lastBackupAt` | JS key-value store | `UserDefaults` after a one-time import (§12) |
| `AbortController` + `setTimeout` timeout; message-regex error classification | `fetch` has no typed errors; RN `fetch` is `whatwg-fetch` over XHR, which buffers the whole body | URLSession (ephemeral, no `URLCache`) + `URLError` codes + one 60 s deadline covering the full body (§4.1–4.2) |
| `SyncResult` tagged union "never throw" | ergonomic in JS | a Swift `enum SyncResult<T> { case success(T), failed(SyncFailureReason) }`, or `Result<T, SyncFailureReason>`. Keep non-throwing semantics at the service boundary. |
| `wal_checkpoint(TRUNCATE)` + `serializeAsync` | expo-sqlite API surface | `VACUUM INTO` temp file, or the GRDB backup API (§5.1) |
| `deserializeDatabaseAsync` + `backupDatabaseAsync` | avoid overwriting a live file | GRDB backup API from a temp-file `DatabaseQueue` (§6.2) |
| `invalidate()` revision counter (`src/providers/DatabaseProvider.tsx:68`) | React re-query trigger | Observation / explicit change notification after restore (§6.2) |
| `running` `useRef`; `busyRef`/`runningRef` double-tap refs | React state updates are async | actor-isolated flag; `@MainActor` state set before the first `await` |
| `restoring` flag on the screen (`app/backup.tsx:52-56`) | React unmount on status change | don't publish the adopted account until success (§9.2) |
| `AppState 'change' === 'active'` | RN lifecycle | `scenePhase == .active` |
| `KeyboardAvoidingView`, `keyboardShouldPersistTaps`, `useHeaderHeight`, safe-area insets | RN layout | SwiftUI `Form`/`ScrollView` handles this |
| `Share.share({message})` | no clipboard module | `ShareLink` |
| `Alert.alert` confirm | RN dialog | `.confirmationDialog` / `.alert` with `.destructive` role |
| `haptics.error()/success()` | RN haptics wrapper | `.sensoryFeedback(.error/.success, trigger:)` |
| `AccessibilityInfo.announceForAccessibility` | RN a11y | `AccessibilityNotification.Announcement` |
| `useNow(60_000)` | re-render ticker | `TimelineView(.periodic(…, by: 60))` |
| Hand-written `ago()` "because Hermes lacks Intl.RelativeTimeFormat" (`src/i18n/format.ts:28-33`) | Hermes | **Keep the hand-written function** anyway, for identical copy |
| Dynamic `import()` of identity/client in `importHousehold.ts:84-94` | bundle splitting | plain dependency injection |

---

## 12. Data left by the Expo build that the native app must pick up (in-place update)

| Data | Expo location | Native handling |
| --- | --- | --- |
| Recovery code | Keychain generic password, service `app:no-auth`, account `Data("sync.accountSecret.v1")`, implicit app-identifier access group, `WhenUnlocked` (§3.7) | Read it at launch, while unlocked and in the foreground. Keep using the same item. Do not add a `keychain-access-groups` entitlement without pinning the group. |
| `lastBackupAt` | `Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json`, key `sync.lastBackupAt.v1`, string ms (§5.3) | Imported once into `UserDefaults` as the same string by the shared importer (`02-device-storage-migration.md` §5.4). Leave the manifest in place. |
| Queue state | `item_photos.remote_synced_at`, `sync_deletions` in `Documents/SQLite/inventory.db` | No conversion. Same schema. |
| Photo files | `Documents/item-photos/<name>.webp` (or older `.jpg`). DB rows hold **absolute `file://` URIs** (`src/services/capture/imageStore.ts:27-45`, `:76-87`). | **Critical; see §13 B4.** Resolve by file name under the current container before deciding a photo is missing. |

---

## 13. Known RN bugs and divergences: decide before implementing

These come from reading the code. "Parity" means copy the bug; "fix" is the recommendation.

- **B1. Rehydration only ever covers the 10 newest synced photos.**
  - The query is `…WHERE remote_synced_at IS NOT NULL ORDER BY created_at DESC LIMIT 10` with no "file missing" filter, which SQL cannot express (`photoSync.ts:136-142`).
  - After pass 1 restores the newest 10, every later pass selects the same 10, finds them present and restores nothing.
  - So after restoring a library of more than 10 photos, the older ones are **never** re-downloaded, despite `strings.backup.restored` ("Photos will finish downloading shortly"). No test covers more than 10 photos.
  - **Fix:** scan all synced rows (cheap: id and uri only), filter to locally missing, then download sequentially. Either cap at 10 per pass or continue until interrupted.
- **B2. A permanently failing photo blocks the upload queue forever.**
  - Uploads go oldest first and stop at the first failure.
  - Examples: a non-UUID id (400), a file over 4 MiB (413), a **0-byte local file** (400 "Empty upload."; the empty bytes are truthy in JS, §7.2), or any other 4xx.
  - Every pass then retries the same photo first and stops. Every later photo never uploads.
  - **Fix:** on `too_large` or a 400, mark the photo as parked (e.g. a local skip-list, since the schema must not change), log it, and continue. Stop only on transient reasons (`offline`, `timeout`, `unauthorized`, `quota_exceeded`, `server_error`).
- **B3. A throw inside rehydration aborts the whole pass, including the database backup.**
  - `writeStoredPhoto` can throw when the image decode fails, and nothing catches it in `rehydrateMissingPhotos`/`syncPhotos`/`runPass`.
  - Because the same rows are re-selected, a remote photo that cannot be decoded can block **all automatic backups** indefinitely.
  - **Fix:** catch per photo, skip it, and continue. Always run `maybeBackup` even if photo sync failed.
- **B4. Absolute photo URIs versus the iOS container path.**
  - Rows store absolute `file:///…/Containers/Data/Application/<UUID>/Documents/item-photos/…`. Apple does not guarantee that path is stable across app updates.
  - `uploadPendingPhotos` **deletes the row** of any unsynced photo whose file is not found at the stored URI. After an update that moved the container, this would silently drop unsynced photos.
  - Rehydration would also re-download synced ones (and B1 limits it to 10).
  - **Must fix:** resolve every stored `file://` URI by its last path component under the current `Documents/item-photos/` before treating a file as missing. Optionally rewrite the row to the current path. Non-`file:` URIs (household cache or remote) count as "not local". Coordinate with the photo-storage spec.
  - Note: the file name is **not** necessarily the row id. `storeItemPhoto` names files with a separate `newId()` (`imageStore.ts:105`), while rehydrated files use the row id (`:162`).
- **B5. Photo upload content type.** The app always sends `Content-Type: image/jpeg` (`client.ts:77`), although captures are WebP (`imageStore.ts:24-25`). The Worker stores and serves `image/jpeg` for WebP bytes. Nothing reads it today; the app ignores the response type. **Option:** send `image/webp` or `image/jpeg` based on magic bytes. Both are allowlisted. See Q3.
- **B6. Enable causes a concurrent second backup** (§8.5). **Fix:**
  1. `enable` creates the account and runs the forced `runBackup`, with the pass guard held.
  2. Then run a normal pass. Its `maybeBackup` is skipped because `lastBackupAt` was just set.
- **B7. Automatic-pass failures are invisible, and a pass erases a manual `.error`** (§8.4). This is parity-relevant UX. Keep it unless the product owner wants automatic failures surfaced (Q5).
- **B8. Keychain read error, then "Turn on", orphans the old account.**
  - `loadAccount` maps a read error to "no account". The screen then offers "Turn on backup", which overwrites the item through `SecItemAdd`, then a duplicate error, then `SecItemUpdate`.
  - With `kSecAttrAccessibleWhenUnlocked`, a read attempted while the device is locked fails with `errSecInteractionNotAllowed`.
  - **The restore path is worse.** In the same state the screen also offers Restore. `importAccount` **overwrites** the hidden item with the typed code (`identity.ts:105-106`). If the restore then fails, `forgetAccount()` **deletes** it (`SyncProvider.tsx:190`). The original code is destroyed even though the user never confirmed anything about it. On success it is silently replaced.
  - **Fix:** distinguish `errSecItemNotFound` (really none) from other errors. On other errors, keep a distinct "keychain unavailable" state: status stays `.off`, but "Turn on" and "Restore" are disabled or a retry is offered. Never read the keychain from a background context while locked.
- **B9. `uploadBackup` does not validate the 201 body** (`client.ts:142`). A body without `capturedAt` writes `"undefined"` to storage, which reads back as `nil`. **Fix:** decode strictly with `BackupSummary: Decodable`. On mismatch return `malformed_response`, or record local time; see Q8.
- **B10. A non-numeric `x-snapshot-schema-version` on download** gives `NaN` in JS, and `NaN > 7` is false, so the restore proceeds. A missing header gives 0, and the restore proceeds. **Fix:** require a parseable integer of at least 1, otherwise `corrupted`. Better still, read `user_version` from the downloaded file (§6.2).
- **B11. The `corrupted` copy says "Nothing on this phone was changed".** That is false when `migrate()` fails *after* the backup-API swap (`backup.ts:139-150`). **Fix:** take a local pre-restore snapshot first (§5.1) and roll back to it if migration fails.
- **B12. iOS reinstall: the code survives in the keychain, and the empty DB gets backed up over the account.**
  - On reinstall, `loadAccount` finds the old code and the status is `idle`.
  - `lastBackupAt` is gone (AsyncStorage was wiped), so the first pass uploads the **empty** database as the newest snapshot. "Empty" means only migration 3's seeded drop-zone space and container (`src/db/migrations.ts:115-142`).
  - The pass runs as soon as the DB opens on first launch, **before onboarding has even finished**, because `SyncProvider` sits above the onboarding gate (`app/_layout.tsx:232-242`, §8.2). The user gets no chance to intervene.
  - The restore form is hidden whenever an account exists.
  - After five automatic backups (each at least 15 minutes apart), the real snapshots are pruned by retention.
  - **Fix candidates (Q2):**
    - Detect "account present + no `lastBackupAt` + local DB has no user rows" and offer "Restore your backup" (download `latest`) instead of auto-backing-up.
    - Or never auto-backup an empty inventory.
- **B13. Upload races a local delete.** If a photo row is deleted while its upload is in flight, the `UPDATE … WHERE id = ?` matches 0 rows and no tombstone exists (the row was unsynced when deleted). The remote copy is orphaned. **Fix:** after a successful upload, check whether the row still exists; if it is gone, enqueue a tombstone or issue the DELETE.
- **B14. Stale documentation, to avoid copying wrong facts.**
  - `worker/src/contract.ts:53` and `:86` say `capturedAt` and backup ids are client time. They are **server** time (`index.ts:311-320`).
  - `worker/src/contract.ts:21-25` says photos are 1600 px at q0.7. They are 1400 px at q0.8 (`src/services/capture/imageScaling.ts:22-23`).
  - `worker/README.md:19` says the secret is generated "at first launch". It is generated only on **Turn on backup**.
  - `worker/README.md:52-53` says photo bodies are "JPEG bytes" and "Streams the JPEG back". New photos are WebP bytes, labelled `image/jpeg` by the app (B5).
  - `photoSync.ts:41-46` says the row is "marked synced-with-nothing". The code **deletes** it.

---

## 14. Tests to port to Swift Testing

The Swift equivalents should use a real on-disk or in-memory GRDB database (as the Jest tests use real SQLite) and a fake `SyncClient` conforming to a protocol.

### 14.1 `src/services/account/__tests__/identity.test.ts` (base32 + identity)

The keychain is mocked with an in-memory map, plus "fail next read" and "fail next write" toggles (`:11-40`). The Swift version should run against a protocol-backed keychain fake.

| Test | Asserts |
| --- | --- |
| `cross-implementation vectors › encodes a known secret to the code the service expects` (`:50-52`) | `encode(0x42×16) == "89144GJ289144GJ289144GJ288"` |
| `… › derives the account id the service derives` (`:54-56`) | `accountId(0x42×16) == "900dfeb7f1b5e344209e2abce56c333d"` |
| `recovery code encoding › round-trips random secrets` (`:60-68`) | 50 random 16-byte secrets: `decode(encode(s))[0..<16] == s` |
| `… › survives the transcription mistakes it was chosen to survive` (`:70-79`) | `formatted.lowercased()`, with `1`→`l` and `0`→`o`, decodes to the same bytes (secret `0x11×16`) |
| `account lifecycle › reports no account on a device that has never had one` (`:83-85`) | `loadAccount() == nil` |
| `… › creates an account and finds it again` (`:87-93`) | code length 26; `loadAccount() == created` |
| `… › gives different devices different accounts` (`:95-101`) | two creates with the store cleared in between give different ids |
| `… › adopts an account from a code typed in any reasonable shape` (`:103-115`) | `import(formatted.lowercased())` succeeds; id is equal; stored code is canonical (equal to the original) |
| `… › refuses a code that decodes to too few bytes` (`:117-122`) | `import("89144")` gives `.malformed`; nothing stored |
| `… › refuses a code containing characters outside the alphabet` (`:124-129`) | `import("U"×26)` gives `.malformed` |
| `… › reports an unwritable keystore rather than claiming success` (`:131-136`) | a write failure gives `.unavailable` |
| `… › treats a keystore read failure as no account, not a new one` (`:138-144`) | a read throw gives `nil` |
| `… › forgets an account without touching anything else` (`:146-151`) | after `forget`, `load == nil` |

### 14.2 `worker/test/base32.test.ts` (server codec; port as extra codec tests)

| Test | Asserts |
| --- | --- |
| `round-trips every byte value` (`:7-13`) | for seeds 0…255, a 16-byte fill round-trips |
| `a 16-byte secret encodes to a code of the documented length` (`:15-18`) | `encode(0xFF×16).count == 26` |
| `folds the characters people actually mistype` (`:20-25`) | `decode("IOIO…")` (26 characters) and `decode("LOLO…")` both equal `decode("1010…")` |
| `ignores case, hyphens, and surrounding whitespace` (`:27-33`) | `"  " + formatted.lowercased() + "  "` decodes to bytes 1…16 |
| `rejects characters outside the alphabet` (`:35-39`) | `decode("U"×26)`, `decode("hello world")` and `decode("")` are all `nil` |
| `formats into readable groups without changing the value` (`:41-47`) | `format("89144GJ289144GJ289144GJ288") == "89144-GJ289-144GJ-28914-4GJ28-8"`; decoding either form gives equal bytes |

Add tests for the subtle cases (§3.3):

- `decode("Z").count == 0` (not `nil`).
- A 27-character code decodes to 16 bytes.
- `…88`, `…89`, `…8A` and `…8B` decode equal.
- An inner space makes the result `nil`.

### 14.3 `src/services/sync/__tests__/backup.test.ts`

The harness (`:15-124`): AsyncStorage is mocked; snapshot/restore use a SQL-dump fake; the fake client records uploads and its `capturedAt = 1000 × n`. `seededDb` creates the space "Garage", a box, and the item "Cordless Drill".

| Test | Asserts |
| --- | --- |
| `runBackup › uploads a snapshot tagged with the current schema version` (`:141-150`) | success; 1 upload; `schemaVersion == LATEST_SCHEMA_VERSION` |
| `… › sends a checksum so the service can reject a corrupted upload` (`:152-159`) | checksum matches `^[0-9a-f]{64}$` |
| `… › reports failure without recording a backup time` (`:161-168`) | `failed(.offline)`; the marker store is empty |
| `… › degrades cleanly on a backend that cannot snapshot itself` (`:170-179`) | `failed(.not_configured)` |
| `… › refuses a snapshot larger than the service accepts` (`:181-191`) | snapshot `MAX+1` bytes gives `failed(.too_large)`. The test asserts only the result, not `stored.count == 0`; add that assertion in Swift. |
| `maybeBackup › backs up when nothing has been backed up yet` (`:195-201`) | non-nil; 1 upload |
| `… › skips a backup taken too recently` (`:203-212`) | after a backup (`capturedAt` 1000), `now = 1000 + MIN − 1` gives `nil`; still 1 upload |
| `… › backs up again once the interval has passed` (`:214-222`) | `now = 1000 + MIN + 1` gives 2 uploads |
| `restoreBackup › brings back data that was deleted after the snapshot` (`:226-239`) | delete items, restore, and items equal `[Cordless Drill]` |
| `… › migrates a snapshot from an older build forward` (`:241-258`) | a snapshot of a DB at v1 restores successfully and `user_version == LATEST` |
| `… › refuses a snapshot written by a newer build` (`:260-270`) | `schemaVersion = LATEST + 1` gives `failed(.corrupted)` |
| `… › passes through a download failure without touching local data` (`:272-280`) | `failed(.offline)`; items unchanged |

### 14.4 `src/services/sync/__tests__/photoSync.test.ts`

The harness (`:15-104`): the image store is faked as a URI-to-bytes map. Its `writeStoredPhoto` writes `file:///documents/item-photos/<id>.webp` and `-thumb.webp`. The fake client tracks `remote`, `uploads`, `deletes` and `downloads`.

| Test | Asserts |
| --- | --- |
| `uploadPendingPhotos › uploads unsynced photos and marks them synced` (`:107-122`) | `{uploaded: 2, interrupted: false}`; both ids uploaded; no rows with `NULL remote_synced_at` |
| `… › does not re-upload a photo already synced` (`:124-132`) | no uploads |
| `… › drops a row whose local file has vanished rather than retrying forever` (`:134-145`) | uploaded 0; `item_photos` empty |
| `… › stops the pass when the service is unreachable, leaving work pending` (`:147-160`) | `{0, true}`; 2 rows still pending |
| `deletion tombstones › records a tombstone when a synced photo is deleted by cascade` (`:164-176`) | delete item, and `sync_deletions == [photo-a]` (trigger) |
| `… › records no tombstone for a photo that was never uploaded` (`:178-185`) | `sync_deletions` empty |
| `… › deletes remotely and clears the tombstone` (`:187-199`) | `{deleted: 1, interrupted: false}`; remote gone; tombstones empty |
| `… › keeps the tombstone when the delete could not be confirmed` (`:201-212`) | interrupted; 1 tombstone remains |
| `rehydrateMissingPhotos › pulls back files that a restore left behind, re-pointing the row` (`:216-239`) | `{1, false}`; `byte_size == 4`; file bytes at the row's `uri` equal the remote bytes; `uri == originalUri` and `thumb_uri == thumbUri`. The fake writes to the same `file:///documents/item-photos/<id>.webp` paths, so "re-pointing" is only observable as equality. The thumb file exists. Swift: assert the row now points at the *current* container path. |
| `… › leaves photos alone when the local file is present` (`:241-250`) | restored 0; no downloads |
| `… › skips a photo missing remotely instead of stalling the pass` (`:252-263`) | one 404 and one present gives `{1, false}` |
| `syncPhotos › reports a complete pass across all three directions` (`:267-275`) | `{uploaded: 1, deleted: 0, restored: 0, interrupted: false}` |
| `… › reports interruption when any direction could not finish` (`:277-284`) | `interrupted == true` |

### 14.4a `src/db/__tests__/nodeDatabase.test.ts` (snapshot/restore primitives)

These exercise the `snapshotAsync`/`restoreAsync` pair that §5.1 and §6.2 replace natively. Port them against the GRDB `BackupService` primitives.

| Test | Asserts |
| --- | --- |
| `file-backed node database › round-trips an in-memory snapshot` (`:31-44`) | create space "Loft"; snapshot; rename to "Attic"; restore, and the name reads "Loft" again on the same connection |
| `… › round-trips a snapshot through restore` (`:46-65`) | the same on a file-backed DB; the snapshot is a byte buffer; after restore, freshly built repositories read "Loft" |

Add native tests for each fix you adopt:

- Cross-platform: a native snapshot restores through an expo-sqlite-equivalent `sqlite3_deserialize` + backup-API path (§5.1).
- Zero-byte photo file: decide and test (parity uploads and gets a 400, B2).
- B1: 15 synced photos missing, and all 15 restored across passes.
- B2: a 413 photo does not block later photos.
- B3: a throwing decode does not abort.
- B4: a stale container path resolves by file name and the row is **not** deleted.

### 14.5 UI-logic tests

| File | Test | Asserts |
| --- | --- | --- |
| `src/ui/household/__tests__/status.test.ts` | `backupSummary › always has a value, including Off` (`:24-31`) | the mapping in §9.1 for unavailable, off, working, never-run and idle |
| | `backupSummary › marks a failed backup in signal` (`:33-38`) | error gives `attention` in signal tone |
| | `showBackupRow › always shows backup on a phone that keeps its own inventory` (`:42-46`) | not paired: true for off, unavailable, idle and error (working and never-run are not exercised) |
| | `… › hides it on a joined phone that never set it up (#48)` (`:48-51`) | paired + off or unavailable: false |
| | `… › keeps it on a joined phone that has a backup account` (`:53-57`) | paired + idle, never-run, working or error: true |
| | `backupReason › has plain words for every failure` (`:61-68`) | malformed, not_found and quota map to their keys; server_error, malformed_response and no_account map to `other` |
| | `… › never shows a raw reason code` (`:70-88`) | no output contains `_` |
| `src/ui/__tests__/code.test.ts` | `normaliseCode › drops spaces and hyphens and upper-cases` (`:4-7`) | `" mmwky-m2h78 "` and `"mmwky\nm2h78\t"` both give `"MMWKYM2H78"` |
| | `… › folds the look-alikes the way the server decodes them` (`:9-12`) | `"il0o"` gives `"1100"`; `"ILO"` gives `"110"` |
| | `invalidCodeChars › reports characters Crockford base32 never uses, once each` (`:16-20`) | `"U"` gives `["U"]`; `"ABUU!"` gives `["U","!"]`; a valid code gives `[]` |
| | `formatCode › groups in fives` (`:24-28`) | `""` gives `""`; `"MMWKY"` gives `"MMWKY"`; `"MMWKYM2H78A"` gives `"MMWKY-M2H78-A"` |
| `src/ui/household/__tests__/join.test.ts` | `codeProblem › accepts a full code however it was typed` (`:15-18`) | `nil` for formatted and lowercase-with-spaces input |
| | `… › names characters no code uses before complaining about the length` (`:20-22`) | `"MMWKU-M2H7%"` gives `chars "U %"` |
| | `… › reports the length of a short or long code` (`:24-30`) | 18 characters gives `length 18`; 27 gives `length 27` |
| `src/ui/__tests__/a11y.test.ts` | `spellCode › spaces the characters and pauses between groups` (`:14-16`) | `"DRW-7K2M"` gives `"D R W, 7 K 2 M"` |
| | `… › copes with a code without groups and with stray hyphens` (`:18-21`) | `"BOX1"` gives `"B O X 1"`; `"-AB--C-"` gives `"A B, C"` |
| `src/i18n/__tests__/format.test.ts` | `ago` table (`:20-48`) | `0`/`59 s`: "just now"; 1 min: "1 minute ago"; 5 min; 1 h; 3 h; 1 day and 47 h: "yesterday"; 2 days; 29 days; 30 days: "1 month ago"; 64 days: "2 months ago"; 365 days: "1 year ago"; 800 days: "2 years ago"; future: "just now" |

### 14.6 Worker route tests (`worker/test/routes.test.ts`): contract reference

These run server-side and **stay in TypeScript**. Use them as the oracle for a Swift `URLProtocol`-stub fake server or an optional integration test against `wrangler dev`.

| Test (line) | Contract fact |
| --- | --- |
| `health needs no credentials` (43) | `GET /v1/health` returns 200 with no auth |
| `every other route requires a recovery code` (48) | no `Authorization` gives 401 |
| `rejects a code that is not 16 bytes` (54) | a 4-byte code gives 401 |
| `enforces the shared app key when one is configured` (62) | key missing or wrong gives 401; correct key gives the route result (404 for an absent photo) |
| `stores and returns a photo` (83) | PUT gives 201; GET gives 200, `content-type image/jpeg`, same bytes |
| `one account cannot read another account photos` (97) | another code gives 404 |
| `rejects a photo id that is not a uuid` (110) | `..%2F..%2Fmeta%2Fusage.json` gives 400 |
| `refuses an oversized photo without buffering it` (123) | declared `content-length` of 4 MiB + 1 gives 413 |
| `replacing a photo does not double-count usage` (137) | 100 B then 40 B gives usage `{bytes: 40, objects: 1}` |
| `deleting a photo frees its usage and is idempotent` (149) | DELETE twice gives 204, 204; usage bytes 0 |
| `stores a snapshot and serves it back as latest` (170) | PUT with schema 3 gives 201 and `summary.schemaVersion 3`; `GET latest` gives 200, `x-snapshot-schema-version: 3`, same bytes |
| `requires a schema version on a snapshot` (194) | no header gives 400 |
| `rejects a snapshot whose bytes do not match the declared checksum` (203) | wrong sha256 gives 422 |
| `keeps only the retention window, dropping the oldest` (220) | 8 PUTs leave 5, newest first, and they are the last 5 written |
| `listing and latest stay scoped to the calling account` (254) | another code gets `[]` and `latest` 404 |
| `usage counts photos and snapshots together` (278) | 10 + 20 + 30 gives `{bytes: 60, objects: 3}` |
| `a corrupt usage counter is rebuilt from what is stored` (302) | garbage `usage.json` gives a recompute of 128 |
| `unknown routes are not found` (319) | `/v1/anything` with a valid code gives 404 |
| `records the image type the client declares, and serves it back` (325) | PUT `image/webp`, GET `image/webp` |
| `falls back to jpeg for an unrecognised or missing declared type` (343) | `text/html` is stored as `image/jpeg` |

Household Worker tests (no phone involvement):

- `worker/test/household-photos.test.ts:29`, `:70`, `:79`, `:97`, `:123`
- `worker/test/household-db.test.ts:29`, `:72`

They cover the secret gate, 503 when unset, thumb keys, bad id or kind (400), idempotent delete, and the db list/delete scope. They need no Swift port.

---

## 15. Open questions

1. **Q1. `syncKey` in production.** `EXPO_PUBLIC_SYNC_KEY` is absent from `eas.json`. Is `SYNC_SHARED_SECRET` set on the deployed Worker, with the key injected as an EAS secret? The native build needs the same value (xcconfig / Info.plist), or every request 401s.
2. **Q2. iOS reinstall with a surviving keychain code (B12).** Should the native app offer a restore when it finds an account but an empty local inventory and no `lastBackupAt`? This is a product decision. Today's behaviour silently erodes the real backups.
3. **Q3. Photo `Content-Type` (B5).** Keep sending `image/jpeg` for parity, or send the real type? Nothing depends on it today.
4. **Q4. Background execution.** Parity is "on foreground only". Should native add `BGAppRefreshTask` or `BGProcessingTask` for backups, or a background `URLSession` for the up-to-32 MiB snapshot? That needs the keychain read while possibly locked: `kSecAttrAccessibleWhenUnlocked` would require migrating the item to `AfterFirstUnlock`, which changes the stored item's attributes.
5. **Q5. Surfacing automatic failures (B7).** Should automatic backup failures show in Settings ("Needs attention") or on the Backup screen? Today they are silent.
6. **Q6. Timeouts.** RN bounds the **whole** exchange at 60 s, upload plus full response download (§4.1). A 32 MiB snapshot upload or restore download on a slow link (under ~4.5 Mbit/s) therefore fails as `timeout` today. Keep 60 s for parity, or give backup PUT/GET a longer budget (photo calls stay at 60 s)?
7. **Q7. TLS and idle-timeout failures.** In RN every transport error, including TLS failures and a URLSession idle timeout, surfaces as `TypeError('Network request failed' | 'Network request timed out')` and maps to `offline` (§4.2). Parity therefore maps `URLError.secureConnectionFailed`, `.serverCertificate*` and `.timedOut` to `offline`. Confirm, or map `.timedOut` to `timeout` (copy-only divergence).
8. **Q8. 201 body validation (B9).** Strict decode giving `malformed_response`, or accept the upload and record local time? The bytes *were* stored.
9. **Q9. Copy-to-clipboard for the code.** RN only had Share and selectable text. Is adding "Copy" acceptable given the clipboard exposure? It would need a `UIPasteboard` expiration.
10. **Q10. Batch size.** Keep `BATCH_SIZE = 10` per direction per pass, or loop until the queue drains or is interrupted? Large backlogs take many foregrounds today.
11. **Q11. Household mode interplay.** While paired, the local DB is a shadow of the household. The shadow inserts `item_photos` with `remote_synced_at = Date.now()` and household URIs (`src/services/household/shadow.ts:200-218`). Personal sync still runs over that DB:
    - Uploads skip shadow photos.
    - Rehydration tries to download them from the *personal* bucket. That gives a 404 and they are skipped, but they count toward the 10-row window (B1).
    - Deleting shadow rows creates personal tombstones, which cause harmless 204 deletes.
    - Personal snapshots include household shadow rows.

    Is that intended, and should native exclude shadow photos from personal photo sync? *(Corrected in the consistency pass.)* Shadow photo rows are written **only** by `upsertItemGraph` after `items.create`, and the HTTP `items.create` returns the server body **unhydrated** (`src/services/household/httpRepositories.ts:248-268`, `return created`), so the stored `uri`/`thumb_uri` are always the server's `r2:household/primary/photos/<id>[-thumb].webp` strings (`src/services/household/shadow.ts:200-221`; `04-household.md` §7; `02-device-storage-migration.md` §3.2 shape 3). Hydrated `file:` cache URLs exist only in memory (`httpRepositories.ts:87-121`) and are never mirrored. A "non-`file:` URI" filter (or "`uri` starts with `r2:`") therefore identifies shadow photo rows reliably today. Rows imported into the household (§11 of 04) live on the server, not locally.
12. **Q12. Orphaned files after restore.** Photo files present before a restore are left on disk. Should native sweep `item-photos/` for files no row references after a successful restore?

---

## 16. Dependencies on other areas

- **Database / migrations spec:**
  - Exact schema incl. migration 4 (`remote_synced_at`, `idx_item_photos_unsynced`, `sync_deletions`, `item_photos_tombstone` trigger) (`src/db/migrations.ts:144-182`).
  - The ported `migrate()` runner and `LATEST_SCHEMA_VERSION` (`:265-311`).
  - DB file location `Documents/SQLite/inventory.db`.
  - `PRAGMA journal_mode = WAL`, `foreign_keys = ON`.
  - A "post-restore invalidate everything" hook.
  - **Migration governance across platforms:** iOS must never ship a `LATEST_SCHEMA_VERSION` that Android RN has not shipped, because snapshots cross platforms under the same recovery code (§5.1).
  - A "DB ready" signal the sync engine can observe (pass trigger, §8.3).
- **Photo storage / capture spec:**
  - `readStoredPhoto` / `writeStoredPhoto` / `deleteStoredPhotos` semantics (`src/services/capture/imageStore.ts:137-198`).
  - Thumbnail regeneration at 320 px q0.7. iOS ImageIO decodes WebP; check whether native can *encode* WebP thumbnails or must switch format.
  - The **absolute-URI rebasing** rule (B4).
  - Lowercase UUID photo ids (`src/core/id.ts:41-54`).
- **Storage migration (first launch of the native build):**
  - Import AsyncStorage `sync.lastBackupAt.v1` from the RN manifest (§5.3, §12).
  - Read the keychain item with Expo's attributes (§3.7).
- **Household spec:**
  - `importLocalInventory` uses `loadAccount` + `createSyncClient().downloadPhoto` as a fallback source of photo bytes when the local file is missing (`src/services/household/importHousehold.ts:41-51`, `:84-94`). The native `SyncClient` and `AccountStore` must be usable from there.
  - `session != nil` drives `pairedNote` and `showBackupRow`.
  - Shadow photo rows (Q11).
- **Settings / Privacy / navigation specs:**
  - The Settings backup row (§9.1).
  - The Privacy copy that describes this feature (§9.8).
  - The Backup screen route and title.
- **Shared UI components:** banner (info/warning, title, action), toast, confirmation dialog, haptics, code text style. The code input belongs to the shared form components (also used by household join).
- **i18n:** all copy keys in §9.8, plus `ago()` from `src/i18n/format.ts`.
- **Config:** `syncEndpoint`, `syncKey`, `syncTimeoutMs` as build settings (§2).

---

## 17. Reviewer notes

An adversarial review re-read every file in scope plus RN's `fetch` polyfill, `DatabaseProvider`, telemetry, entitlements and the household photo cache. Every citation, constant, SQL statement, header, status code, test name and test-vector row in §3.8 was re-checked; the vectors were recomputed in Node and all five match. What changed:

**Corrections**

- **§4.1 timeout window was wrong.** On device, RN `fetch` is `whatwg-fetch` over XHR. It resolves only after the full response body arrives (`node_modules/whatwg-fetch/dist/fetch.umd.js:546-562`). So the 60 s deadline covers the full body download, not just the headers. The native guidance and Q6 were rewritten to match.
- **§4.2 classification table.** A URLSession idle timeout surfaces in RN as `TypeError('Network request timed out')` and maps to `offline`, not `timeout` (`fetch.umd.js:571-575`). The table had mapped `URLError.timedOut` to `timeout` as if that were parity. Q7 is updated.
- **§8.3 triggers were incomplete.** The pass effect also re-runs when `repos` becomes ready, because `runPass` depends on `[repos, client, account]`. On a cold launch, whichever of "account loaded" and "DB opened" finishes last starts the first pass. Also corrected: iOS `inactive` interruptions do not include the share sheet.
- **§9.3 restore().** Only `busyRef` is set before the confirmation (`app/backup.tsx:157`). The visible busy/loading state is not set during the dialog.
- **Citation fixes:** `auth.ts:116-128` → `:116-127`; code field `:224-227` → `:219-230`.
- **§14 test descriptions made exact:**
  - The too-large test does not assert "no upload".
  - The rehydrate test asserts URI *equality*, because the fake writes to the same paths.
  - The not-paired `showBackupRow` test does not cover every status.
- **§2:** the default timeout lives in `config.ts:71`. Added the `Number("") = 0` quirk.

**Additions**

- §3.3: JS `trim()` also strips newlines and U+FEFF; use `.whitespacesAndNewlines` in Swift.
- §3.7: expo-secure-store write semantics.
  - After a successful add, it deletes the legacy and `auth` variants.
  - A duplicate is updated with the value only, so accessibility is unchanged.
  - Reads stop at the first non-not-found error.
  - Access-group pinning, because the Expo entitlements are empty.
  - `createAccount` overwrites an existing item.
- §4.1: use an ephemeral `URLSession` with no `URLCache`. Photo responses are `cache-control: private, max-age=31536000, immutable`.
- §5.1: cross-platform restore compatibility. Android RN restores native snapshots and vice versa. This adds a schema-governance dependency and a fixture test.
- §5.3: the `lastBackupAt` marker is global, not per account. The RN store is excluded from iCloud backup; `UserDefaults` is not.
- §7.2 / §7.4 / B2: a 0-byte file is truthy in JS, so it is uploaded, gets a 400 and blocks the queue forever; rehydration treats it as present. Rehydrated bytes may be JPEG under a `.webp` name.
- §8.2: `SyncProvider` sits above the onboarding gate, so passes run during onboarding. B12 is strengthened accordingly.
- §9: the screen has no "turn off" or "forget code" action. Added the newline/focus handling note for the native code field.
- B8: restoring while an existing keychain item is unreadable overwrites the original code, and a failed restore then deletes it.
- B14: README "JPEG bytes" is stale.
- Q11: a "non-`file:` URI" filter does not exclude shadow photos, which live in the household cache.
- §14.4a: `src/db/__tests__/nodeDatabase.test.ts` snapshot/restore round-trip tests, plus new native test ideas.
- §0 / §16: added supporting files and dependencies.

**Completeness / consistency pass (cross-spec critic)**

- **Q11 corrected:** the previous text claimed shadow rows "often carry `file:` URIs" into the household cache. They do not: the shadow mirror runs on the unhydrated `items.create` body, so shadow `item_photos` rows always hold `r2:` URIs (`httpRepositories.ts:248-268`, `shadow.ts:200-221`). This now agrees with 02 §3.2 (shape 3) and 04 §7. A non-`file:` filter is sufficient to skip them.
- **§5.1 (b) / §6.2 step 3:** the live database is a single GRDB `DatabaseQueue` (cross-spec decision recorded in `00-index.md`, `01-data.md` §2.2, `02-device-storage-migration.md` §2.3), not a `DatabasePool`.
- **B4 / §12 photo files:** the resolver to use is `PhotoPathResolver` (`02-device-storage-migration.md` §3.3), which also rebases Android-restored paths by file name. 05 §9.7 was aligned to it.
- **§5.3 storage type:** the native recommendation was "an `Int64` or `Double`" in `UserDefaults`; 02 §5.3-5.4 and 09 §4.4 keep the raw string (imported verbatim, written as an integer string, parsed with JS-`Number` rules). Aligned to the string form.
- **§8.7 vs 09 Q13:** this spec recommends serialising `runPass`, `enable`, `backupNow` and restore through one actor (B6); 09 lists RN-parity vs fix as open question Q13. The index records the recommendation (fix) and keeps Q13 as the user-facing decision.
