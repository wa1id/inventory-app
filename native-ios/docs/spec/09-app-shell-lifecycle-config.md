# 09 — App shell: boot sequence, providers, lifecycle, config, telemetry, errors

Porting spec for the native iOS app (Swift 6, SwiftUI, iOS 26+, GRDB) that replaces the Expo / React Native app **in place** (same bundle id `com.wystudio.inventory`, shipped as an App Store update).

## 0. Scope, sources, conventions

**In scope:** `app/_layout.tsx`, `src/providers/DatabaseProvider.tsx`, `HouseholdProvider.tsx`, `SyncProvider.tsx`, `ConnectionProvider.tsx` (lifecycle side), `FontProvider.tsx`, `OnboardingProvider.tsx` and `ToastProvider.tsx` (both part of the provider tree), `src/ui/components/BootScreen.tsx`, `ScreenFrame.tsx`, `BottomBar.tsx` (+ `ConnectionBanner.tsx`, `Toast.tsx` `OverlayHost`, `ErrorState.tsx` as shell pieces), `src/services/config.ts`, `src/services/appInfo.ts`, `src/services/telemetry/index.ts`, `src/ui/errors.ts`, `src/hooks/useInventoryQuery.ts`, `expo-env.d.ts`, `.env*`, `eas.json`, `app.json`, `babel.config.js`, `tsconfig.json`.

**Also read because they matter for boot:** `src/db/expoDatabase.ts`, `src/db/migrations.ts`, `src/db/repositories.ts`, `src/services/household/{client,session,importOffer}.ts`, `src/services/onboarding.ts`, `src/services/account/identity.ts`, `src/services/sync/{client,backup,contract}.ts`, `src/services/capture/imageStore.ts`, `src/core/{id,conflict}.ts`, `src/ui/motion.ts`, `src/hooks/useDelayedFlag.ts`, the generated (gitignored) `ios/` project, and the iOS sources of `expo-sqlite`, `expo-secure-store` and `@react-native-async-storage/async-storage` in `node_modules/` (to pin the on-device storage locations exactly).

**Not read:** `.env.local`. Reading it was denied, even key names only, and the reviewer's key-names-only attempt was denied too. Its keys are inferred from `.env.example` and `src/services/config.ts`. No secret values appear anywhere in this document.

**Sibling specs:** `01-data.md` (schema and migration runner), `02-device-storage-migration.md` (**owner** of the legacy import, the Expo-compatible keychain, photo path resolution and target settings), `03-sync-account.md`, `04-household.md`, `05-capture-ai.md`, `06-screens-shell-home.md`, `07-screens-entities.md`, `08-design-i18n-platform.md`. Where this document summarises one of them, that spec wins.

**Conventions**
- Citations are `path:line` or `path:start-end`. `node_modules/...` citations refer to the installed versions (expo-sqlite 57.0.x, expo-secure-store 57.0.x, async-storage 3.1.1).
- User-facing copy is referenced by its key in `src/i18n/strings.ts` (e.g. `strings.boot.opening`), never re-pasted.
- "Native" means the proposed Swift implementation. **MUST** marks behavior that has to stay identical. **RECOMMEND** marks a native improvement or a choice still to confirm.

---

## 1. TL;DR for the Swift engineer

1. **Boot needs three things before the main UI shows** (`app/_layout.tsx:97-103,142-156`): the SQLite database opened and migrated, the onboarding flag read, and the household session read from the keychain. If the database fails, show a full-screen error with Try again, even while the other two are still loading. Fonts are never waited for, and natively they go away entirely.
2. **First launch after the update MUST adopt the Expo build's data in place:**
   - SQLite at `Documents/SQLite/inventory.db`.
   - Keychain items under service `app:no-auth`.
   - AsyncStorage values in `Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json`.
   - Photos in `Documents/item-photos/`.

   Exact formats are in §3.1. Do the AsyncStorage import before the onboarding flag is read. Otherwise every existing user sees onboarding again.
3. **Seven providers become `@MainActor @Observable` app models**, injected through the SwiftUI environment: Database (+revision), Household, Connection, Sync, Onboarding, Toast, and the tabs-scoped DropZone. FontProvider is dropped (§4).
4. **App-wide reactivity is a revision counter, not observation.** Every write calls `invalidate()`. Each on-screen query re-reads when it gains focus, or when the revision changes while it is focused. A failed refresh keeps the last data for the same key (§5). Keep this design: it works the same for local SQLite and for paired HTTP reads.
5. **Foreground handling** (`scenePhase == .active`) triggers two things (§6):
   - one sync pass (photos first, then backup if 15 min have passed), guarded against overlap;
   - when paired, a list refresh at most every 5 s. The first evaluation while paired and active only arms the throttle; on a normal launch that is the moment the session finishes loading, not a scene transition (§4.3).

   While offline and active, the health endpoint is pinged every 10 s. Nothing happens on background. Both lifecycle consumers live **above** the onboarding gate in RN, so they run even while onboarding is showing (§3.2).
6. **Config is build-time** (§8):
   - `development` / `preview` / `production`.
   - Two endpoints: recognition URL and sync URL.
   - The shared app key, sent as header `x-inventory-key`. There are two config entries (recognition, sync), and both are extractable by design.
   - Timeouts of 15 s and 60 s.
   - Household origin, default `https://inventory.wystudio.be`.

   Natively: xcconfig per configuration, then Info.plist, then a Swift `AppConfig` parsed with the same trimming and default rules. Keys go in a gitignored `Secrets.xcconfig` generated by CI.
7. **Telemetry has no vendor and no network.** Events go through an allowlist redactor, and the default sink prints only in debug builds. The privacy screen promises this (`strings.privacy.diagnosticsBody`), so keep a no-op release sink unless that copy changes (§9).
8. **Errors are never shown raw.** `describeError(cause, context, subject)` maps everything to 7 kinds and copy keys (§10). Port it, and its tests, verbatim.
9. **GRDB caveat that affects boot:** do **not** use `DatabaseMigrator`. It adds a `grdb_migrations` table, and backups and household dumps are SQLite-schema-dependent. Re-implement the `PRAGMA user_version` runner exactly (§13.5).

---

## 2. RN boot sequence today (reference behavior)

### 2.1 Module-load side effects (before any render)

| What | Where | Native |
|---|---|---|
| Installs the CSPRNG used by `newId` / `newQrToken`: `configureRandomBytes((n) => Crypto.getRandomBytes(n))` | `src/providers/DatabaseProvider.tsx:15`; injection seam `src/core/id.ts:15-17` | Not needed. Use `SecRandomCopyBytes` or `SystemRandomNumberGenerator` directly. **MUST** keep "no weak fallback": `id.ts:26-33` throws if no source is installed, and native must `fatalError` or throw rather than fall back to a weak generator. **MUST keep the persisted id formats** (they are stored in SQLite and sent to the household and sync services): `newId` = RFC 4122 v4 layout from 16 random bytes, byte 6 = `(b & 0x0f) \| 0x40`, byte 8 = `(b & 0x3f) \| 0x80`, **lowercase** hex, 8-4-4-4-12 (`id.ts:41-54`, `src/core/bytes.ts:10-17`). `UUID().uuidString` is upper-case, so lowercase it or format the bytes yourself. `newQrToken` = 32 lowercase hex chars from 16 random bytes (`id.ts:62-64`). Tests: §14.1 (`id.test.ts`). |
| `appConfig` evaluated once from inlined `EXPO_PUBLIC_*` values | `src/services/config.ts:65-76` | `AppConfig.load(from: Bundle.main)` once in the composition root (§8). |
| `appVersion` from `Constants.expoConfig.version`, default `'0.0.0'` | `src/services/appInfo.ts:4` | `Bundle.main.infoDictionary["CFBundleShortVersionString"]`. Shown in Settings (`app/settings.tsx:104`). |
| Telemetry sink defaults to `consoleSink`. `setTelemetrySink` is never called anywhere (grep) | `src/services/telemetry/index.ts:70-79` | §9. |
| Entry point is expo-router (`"main": "expo-router/entry"`) | `package.json` | `@main struct InventoryApp: App`. |

### 2.2 Provider tree (outermost to innermost)

Source: `app/_layout.tsx:223-249`.

| # | Provider | Gates render? | Depends on | Why it sits here (source) |
|---|---|---|---|---|
| 1 | `SafeAreaProvider` | no | — | RN-only plumbing. |
| 2 | `FontProvider` | **never** | — | "Outermost and never gating" (`_layout.tsx:226`; `FontProvider.tsx:33-40` file doc). |
| 3 | `DatabaseProvider` | yes (via gate) | — | Owns DB state and `revision`. |
| 4 | `HouseholdProvider` | yes (via gate, `ready`) | — | Session from keychain. |
| 5 | `ConnectionProvider` | no | Household (session), Database (`invalidate`) | "Needs the session; above Sync so both see the same connection" (`_layout.tsx:230`). |
| 6 | `SyncProvider` | no | Database (`state`, `invalidate`) | Above the readiness gate on purpose: it handles a not-ready DB itself, and mounting it below the gate would restart every sync pass whenever the gate re-rendered (`_layout.tsx:232-237`). |
| 7 | `OnboardingProvider` | yes (via gate) | — | Shared state so the gate flips in the same tick (`OnboardingProvider.tsx:18-25`). |
| 8 | `RootNavigator` (the gate) | — | all of the above | `_layout.tsx:104-221`. |
| post-gate | `ThemeProvider` then `ToastProvider` then `Stack` + `OverlayHost` | — | — | Exist only once ready (`_layout.tsx:158-220`). |
| tabs scope | `DropZoneProvider` | — | Repositories | Mounted in `app/(tabs)/_layout.tsx:19`, so it refreshes like a screen. |

`useRepositories()` (`DatabaseProvider.tsx:108-120`) reads both Database and Household, so it is only valid in screens below the gate.

### 2.3 Concurrent boot tasks

All of these start in the first commit's effects. None awaits another. React runs child effects before parent effects, so they *start* in the order Onboarding, Sync, Connection, Household, Database, Font. They are fire-and-forget async, so they *finish* in no defined order.

| Task | Source | Storage | Success | Failure | Gates UI |
|---|---|---|---|---|---|
| Open + migrate DB | `DatabaseProvider.tsx:41-66` → `expoDatabase.ts:72-77`, `repositories.ts:31-34`, `migrations.ts:284-313` | `Documents/SQLite/inventory.db` | `state = ready(repos)`; `logEvent('database_ready', {durationMs})` (`:50`) | `state = error(message)`; `logEvent('database_open_failed', {durationMs})` (`:54`). This is sent as an *event*, not an error. | **yes** |
| Load household session | `HouseholdProvider.tsx:34-46` → `session.ts:7-29` | Keychain `household.session.v1` | `session = stored or null`, `ready = true` | Any error or invalid JSON gives `null` (`session.ts:12-18,26-28`), so the phone looks **unpaired** | **yes** (`ready`) |
| Read onboarding flag | `OnboardingProvider.tsx:29-31` → `onboarding.ts:10-18` | AsyncStorage `onboarding.completed.v1` | `'completed'` iff the value is the string `'true'`, else `'pending'` | Read error gives `false`, so `'pending'`: onboarding shows again (`onboarding.ts:14-17`) | **yes** |
| Load sync account (only if `syncEndpoint`; with no endpoint the keychain is never read and status stays `unavailable`) | `SyncProvider.tsx:74-88` → `identity.ts:52-69`, `backup.ts:29-37` | Keychain `sync.accountSecret.v1`, AsyncStorage `sync.lastBackupAt.v1` | `status = idle(account, lastBackupAt)`. The stored code must base32-decode to exactly 16 bytes, otherwise it counts as no account (`identity.ts:63-66`). `account.id` = lowercase hex of the first 16 bytes of SHA-256(secret) (`identity.ts:131-134`; the sync area owns the codec) | A keychain error, an empty value or a bad code gives `null`, and status stays `off` (`identity.ts:54-61`). It never creates a new account | no |
| Load fonts | `FontProvider.tsx:46-59` | bundled TTFs | `fontsReady = true` | `logError('fonts_failed')`; system font forever | no |
| iOS Bold Text query + listener | `FontProvider.tsx:61-74` | — | `boldText` | ignored | no |
| `markJoinedBefore()` when a session is known | `ConnectionProvider.tsx:81-83` → `importOffer.ts:45-51` | AsyncStorage `household.joinedBefore.v1 = 'true'` | — | ignored | no |

Cross-task dependencies:
- The first sync pass needs both `repos` (DB ready) and `client` (account loaded): `SyncProvider.tsx:97-98,114-123`.
- The connection subscription needs a session: `ConnectionProvider.tsx:81-82`.

### 2.4 The gate, its precedence, and recovery UI

`RootNavigator` (`app/_layout.tsx:104-221`) checks, in order:

1. **`database.state == error`** shows the full-screen `ErrorState` inside a safe area (`:142-152`):
   - title `strings.boot.failedTitle`, body `strings.boot.failedBody`;
   - one button, `strings.common.tryAgain`, which calls `retry()`.

   This is checked **first**, so it shows even if onboarding or the session are still loading. The raw `message` kept in state (`DatabaseProvider.tsx:55-59`) is **never displayed**. `ErrorState` announces its heading to VoiceOver on iOS (`ErrorState.tsx:60-62`). Its `accessibilityLiveRegion="assertive"` is Android-only.
2. **`database.state == loading || onboarding.status == 'loading' || !household.ready`** shows `BootScreen` (`:154-156`).
3. Otherwise the main stack (`:158-220`).

**Retry** (`DatabaseProvider.tsx:69-72`): sets `state = loading` and bumps `attempt`. The effect re-runs and calls `openDatabaseAsync` again, then `migrate` again. The previous handle is never closed explicitly. expo-sqlite returns its **cached native connection** for the same path and options (`node_modules/expo-sqlite/ios/SQLiteModule.swift:107-111`), so in practice the retry re-runs the pragmas and the migration on the same connection. A stale attempt's result is ignored through the `cancelled` flag (`:42,49,53,63-65`). The fallback message `'The inventory database could not be opened.'` (`:58`) is only kept in state and is never shown.

**BootScreen** (`src/ui/components/BootScreen.tsx:15-31`):
- the brand mark at size 52 (`:21`);
- the caption `strings.boot.opening`, which appears only after `delay.bootCaption = 400` ms (`:17`, `src/ui/motion.ts:29`, `src/hooks/useDelayedFlag.ts:12-25`);
- the caption line is reserved (`minHeight: 20`) so the mark does not move (`:41-44`);
- `accessibilityLiveRegion="polite"` (`:22`) is Android-only, so iOS announces nothing.

**There is no other boot recovery UI.** Keychain and AsyncStorage failures degrade silently: unpaired, or onboarding shown again. There is **no React error boundary** (grep finds no `ErrorBoundary`), so a render exception crashes the app.

### 2.5 Post-gate shell

- **Navigation chrome** (`_layout.tsx:40-55,122-140`):
  - header background and screen background are the theme background, with no header shadow;
  - the back button shows no title (`headerBackButtonDisplayMode: 'minimal'`);
  - no large titles, because iOS 26 hides a large title when the header has a background colour (`:125`);
  - full-screen swipe-back (`fullScreenGestureEnabled`, `:137`);
  - Android-only fade under Reduce Motion (`:138`).

  Natively, use stock `NavigationStack`. The RN app avoided native large titles only because of that iOS 26 custom-header-background quirk; it then **drew large titles in content** (tab roots via `TabRootHeader`, detail screens via `useCollapsingTitle`). The native equivalent is therefore system **large titles** on tab roots and on space/container/item detail screens (`06-screens-shell-home.md` §5.2, §16.6; `07-screens-entities.md` §0.11 / Q9), and inline titles on sheets, forms and the other pushed screens. iOS 26 provides the content back-swipe. *(Consistency pass: this line previously said "inline titles" everywhere.)*
- **Route table and presentation** (`_layout.tsx:165-213`). Titles are `strings` keys; `''` means the screen titles itself in its content. A sheet is a modal sheet with a "Cancel" leading item (`SheetClose`, `:62-90`). A full-screen modal has no header (`:92-95`).

  | Route | Presentation | Title |
  |---|---|---|
  | `(tabs)` | root, no header | — |
  | `settings` | push | `strings.settings.title` |
  | `household` | push | `strings.household.screenTitle` |
  | `backup` | push | `strings.backup.title` |
  | `privacy` | push | `strings.privacy.title` |
  | `space/new` | sheet | `strings.spaceForm.newTitle` |
  | `space/[id]` | push | `''` |
  | `space/[id]/edit` | sheet | `strings.spaceForm.editTitle` |
  | `container/new` | sheet | `strings.containerForm.newTitle` |
  | `container/[id]` | push | `''` |
  | `container/[id]/edit` | sheet | `strings.containerForm.editTitle` |
  | `container/[id]/qr` | push | `''` |
  | `container/[id]/link` | full-screen | — |
  | `item/new` | sheet | `strings.add.title` |
  | `item/[id]` | push | `''` |
  | `item/[id]/edit` | sheet | `strings.editItem.title` |
  | `item/[id]/move` | sheet | `''` (set by the screen) |
  | `item/[id]/photo` | full-screen, fade | — |
  | `capture/index` | full-screen | — |
  | `capture/review` | push, back button hidden | `''` |
  | `c/[token]` (deep link) | push | `strings.deepLink.title` |
  | `onboarding` | root when pending, no header, no swipe gesture | — |
- **Guards** (`Stack.Protected`, `:165,208`). Every app screen requires `onboarding.status == 'completed'`, and `onboarding` requires `'pending'`. Flipping the status swaps the whole stack with **no navigation call**: completing onboarding is `app/onboarding.tsx:49-51`, and replaying it from Settings is `app/settings.tsx:85-90`. A deep link that arrives while onboarding is pending has nowhere to go (the guarded route is unavailable).
- **Cold deep link anchor** (`unstable_settings = { anchor: '(tabs)' }`, `_layout.tsx:33-37`). A QR link (`inventory://c/<token>`, `src/repositories/qr.ts:29`) opened from cold gets Home underneath, so Back has somewhere to go.
- **`SheetClose`** (`:57-85`). On iOS it is a text button `strings.common.cancel` that calls `router.back()`. That path goes through the form's dirty guard exactly like a swipe-down.
- **`OverlayHost`** is rendered after the stack (`:215-216`, `Toast.tsx:226-252`). It hosts the toast and the removed-phone layer above everything, including native sheets: on iOS through `FullWindowOverlay`, a separate window. The overlay is accessibility-modal **only while revoked** (`Toast.tsx:234-247`). It is rendered regardless of onboarding status, so the revoked layer can appear over onboarding too.
- `SystemUI.setBackgroundColorAsync(plaster)` (`:113-115`) and `<StatusBar style="auto">` (`:162`) are RN plumbing. Native needs neither. The first one leaves an Int `ExpoSystemUI.backgroundColor` in the **standard** `UserDefaults` domain, which the native app inherits because the bundle id is the same. The legacy import removes it (`02-device-storage-migration.md` §6).

### 2.6 Timeline

```
t0  JS bundle loaded; module side effects (§2.1)
t0  RootLayout renders → gate shows BootScreen immediately (nothing blocks first render)
    ├─ open DB → WAL, FK on → migrate (user_version → 7)   ─┐
    ├─ SecureStore get household.session.v1                 ├─ all three needed
    ├─ AsyncStorage get onboarding.completed.v1            ─┘
    ├─ SecureStore get sync.accountSecret.v1 (+ lastBackupAt)  (not gating)
    └─ font load (not gating)
+400ms  caption "strings.boot.opening" appears if still booting
session ConnectionProvider (above the gate): markJoinedBefore (if paired), reachability subscription,
loaded  resume-refresh throttle armed if the app is active
DB+acct SyncProvider (above the gate): first pass as soon as DB ready AND account loaded, whatever
        the onboarding status
ready   (all three gate inputs) Theme+Toast+Stack+Overlay mount; guarded screens mount and run their queries
```

---

## 3. Native boot sequence (proposed)

### 3.1 Data the Expo build leaves on the device (adopt in place, do not re-create)

**SQLite**
- Location: `<Documents>/SQLite/inventory.db`, plus `-wal` and `-shm` sidecars. `expo-sqlite`'s `defaultDatabaseDirectory` is `documentDirectory/SQLite` (`node_modules/expo-sqlite/ios/SQLiteModule.swift:24-29`, `src/pathUtils.ts:9`). The name `inventory.db` comes from `src/db/expoDatabase.ts:63`.
- State: `journal_mode = WAL` (persistent in the file header), `PRAGMA user_version = 7` (= `MIGRATIONS.length`, `src/db/migrations.ts:264-265`). `foreign_keys` is a per-connection setting and must be turned on at every open (`expoDatabase.ts:74-75`).
- Native: open the same path with GRDB, enable foreign keys (GRDB's default `foreignKeysEnabled = true`), keep WAL, run the user_version runner (§13.5). Do **not** move the file.

**Keychain (expo-secure-store)**
- Item class `kSecClassGenericPassword`.
- `kSecAttrService = "app:no-auth"`.
- `kSecAttrAccount` **and** `kSecAttrGeneric` = `Data(key.utf8)`. Data, not String.
- `kSecAttrAccessible = kSecAttrAccessibleWhenUnlocked`.
- No access group, so the default group `<TeamID>.com.wystudio.inventory` applies. The app has no entitlements: `ios/Inventory/Inventory.entitlements` is an empty dict.
- Sources: `node_modules/expo-secure-store/ios/SecureStoreModule.swift:69-84,89-99,172-190`; `SecureStoreOptions.swift` (default `.whenUnlocked`); `app.json:47-51` (`faceIDPermission: false`, so `requireAuthentication` is never used).
- **Read order:** expo's `get()` probes service `app:no-auth`, then `app:auth`, then legacy `app` with no suffix (`SecureStoreModule.swift:69-84`). The canonical native recipe (`02-device-storage-migration.md` §4.3, owner) reads `app:no-auth`, then `app`, and skips `app:auth`: no call site ever passed `requireAuthentication`, so such items cannot exist, and skipping the probe rules out a biometric prompt. Each lookup uses `kSecMatchLimitOne` + `kSecReturnData`. `errSecItemNotFound` means "try the next one". **Any other status throws** (`:159-169`), for example `errSecInteractionNotAllowed` while the device is locked, because the items are `WhenUnlocked`. The bytes are decoded as UTF-8, and invalid UTF-8 reads as `nil` (`:75`). The JS callers turn a throw into "no session" or "no account" (`session.ts:26-28`, `identity.ts:54-61`).
- **Write MUST match `set()`** (`:89-125`): `SecItemAdd` with service `app:no-auth`, `kSecValueData` = UTF-8 bytes and `kSecAttrAccessible = WhenUnlocked`. On `errSecSuccess`, also `SecItemDelete` the legacy `app` item and the `app:auth` item. On `errSecDuplicateItem`, `SecItemUpdate` only `kSecValueData` on the `app:no-auth` item, leaving its accessibility unchanged. Any other status throws.
- **Delete MUST match** (`:43-51`): `SecItemDelete` on all three services (`app`, `app:auth`, `app:no-auth`). Statuses are ignored, so it never fails.
- Keys that are empty or whitespace-only are rejected (`:213-219`). None of the app's keys are.
- Keys:
  - `household.session.v1`: a JSON object `{origin, token, deviceId, deviceName, householdName}`, all strings, written as compact `JSON.stringify` output in that key order (`session.ts:5,31-33`). The reader accepts any key order, requires string `origin`/`token`/`deviceId`, and defaults `deviceName` to `'This phone'` and `householdName` to `'Home'` (`session.ts:12-25`). An empty string or invalid JSON means no session. Native should write the same five string fields (`JSONEncoder` key order does not matter to either reader), so an RN TestFlight build installed over the native one still reads it.
  - `sync.accountSecret.v1`: the 26-character base32 recovery code (`identity.ts:30,82,106`).
- Native: read and write the **same items with the same attributes**. No migration is needed, and the native app **MUST** be signed by the same Apple Team for the access group to match.

**AsyncStorage**
- The app's default import is the *legacy v2* store: async-storage 3.1.1 `src/index.tsx` has `export default getLegacyStorage()`.
- File: `<Application Support>/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json` (`apple/legacy_storage/RNCAsyncStorage.mm:17,129-150,538-540`).
- Format: a JSON object, key to string value. A value of 1024 UTF-16 units or fewer is stored **inline** (`RCTInlineValueThreshold`, `:21,633-641`). A longer value has JSON `null` in the manifest, and its text lives in a sibling file named the **lowercase hex MD5 of the key** (`:507-511,598-618,633-649`).
- Older locations that RN migrates on init: `<Documents>/RCTAsyncLocalStorage_V1`, `<Documents>/RNCAsyncLocalStorage_V1`, `<Documents>/RCTAsyncLocalStorage` (`:17-19,445-458`). When two exist, RN keeps the one whose manifest was modified most recently, not the first in a fixed order (`:332-362,374-410`). These paths cannot hold this app's data, because it shipped async-storage v3 from its first commit (`02-device-storage-migration.md` §5). Only the `Documents/RCTAsyncLocalStorage_V1` fallback is worth keeping.
- The directory is excluded from iCloud backup (`:527-536`).
- Native: a one-time import into `UserDefaults` (§3.3).

**Photos**
- `<Documents>/item-photos/<photoId>.webp` and `<photoId>-thumb.webp` (`src/services/capture/imageStore.ts:24-53`).
- **DB rows hold absolute `file://` URIs** (`imageStore.ts:76-87`), and those include the app container path. Apple does not guarantee that path stays the same across updates or restores.
- Native: decided in `02-device-storage-migration.md` §3.3. Every read goes through `PhotoPathResolver`, which resolves by file name under the current `Documents/item-photos/` (or `Caches/household-photos/`). Native **writes keep the same shape**: an absolute `file://` URI in the current container. **Do not** introduce a relative format, because backups are also restored by the RN Android app and by RN TestFlight builds. Rewriting stale rows to the current-container URI ("self-heal", same shape) is allowed but optional; it is open as 02 Q4. *(Consistency pass: this bullet previously said 02 forbids rewriting rows; it does not.)*

**Disposable caches**
- `<Caches>/household-photos/` (`src/services/household/photoCache.ts:19`) and `<Caches>/label-*.png` (`src/ui/container/labelImage.ts:46`) can be ignored.

**AsyncStorage keys in use**

| Key | Value shape | Writer / reader |
|---|---|---|
| `onboarding.completed.v1` | `'true'` or absent | `src/services/onboarding.ts:3,20-30` |
| `household.importOffer.v1` | JSON `{"spaces":number,"items":number}` | `src/services/household/importOffer.ts:5` |
| `household.joinedBefore.v1` | `'true'` | `importOffer.ts:6,45-51` |
| `sync.lastBackupAt.v1` | decimal ms epoch as a string | `src/services/sync/backup.ts:12,29-46` |
| `places.recent.v1` | JSON `string[]` of container ids, at most 6 | `src/services/places/recentPlaces.ts:5,8` |
| `categories.recent.v1` | JSON `string[]`, at most 20; may exceed 1024 chars, so the file case applies | `src/ui/categoryMemory.ts:3-4` |
| `notice.unpaired.dismissed.v1` | `'1'` | `src/ui/home/unpairedNotice.ts:4,36` |

### 3.2 Order and gating

```
Step 0  process start (synchronous, cheap, no disk/keychain I/O):
        AppConfig.load(Bundle.main); Telemetry.install(sink); AppContainer.live()
Step 1  first frame: launch screen → RootView shows BootView (phase = .booting)
Step 2  RootView.task (once per process):
        2a  LegacyImport.runIfNeeded()            // AsyncStorage → UserDefaults (§3.3, owner 02 §5.4); synchronous and cheap;
                                                  // must finish before ANY UserDefaults read (onboarding.load, sync lastBackupAt, …)
        2b  async let db  = database.open()       // GRDB open + user_version migrate
            async let hh  = household.load()      // keychain read (§3.1)
            async let ob  = onboarding.load()     // UserDefaults "onboarding.completed.v1" == "true"
            Task { await sync.loadAccount() }     // not gating; only if config.syncEndpoint != nil
Step 3  RootView.body:
        if case .failed = database.state            → BootFailedView(retry: database.retry)
        else if database.isLoading || onboarding.status == .loading || !household.ready → BootView
        else if onboarding.status == .completed     → MainShell (tabs + routes)
        else                                         → OnboardingFlow (full-screen root, not dismissible)
        + overlay window (toast + revoked layer) installed once the gate passes (§7.7)
Step 4  NOT tied to the gate (in RN, Connection and Sync sit ABOVE RootNavigator, `_layout.tsx:231-242`):
        connection subscription starts as soon as household.session != nil (that is, when the session load
        resolves, which is also part of the gate); sync first pass as soon as DB ready AND account loaded,
        even while onboarding is pending or the DB gate is still on BootView for another reason;
        scenePhase routing is active from launch (§6). Start these from the composition root, not from MainShell.
```

**MUST:**
- The DB error check takes precedence over loading.
- Fonts and the sync account never gate.
- Nothing blocks the first frame.

**Failure handling**

| Failure | RN behavior | Native |
|---|---|---|
| DB open or migrate throws | Error screen with retry; event `database_open_failed{durationMs}` | Same. `retry()` **closes the previous `DatabaseQueue` if any**, sets `.loading`, and reopens (RECOMMEND closing; RN reuses expo-sqlite's cached connection, §2.4). |
| Keychain read fails | Treated as no session, so the phone looks unpaired. The sync account is treated as absent, so status stays `off` | MUST keep "never crash". The items are `WhenUnlocked`, so reads fail with `errSecInteractionNotAllowed` whenever the device is locked. The app has no background launch reasons, and prewarming stops before `UIApplicationMain`, so `App.init` and `.task` do not run then. In practice this only matters if background modes are added later. RECOMMEND treating that status as *not yet known*: wait for `UIApplication.protectedDataDidBecomeAvailableNotification` before setting `ready`, rather than running a paired phone as local-only. See §15 Q7. |
| Onboarding flag unreadable | `pending`, so onboarding shows again | Same (`UserDefaults` does not fail in practice). |
| Legacy import fails (manifest unreadable) | n/a | Do not set the marker. Fall through to defaults, which matches RN's failure behavior, and retry on the next launch. |

### 3.3 First-launch legacy adoption (AsyncStorage → UserDefaults)

**Owner: `02-device-storage-migration.md` §5.4** (reader `LegacyAsyncStorageReader`, importer `LegacyImport`). That spec is authoritative. This is a summary of what boot depends on, kept consistent with it:

1. If `UserDefaults.standard.integer(forKey: "native.legacyImport.v1") >= 1`, return. The marker is an **Int** (`1` = done), not a Bool.
2. Manifest: `ApplicationSupport/<bundleId>/RCTAsyncLocalStorage_V1/manifest.json` (fallback `Documents/RCTAsyncLocalStorage_V1/manifest.json` only, see §3.1).
   - Missing: fresh install, or the RN app never wrote anything. Import nothing and set the marker.
   - Exists but cannot be read (I/O error, for example data protection while locked) or is not UTF-8: **do not set the marker**. Use defaults this launch (RN would too, `RNCAsyncStorage.mm:540-552`) and retry next launch.
   - Exists but is not a JSON object: treat it as empty and set the marker. RN does the same, logs, and starts a new manifest (`:557-562`).
3. For each entry: a string value is used as is. A `null` value means reading `<manifestDir>/<lowercase hex MD5 of the key's UTF-8 bytes>` (`RCTMD5Hash`, `node_modules/react-native/React/Base/RCTUtils.mm:256-268`; `Insecure.MD5` in CryptoKit) as UTF-8. If the file is missing, the key is absent.
4. Copy **only the 7 known keys** (§3.1 table) as **raw strings** under the **same key names**, and never overwrite a key that `UserDefaults` already has. Storing raw strings keeps every RN parse rule and test portable one-to-one.
5. Remove `ExpoSystemUI.backgroundColor` from the standard domain (02 §6), then set the marker. **Leave the legacy directory untouched**: an RN TestFlight build installed over the native one would still read it.
6. Keychain and SQLite need no import (§3.1). Photo URIs go through `PhotoPathResolver` (02 §3.3).

---

## 4. Providers → native app models

All models are `@MainActor @Observable final class`, created once in the composition root and injected with `.environment(model)`. I/O runs in Sendable services or actors (§13.4).

### 4.1 `DatabaseModel` (from `DatabaseProvider`)

**RN state**
- `DatabaseState = loading | ready(repos) | error(message)` (`DatabaseProvider.tsx:17-20`).
- `revision: number`, starting at 0, in its own context so that writers do not re-render (`:30-34,38`).
- `attempt: number` (`:39`).

**API**
- `state`.
- `invalidate()` increments `revision` (`:68`).
- `retry()` (`:69-72`).
- `useRevision()` (`:96-98`).
- `useRepositories()` (`:108-120`).

**Who calls `invalidate()`:**
- every screen after a write (20 files; e.g. `src/hooks/useMove.ts:93,108`);
- `ConnectionProvider` on recovery and resume (`:118,157,177`);
- `SyncProvider` after a restore (`:198,203`);
- the revoked layer after leaving (`ConnectionBanner.tsx:72-81`);
- the join flow after pairing (`src/ui/household/JoinForm.tsx:122`);
- leaving the household (`app/household.tsx:228`).

**Native shape**

```swift
enum DatabaseState { case loading, ready(LocalRepositories), failed }   // message kept only for logs
@MainActor @Observable final class DatabaseModel {
  private(set) var state: DatabaseState = .loading
  private(set) var revision = 0                  // starts at 0; &+= 1 per invalidate()
  func open() async                              // telemetry: database_ready / database_open_failed {durationMs}
  func retry() async                             // close previous DatabaseQueue → .loading → open()
  func invalidate()                              // revision &+= 1
}
```

**Repository composition** (`useRepositories`, `DatabaseProvider.tsx:108-120`):
- Unpaired: the repositories are the local SQLite repositories.
- Paired (`household.session != nil`): they are `withLocalShadow(httpRepos, localRepos)` (`src/services/household/shadow.ts:11`). Every successful household write is mirrored into local SQLite, and mirror failures only log `household_shadow_failed` (sent as an *event*, `shadow.ts:102-110`).
- It is invalid before the DB is ready, and throws (`:116-118`).
- **Changing the session does not re-run queries by itself.** Callers invalidate explicitly after `pair` or `disconnect`. Native: expose a computed `repositories` on a small `RepositoryProvider` that combines `DatabaseModel` and `HouseholdModel`. Keep the explicit invalidate at call sites.

### 4.2 `HouseholdModel` (lifecycle side of `HouseholdProvider`)

**State:** `session: HouseholdSession?`, `ready: Bool` (false until the keychain read returns), and `repos` = HTTP repositories when a session exists (`HouseholdProvider.tsx:20-26,31-32,48`).

**Load** (`:34-46`) reads `household.session.v1`. Validation (`session.ts:12-25`):
- `origin`, `token` and `deviceId` must be strings, otherwise the session is `nil`;
- `deviceName` defaults to `'This phone'` and `householdName` to `'Home'`.

**`pair(bootstrapSecret, deviceName)`** (`:50-54`):
1. `pairWithHousehold`, which POSTs to `${appConfig.householdOrigin with trailing "/" stripped}/v1/pair` (`client.ts:77-101`). The response needs string `token`, `deviceId` and `origin`, otherwise `HouseholdHttpError(500, 'invalid_response')` (`:87-93`). The session keeps the **server-returned `origin`** with trailing `/` stripped, `deviceName.trim()`, and `householdName`, which defaults to `'Home'` (`:94-100`);
2. save to the keychain (a keychain failure throws, `session.ts:31-33`);
3. set the session.

It throws to the caller on failure. **From then on, every household request (reads, writes, the health ping) goes to `session.origin`, not to `appConfig.householdOrigin`.** The config value is only the pairing target and the display fallback (§8.1).

**`disconnect()`** (`:56-59`): delete the keychain item (a missing item is fine, `session.ts:35-41`), then set the session to `nil`. Callers then `invalidate()`.

Wire details of pairing and the HTTP repositories belong to the household area.

### 4.3 `ConnectionModel` (from `ConnectionProvider`)

**State enum** (`ConnectionProvider.tsx:20-27`): `local | online | unsure | offline | revoked`.
- `state = session == nil ? .local : tracked.state` (`:74`).
- `sessionKey = "\(origin)|\(token)"` (`:60`). Any change of session key resets the tracked state to `online` (`:63-72`), cancels timers and restarts the subscription.

**Constants**

| Name | Value | Source |
|---|---|---|
| `HEALTH_PING_MS` | 10 000 | `ConnectionProvider.tsx:40` |
| `HEALTH_TIMEOUT_MS` | 5 000 | `:41` |
| `RESUME_REFRESH_MS` | 5 000 | `:43` (also the minimum gap between recovery refreshes) |
| offline delay | `delay.reconnect` = 2 500 | `src/ui/motion.ts:30`, `ConnectionProvider.tsx:124-127` |

**Input.** Every household request reports a `Reachability` value of `ok`, `offline` or `unauthorized` through `onHouseholdReachability` (`src/services/household/client.ts:21-59,176,180`).
- `offline`: a network error or timeout, or HTTP 502 or 520–530 (Cloudflare reporting the home box down).
- `unauthorized`: HTTP 401 **on a request that carried a token**.
- `ok`: any other HTTP answer, including 4xx and 5xx.

**State machine.** This is the subscription body at `:81-134`. `current` is a subscription-local mirror; `set(next)` is ignored if `current == .revoked` or `current == next` (`:90-96`).

| Current | Input | Next | Side effects |
|---|---|---|---|
| any paired | session key changes | `online` | Reset; cancel the offline timer; `lastRecovery = 0`; call `markJoinedBefore()` (`:83`) if the new key is non-nil. |
| `revoked` | anything | `revoked` | Sticky until the session changes (`:91`). |
| `online` | `offline` | `unsure` | Start a 2.5 s timer (`:122-127`). |
| `unsure` | `offline` | `unsure` | Ignored, the timer is already running (`:122`). |
| `unsure` | timer fires | `offline` | `strings.connection.reconnecting` is announced on **every** transition into `offline` (an effect keyed on `offline`, both platforms, not queued, `:160,165-167`); the ping loop starts if the app is active. |
| `offline` | `offline` | `offline` | Ignored. |
| `unsure`/`offline` | `ok` | `online` | Cancel the timer. If `now - lastRecovery >= 5000` then `lastRecovery = now; invalidate()` (`:108-120`). `lastRecovery` starts at 0, so the first recovery always refreshes. |
| `online` | `ok` | `online` | Cancel the timer; nothing else. |
| `revoked` | `ok` | `revoked` | Cancel the timer. `set('online')` is ignored, so `recovering && current == online` is false and nothing is invalidated (`:113-116`). |
| `unsure`/`offline`/`revoked` | `offline` | unchanged | Ignored (`:122`: `current !== 'online' \|\| offlineTimer`). |
| any non-revoked | `unauthorized` | `revoked` | Cancel the timer (`:103-107`). |

**Ping loop** (`:136-142,169-173`). It runs only while `state == .offline && scenePhase == .active`:
- the first ping is 10 s after both conditions hold (an interval, not immediate);
- each ping is `GET {origin}/v1/health`, with no token, `Accept: application/json` and a 5 s timeout (`client.ts:162-169`);
- the result is ignored, because the request reports its own reachability;
- every ping that fails with a network error (not a timeout) also logs `household_fetch_failed` (`client.ts:184-186`), so roughly one error event every 10 s while offline. Timeouts log nothing.

**`retry()`** (`:175-178`) pings immediately and calls `invalidate()`. It is used by the connection banner's button.

**Resume refresh** (`:144-158`). On every transition to `active` while paired:
- if `now - lastResume < 5000`, skip;
- `first = (lastResume == 0)`, then `lastResume = now`;
- if not `first`, `invalidate()`.

`lastResume` lives for the provider's lifetime and is *not* reset on a session change. The effect runs whenever `appState` or `sessionKey` changes (`:158`), and only proceeds when `appState == 'active' && sessionKey != nil`. Consequences the native port must reproduce:
- At launch the session is still loading (`sessionKey == nil`) when the app first becomes active. The **first evaluation that passes the guard is usually the session load resolving**, not a scene transition. It only arms `lastResume`.
- A phone that was unpaired at launch and pairs later: pairing is the first evaluation, so no invalidate.
- Leaving and re-joining more than 5 s after the last evaluation: the session-key change counts as a resume and invalidates.
- Local-only phones never get a resume refresh.

Natively: `ConnectionModel` keeps `lastResume` and evaluates the same rule on `scenePhase == .active` **and** on every session change while active.

**Consumers:**
- the connection banner: shown only for `offline` (`ConnectionBanner.tsx:25-41`);
- the revoked layer (§7.6);
- `useDirtyGuard` disables discard prompts while revoked (`src/hooks/useDirtyGuard.ts:32-34`);
- the Home error explanation: `revoked`, or offline while not `online` (`app/(tabs)/index.tsx:76-78`);
- Home's subtitle: `strings.connection.sharedReconnecting` when paired and `offline`, otherwise `strings.connection.shared` or `strings.connection.local` (`app/(tabs)/index.tsx:407,440-445`);
- Household screen texts (`app/household.tsx:307-309,379-385`);
- Scan and Add sheet guards (`app/(tabs)/scan.tsx:162`, `app/item/new.tsx:330`).

**Native shape**

```swift
enum ConnectionState: Equatable { case local, online, unsure, offline, revoked }
@MainActor @Observable final class ConnectionModel {
  private(set) var state: ConnectionState = .local
  init(household: HouseholdModel, database: DatabaseModel, client: HouseholdClient,
       reachability: ReachabilityHub, clock: any Clock<Duration> = ContinuousClock())
  func sessionChanged(_ session: HouseholdSession?)      // restart subscription
  func scenePhaseChanged(_ phase: ScenePhase)            // resume refresh + ping loop gating
  func retry()
}
```

Timers are `Task`s using an injected clock, so tests can drive time. RECOMMEND port tests for every row of the table above (none exist in RN).

### 4.4 `SyncModel` (lifecycle side of `SyncProvider`)

**Status enum** (`SyncProvider.tsx:36-41`), also consumed by `src/ui/household/status.ts`:

```
unavailable | off | idle(account, lastBackupAt: Int64?) | working(account) | error(account?, reason: SyncFailureReason)
```

**Initial value:** `syncEndpoint != nil ? .off : .unavailable` (`:60-62`). If an account exists, it becomes `.idle(account, lastBackupAt())` after the load (`:74-88`). Until then a phone with an account briefly reports `off`. `lastBackupAt` comes from `UserDefaults` `sync.lastBackupAt.v1` (`backup.ts:29-37`). Parse with JS `Number` semantics: an empty or absent value gives `nil`; otherwise `Number(stored)` must be finite, else `nil`. JS `Number` trims whitespace and accepts decimals and exponents, so parse as `Double` after trimming, check finiteness, then convert. The writer stores `String(capturedAt)`, an integer ms epoch from the Worker (`worker/src/index.ts:319,346`), so `Int64` fits.

**Pass** (`runPass`, `:97-110`):
1. Guard on local repos ready, an account, and no pass already running (`running` ref, `:65,98`).
2. `syncPhotos(localDb, client)`.
3. `maybeBackup(localDb, client)`, which backs up only if `lastBackupAt == nil || now - last >= 15 min` (`MIN_BACKUP_INTERVAL_MS`, `backup.ts:22,98-106`).
4. Set `status = idle(account, lastBackupAt())`.

**Automatic failures are silent.** The result of `maybeBackup` is ignored, and the status returns to `idle` with an unchanged `lastBackupAt`. Errors thrown by the pass are not caught: an unhandled `void` promise, and the status is left as it was.

**A completed automatic pass always overwrites the status with `idle`** (`:104-106`). That includes an `error` left by a failed `backupNow`/`enable` and a `working` from a manual backup still in flight. So a backup-failed banner disappears on the next foreground.

Sync always uses the **local** SQLite, even when paired.

**Triggers** (`:114-123`):
- once immediately whenever the pass closure changes, i.e. when the repos, client or account change: DB becoming ready, an account loaded or created;
- on every AppState transition to `active`.

**User actions:**
- **`enable()`** (`:125-144`): `createAccount()`, then `working`, then `runBackup`. On failure the status is `error(account, reason)` and **the account is kept**; on success, `idle(capturedAt)`. Returns `not_configured` if the DB is not ready. It does **not** check `syncEndpoint`; the screen only offers it when configured. If `createAccount()` throws (keychain write failed), the throw reaches the caller (`app/backup.tsx:133-137` logs `backup_enable_failed`) and the status is unchanged.
- **`backupNow()`** (`:146-157`): silently returns unless DB, client and account all exist. Then `working`, `runBackup`, and `error` or `idle`. It does **not** take the `running` guard, so an automatic pass started by foregrounding can run at the same time. Whichever finishes last sets the status. The screen has its own double-tap guard (`app/backup.tsx:289-330`).
- **`restoreFromCode(code)`** (`:159-212`):
  - Returns `not_configured` if the DB is not ready.
  - `importAccount`: `malformed` stays `malformed`; `unavailable` (keychain write failed) is reported as `not_configured`.
  - The running flag is set for the whole restore, which blocks *new* automatic passes (`:173-177,207-208`). It is set **without checking** whether a pass is already running. An in-flight pass is not awaited, and its `finally` clears the flag early (`:107-109`).
  - On failure: `forgetAccount()`, then `off`, and the reason is returned.
  - On success: `invalidate()`, then `syncPhotos` (errors swallowed), then `invalidate()`, then `idle(adopted, lastBackupAt())`. A restore does not write `lastBackupAt`, so the next pass's `maybeBackup` backs up immediately if no value is stored.
- **`refresh()`** (`:214-217`): if an account exists, sets `idle(account, lastBackupAt())` unconditionally, clearing `error`/`working`; otherwise a no-op. **No caller uses it** (grep), so native may omit it.

**Native:** a `SyncCoordinator` actor owns the "one at a time" guard (set the flag *before* the first `await`). `SyncModel` mirrors the status on the main actor.

RECOMMEND that `enable()` and `backupNow()` also hold the guard, and that `restoreFromCode` wait for an in-flight pass before starting. In RN, adopting the new account immediately triggers an automatic pass that can run a second backup at the same time as `enable`'s first one (`:129` with `:114-123`; `maybeBackup` sees no `lastBackupAt`). See §15 Q13. Backup, photo sync and wire details belong to the sync area (`03-sync-account.md`).

### 4.5 `OnboardingModel` (from `OnboardingProvider`)

- `status: loading | pending | completed` (`OnboardingProvider.tsx:6`).
- Load: `completed` iff `UserDefaults` `onboarding.completed.v1 == "true"` (`onboarding.ts:10-18`).
- `complete()`: set `completed` **first**, then persist `'true'` (`:33-36`, `onboarding.ts:20-30`). Persist errors are ignored.
- `replay()`: set `pending` first, then remove the key (`:38-41`).
- The root view swaps between onboarding and the main shell purely from `status`. There is no navigation call.

Telemetry `onboarding_finished{outcome: completed|skipped, step}` is sent by the onboarding screen (`app/onboarding.tsx:52`).

### 4.6 `ToastCenter` (from `ToastProvider`, app-wide shell)

Rules (`src/providers/ToastProvider.tsx`):

**Showing and replacing**
- One toast at a time. `show(options)` returns the id `"toast-N"`, where N is a process-global counter pre-incremented from 0, so the first id is `toast-1` (`:67,184-187`). `tone` defaults to `info`. A new toast replaces the current one, even one mid-exit, whose exit is cancelled (`:158,210`).
- **Error hold.** If the current toast is an error that has been shown for less than `ERROR_HOLD_MS = 1500` (`:65`), the newcomer waits (`:194-208`):
  - a single pending slot holds the waiting toast, and the newest wins, **except** that a pending error is never replaced by an info toast;
  - one timer fires at `1500 - heldFor` and presents whatever is pending.

**Lifetime**
- `options.duration`, or 9 000 ms with an action, or 5 000 ms without (`delay.toast`, `delay.toastWithAction`, `src/ui/motion.ts:33-34`).
- Doubled while VoiceOver is running (`:95-109,164-165`).

**Announcement** (`:170-177`)
- With an action, the spoken text is `"\(message), \(strings.a11y.availableAction(label))"`; otherwise just the message.
- On iOS it is queued, so it does not interrupt current speech.

**Touch and dismissal**
- `pause()` on touch-down freezes the remaining time, but only if the life timer is running (`:224-232`).
- `resume()` on touch-up or cancel restarts with `max(remaining, delay.toast / 2 = 2500)`, but only if paused (`:234-239`). The VoiceOver doubling is **not** reapplied on resume.
- `dismiss(id)` clears a matching pending toast, then leaves (`:216-222`).
- Leaving runs an exit animation; the toast is removed after `duration.toastOut = 120` ms (`:136-145`, `motion.ts:14`).

**Bottom chrome**
- `registerChrome(height)`: the focused screen's tab bar or bottom bar registers its height, and the most recent registration wins (`:241-250,286-295`).
- The toast floats `12` pt above it, or above the home indicator if nothing is registered (`src/ui/components/Toast.tsx:18,29`).

**Card**
- Max width 480 (`Toast.tsx:263`).
- A downward swipe of more than 24 pt dismisses (`:20,104-111`).
- The action runs at most once, then dismisses the toast (`:135-140`). It is disabled and hidden from VoiceOver while the toast is leaving (`:134,204-214`). It is labelled `action.accessibilityLabel ?? action.label`.
- The close button is labelled `strings.a11y.dismissToast` (`:147`).
- An error toast has the alert role and a leading signal bar (`:158,173`).

**Native:** `ToastCenter` (`@Observable`) plus a `ToastHost` view rendered in a pass-through overlay `UIWindow` (§7.7). Announce with `AccessibilityNotification.Announcement`, using an `AttributedString` with `accessibilitySpeechQueueAnnouncement = true` for the queued variant. Use `@Environment(\.accessibilityVoiceOverEnabled)` or `UIAccessibility.isVoiceOverRunning` for the doubling.

### 4.7 `FontProvider` (dropped)

It loads 5 weights of Atkinson Hyperlegible Next (`FontProvider.tsx:21-27,46-59`) and tracks iOS Bold Text (`:61-74`), because the system applies Bold Text to its own font but not to a custom one (`src/ui/fontContext.ts:6`).

**Native uses system fonts** (a user decision): no provider, no `fonts_failed` event, and Bold Text and Dynamic Type come for free. `src/ui/__tests__/typography.test.tsx` is not ported (§14).

### 4.8 `DropZoneModel` (tabs scope; owned by the drop-zone area)

- One shared read of `repos.items.listUnsorted()` with query key `'drop-zone'` (`src/providers/DropZoneProvider.tsx:31-36`).
- Exposes `items`, `count`, `loading` (only true when there is no data yet), `cause`, `refreshFailed`, `reading` and `reload` (`:38-49`).
- It uses the same reactivity mechanism as §5, scoped to the tab shell.

---

## 5. App-wide reactivity: `useInventoryQuery` + revision

`src/hooks/useInventoryQuery.ts` is the main read mechanism: **30 call sites in 19 files** (18 screens/components plus `DropZoneProvider`). There are two other readers of `revision`:
- `useSearch` (Home search) applies the same focus-gated `seenRevision` rule, plus a nonce bumped on focus and retry, and its own 200 ms debounce (`src/hooks/useSearch.ts:59-71`).
- `app/c/[token].tsx` is deliberately a one-shot read that ends in navigation, so it ignores revision and focus (`:40-43`).

Exact semantics of `useInventoryQuery`:

**Inputs**
- `run: () async throws -> T`.
- `key: String`, the identity of the query's inputs (e.g. `space:${id}`).

**State**
- `localRevision = 0`.
- `seenRevision`, initialised to the global `revision` at mount.
- `settled = {token: -1, key, data: nil, failed: false, cause: nil}` (`:55-63`).

**Rules**
1. **Focus gating** (`:65-69`). While the screen is focused, `seenRevision` follows the global revision. A write therefore refetches only the screen in front. Background screens catch up when they are focused again.
2. **Request identity** (`:71,130-138`): `requestToken = FNV-1a-32("\(key)|\(seenRevision)|\(localRevision)")`. Natively, use a struct `QueryTrigger(key, seenRevision, localRevision): Hashable`; no hashing is needed.
3. **Read** (`:82-106`). Whenever the trigger changes, run the query. A result for a superseded trigger is ignored (cancellation).
   - Success: `settled = {token, key, data: result, failed: false}`.
   - Failure: `settled = {token, key, data: previous.key == key ? previous.data : nil, failed: true, cause}`. A blip never turns a list into an error page, but data from a different key is not kept.
4. **Focus** (`:109-113`): every time the screen gains focus, including the first, `localRevision += 1`.
5. **Reload** (`:115`): `localRevision += 1`.
6. **Outputs** (`:117-126`):
   - `data = settled.data`. This is **not filtered by key**: while a new key loads, the previous key's data remains visible.
   - `loading = settled.token != requestToken`.
   - `cause = (current && failed) ? settled.cause : nil`.
   - `refreshFailed = current && failed && settled.data != nil`.

**Quirks not to copy:**
- On mount RN issues two reads. The first, at `localRevision 0`, is superseded by the focus bump.
- Regaining focus after a write likewise issues two reads in a row.

Native should issue exactly one read per trigger change and coalesce focus and revision catch-up into one.

**Native design (RECOMMEND)**

```swift
@MainActor @Observable final class InventoryQuery<Value: Sendable> {
  private(set) var data: Value?; private(set) var isLoading = true
  private(set) var cause: (any Error)?; var refreshFailed: Bool { cause != nil && data != nil }
  func reload()
}
// View side: .inventoryQuery(query, key: "space:\(id)") { repos in try await repos.spaces.get(id) }
// implemented with .task(id: QueryTrigger(key, seenRevision, localRevision)) — .task(id:) cancels the stale read.
```

"Focused" means the screen is the top of its navigation stack, has no sheet or full-screen cover over it, and its tab is selected. SwiftUI has no `isFocused` for screens, so the navigation area must provide a `ScreenFocus` environment value (§15 Q12).

Keep the revision mechanism rather than GRDB `ValueObservation`. When paired, reads are HTTP, and one mechanism must serve both modes.

A `null` result from a read ("gone") is data, not an error. JS `describeError(null)` maps it to `gone` (§10).

**`cause` semantics that the screens rely on.** The hook returns `cause: null` whenever the current read did not fail (`:122`). Screens therefore never pass the hook's `cause` straight to `ErrorState` for the gone case. They branch on truthiness (`if (query.cause) … else if (loading) … else <ErrorState cause={null} …/>`, e.g. `app/item/[id]/index.tsx:274-292`) and pass an explicit `null` to get "gone". Natively, `InventoryQuery.cause == nil` means "no error", and the gone branch passes `QueryCause.gone` explicitly. Never feed a `nil` query cause into `describeError`, because native `nil` means JS `undefined`, which is `local`.

---

## 6. Foreground / background handling

**Every RN lifecycle listener**

| Listener | Source | Fires on | Triggers |
|---|---|---|---|
| `AppState 'change' → 'active'` | `SyncProvider.tsx:118-120` | every transition to `active`, including `inactive → active` (Control Center, app switcher) | `runPass()`: photo sync, then backup if more than 15 min since the last one. No-op if a pass is running, there is no account, or the DB is not ready. |
| `AppState 'change'` (all values) | `ConnectionProvider.tsx:144-147` | every change | updates `appState`, which drives the resume refresh (`:149-158`) and the ping loop (`:169-173`) |
| `AccessibilityInfo 'boldTextChanged'` | `FontProvider.tsx:69` | setting change | re-styles text. **Dropped** natively. |
| `AccessibilityInfo 'screenReaderChanged'` | `ToastProvider.tsx:102-104` | VoiceOver toggled | toast duration doubling |
| `AccessibilityInfo 'reduceMotionChanged'` | `src/ui/motion.ts:62-69` | setting change | all motion lengths become 0 |
| `useFocusEffect` / `useIsFocused` | `useInventoryQuery.ts:54,109-113`; `useNow.ts:11-25`; `useBottomChrome` (`ToastProvider.tsx:286-295`) | screen focus | query refresh; clocks tick only while focused; toast chrome height |

**Nothing happens on background.** There are no flushes, no background tasks, and no timers kept alive: the ping loop stops when the app is not active.

`inactive → active` also happens when a system alert closes, for example the camera permission prompt or a Face ID sheet. Each one therefore triggers a sync pass and a (throttled) resume refresh, in RN and natively alike. That is parity, not a bug.

Also live in RN, and free natively: `useColorScheme` re-themes on an appearance change (`src/ui/theme.ts:114`), and `Keyboard` listeners in `useKeyboardInset` (`src/hooks/useKeyboardInset.ts:36-37`).

**Native mapping**
- `@Environment(\.scenePhase)` at the `App` level goes to `AppLifecycle.scenePhaseChanged(_:)`. On `.active` it calls `sync.onActive()` and `connection.onActive()`. On anything else it calls `connection.onInactive()`, which stops pinging.
- Accessibility state comes from the environment: `accessibilityReduceMotion`, `accessibilityVoiceOverEnabled`.

RECOMMEND `UIApplicationSupportsMultipleScenes = NO` to match the RN app's single window, so that the App-level `scenePhase` equals the app's state.

`BGTaskScheduler` backups would be new behavior and are out of scope unless requested (§15 Q15).

---

## 7. App shell components (information architecture and behavior)

### 7.1 `BootView` (from `BootScreen`)
- A centered brand mark, the household mark from `src/ui/components/Mark.tsx`: a dark rounded box with a yellow tape strip, decorative and hidden from accessibility.
- Under it, the caption `strings.boot.opening`, shown only after 400 ms in a reserved line.
- No VoiceOver announcement (RN's live region is Android-only).
- RECOMMEND the launch screen (`UILaunchScreen`) uses the same background as `BootView` to avoid a flash.

### 7.2 `BootFailedView` (gate error)
- Title `strings.boot.failedTitle`, body `strings.boot.failedBody`, and a refresh icon.
- One button, `strings.common.tryAgain`, which calls `DatabaseModel.retry()`.
- Announce the title to VoiceOver on appear (`ErrorState.tsx:60-62`).
- `ContentUnavailableView` with an action fits.

### 7.3 Generic `ErrorStateView` (used by screens; from `ErrorState`)

**Text precedence** (`ErrorState.tsx:52-57`):
- if a `cause` is given (`cause !== undefined`, so an explicit `null` counts and gives "gone"), or either override is missing, compute `describeError(cause, context, subject)`;
- heading = `title ?? described.title`, body = `body ?? described.body`.

Overrides must come from `strings`, never `Error.message` (`:19-26`).

**Actions:**
- `onRetry`, labelled `strings.common.tryAgain` (`:77-84`);
- an optional secondary button (`:85-92`).

### 7.4 `ScreenFrame` (every screen's frame; `src/ui/components/ScreenFrame.tsx`)

Kinds: `tabRoot | detail | modal | camera` (`:13`).

**Safe-area edges** (`:16-28`):
- `tabRoot`: top, left, right. Tab roots have no navigation bar and draw their own large title in content (`TabRootHeader`, `:76-98`).
- `detail` and `modal`: left, right. They sit under a navigation bar, and the bottom is handled by the bottom bar or the list.
- `camera`: none (full bleed, black background, `:58`).

**Connection banner** (§7.5) at the top, **outside any scroll view** so it cannot scroll away. On by default, off for `camera` (`:36,49,60`).

**Layout:**
- Content is centered with a max width of `CONTENT_MAX_WIDTH = 640` pt, for iPad (`:123-128`, `src/ui/tokens.ts:159`).
- An optional bottom bar slot sits under the content (`:62`).
- `SearchButton` (`:100-114`) is a shared header action, labelled `strings.a11y.searchHousehold` with hint `strings.a11y.searchHint`, that opens Home with the search field focused.

Usage counts (`kind="…"` occurrences, grep): `tabRoot` 4 in 4 files, `detail` 17 in 10 files, `modal` 10 in 7 files, `camera` 2 in 2 files. Several screens render a different frame per state.

**Native:**
- a `ScreenFrame` view or `ViewModifier`;
- the banner via `.safeAreaInset(edge: .top)`;
- the bottom bar via `.safeAreaInset(edge: .bottom)`;
- `.frame(maxWidth: 640)` centered;
- system backgrounds, per the fully native look.

### 7.5 `ConnectionBanner`
- Visible only when `connection.state == .offline` (`ConnectionBanner.tsx:25-41`).
- Warning style, cloud-off icon, message `strings.connection.reconnecting`, action `strings.connection.retry`, which calls `connection.retry()`.
- It does **not** announce itself, because `ConnectionModel` announces once on the transition (`:16-24`).

### 7.6 `RevokedOverlay` (from `RevokedLayer`)

**Shows** when `connection.state == .revoked`. It covers every screen and sheet (`ConnectionBanner.tsx:43-120`).

**On appear:**
- dismiss everything presented and pop to the tab root (`router.dismissAll()` if possible, `:63`);
- announce `strings.revoked.title` (`:64`);
- (Android back blocked, `:66`.)

**Content:** the mark, `strings.revoked.title`, `strings.revoked.body`, then two buttons:
- `strings.revoked.join`: `household.disconnect()`, then `database.invalidate()`, then navigate to the Household screen (`:72-76`).
- `strings.revoked.local`: `household.disconnect()`, then `database.invalidate()` (`:78-81`).

It leaves by itself because the state becomes `.local`. While it is up, the rest of the app is hidden from VoiceOver (accessibility-modal, `Toast.tsx:234-247`).

### 7.7 Overlay window (from `OverlayHost` / `FullWindowOverlay`)

- Toasts and the revoked overlay must render **above SwiftUI sheets and full-screen covers**. Examples: "Moved to …" with Undo staying visible while the move sheet slides away, and the revoked layer covering an open sheet. SwiftUI offers no in-hierarchy way to draw above a presented sheet.
- Native: create a pass-through `UIWindow` on the active `UIWindowScene` at a window level above normal, hosting `ToastHost` and `RevokedOverlay` in a `UIHostingController`.
  - `hitTest` returns `nil` outside the toast card, so touches pass through.
  - While revoked, it captures all touches and sets `accessibilityViewIsModal = true`.
  - Install it once the gate passes. In RN, `OverlayHost` exists only post-gate (`_layout.tsx:216`).

### 7.8 `BottomBar` (a screen's primary actions; `src/ui/components/BottomBar.tsx`)

**Children:** one or two full-width buttons, **secondary first, primary last**. The primary sits on the trailing side, under the thumb (`:11-16`).

**Layout:**
- **Stacking** (`:46`) happens when `stackOnLarge` (default true) && `stacked` && there are more than 1 items. The primary goes **on top** (`column-reverse`, `:106-108`).
  - `stacked = fontScale >= 1.35 || windowWidth < 360` (`src/hooks/useLayoutScale.ts:13-16`, `tokens.ts:178-179`).
  - RN's `fontScale` 1.35 corresponds to `DynamicTypeSize.xxxLarge` (1.353) and above. Native test: `dynamicTypeSize >= .xxxLarge || width < 360`.
- **Side by side** (`:47`): the secondary takes `flex 1` and the primary `flex 1.4` (`:112-114`). Both stretch to the taller one's height (`:82-86`).
  - With `primaryFit` (`:17-24,115-119`), the primary sizes to its label (minimum width 120 pt) and the secondary takes the rest. Used where the primary is "Save" and the secondary is long.

**Spacing:** top 12, sides 16, bottom 12, plus the home-indicator inset **except while the keyboard is visible** (`:60`, `tokens.ts:175`). Gap 12 (`ROW_GAP`). A top separator.

**Toast:** while focused, it registers its height so toasts float above it (`:49,54`).

**Native:** `.safeAreaInset(edge: .bottom)` already follows the keyboard and drops the home-indicator padding, so `useKeyboardInset` (`src/hooks/useKeyboardInset.ts`) is not needed. Use stock buttons. For the toast offset, report the height with `onGeometryChange` to `ToastCenter` while focused.

---

## 8. Configuration

### 8.1 `AppConfig` fields (`src/services/config.ts:14-76`)

| Field | Env var (RN) | Parse rule (exact) | Default | Used by |
|---|---|---|---|---|
| `recognitionEndpoint: String?` | `EXPO_PUBLIC_RECOGNITION_URL` | trim; empty → nil. **No** trailing-slash strip: it is a full URL including the path (`:66`). | nil (feature off) | `recognition.ts:65,88`; Settings "Photo suggestions" (`app/settings.tsx:125-129`); Privacy (`app/privacy.tsx:80`) |
| `recognitionKey: String?` | `EXPO_PUBLIC_RECOGNITION_KEY` | trim; empty → nil (`:67`) | nil (header omitted) | header `x-inventory-key` (`recognition.ts:93`) |
| `recognitionTimeoutMs: Int` | `EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS` | `Number(value ?? 15000)` (`:68`) | 15 000 | `recognition.ts:67,82` |
| `syncEndpoint: String?` | `EXPO_PUBLIC_SYNC_URL` | trim; strip trailing `/+`; empty → nil (`:69`) | nil (`SyncStatus.unavailable`) | `SyncProvider.tsx:61,75`; `sync/client.ts:32`; Privacy (`app/privacy.tsx:56,64`) |
| `syncKey: String?` | `EXPO_PUBLIC_SYNC_KEY` | trim; empty → nil (`:70`) | nil (header omitted) | header `x-inventory-key` (`sync/client.ts:51`) |
| `syncTimeoutMs: Int` | `EXPO_PUBLIC_SYNC_TIMEOUT_MS` | `Number(value ?? 60000)` (`:71`) | 60 000 | `sync/client.ts:34,43` |
| `householdOrigin: String` | `EXPO_PUBLIC_HOUSEHOLD_ORIGIN` | trim; strip trailing `/+`; empty → default (`:72-74`) | `https://inventory.wystudio.be` | pairing target only (`client.ts:78`); once paired, requests use `session.origin` from the pair response (§4.2). Settings shows `serverHost(session?.origin ?? householdOrigin)` (`app/settings.tsx:47`). The Join form shows `serverHost(appConfig.householdOrigin)`, never the session (`src/ui/household/JoinForm.tsx:200`) |
| `environment` | `EXPO_PUBLIC_ENV` | `'production'` or `'preview'` exactly, else `'development'` (`:59-63`) | `development` | Settings "Technical details" shows the raw value (`app/settings.tsx:119`) |

**Timeout edge case.** `??` only catches *undefined*. An env var set to `""` yields `Number("") = 0`, and to `"abc"` yields `NaN`; both abort the request at once. RECOMMEND the native parser treat empty, non-numeric or ≤ 0 values as the default (documented divergence, §15 Q14).

**Other config-derived values**
- `serverHost(origin)` (`src/ui/household/join.ts:83-90`): `trim()`, strip a leading scheme matching `/^[a-z][a-z0-9+.-]*:\/\//i`, then cut at the first `/`, `?` or `#`. If nothing is left, return the **untrimmed** input.
- The default phone name for joining comes from `Constants.deviceName` (`src/ui/household/JoinForm.tsx:93`), which is `UIDevice.current.name` (`node_modules/expo-constants/ios/EXConstantsService.m:102-106`), filtered by `suggestedPhoneName` (`join.ts:60-63`). On iOS 16+ this is the generic model name unless the app has the user-assigned-device-name entitlement. The RN app does not have it, so parity needs no entitlement. Generic names are filtered to `''`.
- `LATEST_SCHEMA_VERSION` (7) is shown in Settings as `strings.settings.schemaValue(7)` (`app/settings.tsx:121-122`).

### 8.2 Values per environment

| | development | preview | production |
|---|---|---|---|
| EAS profile | `development` (dev client, internal, device-only: `ios.simulator false`), `eas.json:7-19` | `preview` (internal / ad hoc), `eas.json:21-28` | `production` (store, `autoIncrement`), `eas.json:30-39` |
| `EXPO_PUBLIC_ENV` | `development` (`eas.json:11`) | `preview` (`:24`) | `production` (`:33`) |
| Recognition URL | from local `.env.local` when Metro runs on the dev machine (e.g. `http://localhost:8787/api/recognize`, `.env.example:13-16`); otherwise nil | **none in eas.json**, so nil unless set as an EAS environment variable | `https://server-wy-studio.vercel.app/api/recognize` (`eas.json:34`) |
| Sync URL | `.env.local` (e.g. `http://localhost:8787`, `.env.example:31-35`) | none, so nil unless set in EAS | `https://inventory-sync.wyachou95.workers.dev` (`eas.json:35`) |
| Recognition key / sync key | `.env.local` | EAS env vars, if any | **not in eas.json**, so they must come from EAS project environment variables (§8.3) |
| Timeouts | 15 000 / 60 000 unless overridden | same | same |
| Household origin | default `https://inventory.wystudio.be` (no env anywhere) | same | same |
| Telemetry output | console (`__DEV__`) | none | none |

### 8.3 How the shared app secret (`x-inventory-key`) gets into the RN build today

- `EXPO_PUBLIC_*` variables are inlined into the JS bundle by Metro at bundle time (`config.ts:1-13`; `.env.example:3-5`). The key is a plain string inside the bundle and is **extractable by design**. The code and backends say so explicitly (`config.ts:18-24,36-42`; `server/src/auth.ts:3-13`; `worker/src/auth.ts:4-16`). It deters casual abuse. The server's rate limit is the spend cap, and the sync account is protected by the device-generated recovery code.
- Sources, by build type:
  - **Local dev builds:** `.env.local` (gitignored, `.gitignore:42,53`), read by the Expo CLI.
  - **EAS cloud builds:** `eas.json` `env` (no keys there), plus EAS project environment variables configured on expo.dev for the profile's environment. EAS does not upload gitignored files, so `.env.local` cannot be the source for production. **Inference, unverified: §15 Q1.**
- Backend checks:
  - recognition (Vercel) compares the header to `RECOGNITION_SHARED_SECRET` (trimmed) in constant time. An unset secret means an open endpoint; a missing or wrong header gives 401 (`server/src/auth.ts:15-31`);
  - sync (Cloudflare Worker) compares it to `SYNC_SHARED_SECRET` (trimmed; unset means no app-key check) and **also** requires `Authorization: Bearer <recovery code>` (`worker/src/auth.ts:18,28-35`).
- The client sends the header **only when the key is non-nil** (`recognition.ts:93`, `sync/client.ts:51`).
- **Household requests never carry `x-inventory-key`.** The home server is reached with the session bearer token only (`client.ts:162-169`). Do not add the app key to the household client.
- A recognition test asserts that no `authorization` or `x-api-key` header is ever sent to recognition (`src/services/ai/__tests__/recognition.test.ts:142-152`).

### 8.4 Native configuration design (RECOMMEND)

```
native-ios/Config/
  Shared.xcconfig            # PRODUCT_BUNDLE_IDENTIFIER = com.wystudio.inventory
                             # IPHONEOS_DEPLOYMENT_TARGET = 26.0 ; SWIFT_VERSION = 6.0 ; SWIFT_STRICT_CONCURRENCY = complete
                             # INV_HOUSEHOLD_ORIGIN = https:/$()/inventory.wystudio.be
                             # INV_RECOGNITION_TIMEOUT_MS = 15000 ; INV_SYNC_TIMEOUT_MS = 60000
                             # INV_RECOGNITION_URL = ; INV_SYNC_URL = ; INV_RECOGNITION_KEY = ; INV_SYNC_KEY =
                             # #include? "Secrets.xcconfig"      (optional include, last so it wins)
  Debug.xcconfig             # #include "Shared.xcconfig" ; INV_APP_ENV = development ; #include? "Local.xcconfig"
  Preview.xcconfig           # Release-based config ; INV_APP_ENV = preview   (URLs: see §15 Q2)
  Release.xcconfig           # INV_APP_ENV = production
                             # INV_RECOGNITION_URL = https:/$()/server-wy-studio.vercel.app/api/recognize
                             # INV_SYNC_URL = https:/$()/inventory-sync.wyachou95.workers.dev
  Secrets.example.xcconfig   # INV_RECOGNITION_KEY = / INV_SYNC_KEY =   (committed, empty)
  Secrets.xcconfig           # gitignored; written by CI from repository secrets; never committed
  Local.xcconfig             # gitignored; developer overrides (local server URLs)
```

- **Info.plist:** add a dictionary `InventoryConfig` with keys `AppEnvironment = $(INV_APP_ENV)`, `RecognitionURL`, `RecognitionKey`, `RecognitionTimeoutMs`, `SyncURL`, `SyncKey`, `SyncTimeoutMs`, `HouseholdOrigin`, each set to `$(INV_…)`. Build settings expand in Info.plist by default.
- **Swift:** `AppConfig.load(from bundle: Bundle) -> AppConfig` reads that dictionary and applies **exactly** the §8.1 rules. An empty string means absent, because an unset xcconfig variable expands to `""`.
- **xcconfig gotcha:** `//` starts a comment, so `https://x` silently becomes `https:`. Write URLs as `https:/$()/host/path`.
- **Exposure is unchanged:** Info.plist values are readable in the IPA, just as JS bundle strings were. There is nothing to obfuscate (the key is not a secret by design). **Never commit the real values.**
- **CI:** EAS will no longer build iOS. The native build needs a macOS runner or Xcode Cloud that writes `Secrets.xcconfig` from secrets. Suggested names: `INVENTORY_RECOGNITION_KEY`, `INVENTORY_SYNC_KEY`. Keep the two entries separate even if the values are equal; `worker/src/auth.ts:7` says it is "the same shared app secret".
- **Network timeouts:** the JS timeouts are **total wall-clock** (an `AbortController` fires after N ms: `client.ts:155-156`, `sync/client.ts:42-43`, `recognition.ts:81-82`). `URLRequest.timeoutInterval` is an *idle* timeout, so it does not match. Race the request against `Task.sleep` (or use `URLSessionConfiguration.timeoutIntervalForResource` per session) to keep the semantics. This affects the household (default 20 000 ms, `client.ts:156`), sync (60 000 ms) and recognition (15 000 ms) clients.

### 8.5 Identity and build settings the native target must carry

| Setting | RN value (source) | Native |
|---|---|---|
| Bundle id | `com.wystudio.inventory` (`app.json:13`) | same (**MUST**) |
| Apple Team | the team that signed the EAS builds (keychain default access group) | **MUST be the same team** (§3.1) |
| Display name | `Inventory` (`app.json:3`; generated `ios/Inventory/Info.plist` `CFBundleDisplayName`) | same |
| Marketing version | `0.1.0` (`app.json:5`); Settings shows it (`appInfo.ts:4`) | must be **higher than the live App Store version** (§15 Q3) |
| Build number | `appVersionSource: remote` + `autoIncrement` (`eas.json:4,31`), so EAS owns the counter | must exceed the highest build uploaded to App Store Connect app `6795274058` (`eas.json:45`) |
| URL schemes | `inventory` (`app.json:8`) and `com.wystudio.inventory` (Expo-added; generated Info.plist) | keep `inventory` (QR labels `inventory://c/<token>`, `qr.ts:29`); the bundle-id scheme is unused by app code (§15 Q16) |
| Minimum OS | iOS 16.4 (generated `project.pbxproj` `IPHONEOS_DEPLOYMENT_TARGET`) | **26.0**. Users on older iOS stay on the last RN build (§15 Q4). |
| Device family / capabilities | `TARGETED_DEVICE_FAMILY = "1,2"`; `UIRequiredDeviceCapabilities = [arm64]` (generated `Info.plist:60-63`) | **keep both exactly**. An App Store update may not drop a device family or add a required capability (`02-device-storage-migration.md` §9.3). |
| Orientation | iPhone: `Portrait` + `PortraitUpsideDown` (`app.json:6` `"portrait"`; generated `ios/Inventory/Info.plist:68-72`). iPad: all four (`supportsTablet: true`, `app.json:12`; `Info.plist:73-79`). `UIRequiresFullScreen = false`, so iPad multitasking works | same |
| Appearance | `userInterfaceStyle: automatic` (`app.json:9`) | light and dark |
| Usage strings | `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription` (`app.json:15-19`) | copy verbatim; no microphone (`app.json` camera plugin `microphonePermission: false`) |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` (`app.json:18`) | same |
| ATS | `NSAllowsArbitraryLoads = false`, `NSAllowsLocalNetworking = true` (generated Info.plist) | keep local networking, at least in Debug, for local servers (§15 Q21). Release builds only talk to https hosts: the household goes through Cloudflare, "Phones only use the Cloudflare hostname" (`config.ts:52`). A Debug build that points at a dev server on the LAN also needs `NSLocalNetworkUsageDescription`, which the generated RN plist does not have (Debug-only RECOMMEND). |
| Entitlements | none (empty, `ios/Inventory/Inventory.entitlements`) | none. **Do not** add `keychain-access-groups` that would change the default group. The user-assigned-device-name entitlement is not needed (§8.1). |
| Handoff activity | `$(PRODUCT_BUNDLE_IDENTIFIER).expo.index_route` (Expo Router) | drop |
| Privacy manifest | provided by the Expo modules | add `PrivacyInfo.xcprivacy`: `NSPrivacyAccessedAPICategoryUserDefaults` (CA92.1) and `NSPrivacyAccessedAPICategoryDiskSpace` (E174.1, for the free-space check before writing photos, `imageStore.ts:200-207`); no tracking, no collected data types beyond what the recognition and backup areas declare |
| EAS project | `extra.eas.projectId`, `owner: wa1id` (`app.json:70-76`); `extra.router: {}` | not used natively |

### 8.6 Files

- **`.env.example`** (committed) keys:
  - `EXPO_PUBLIC_RECOGNITION_URL`
  - `EXPO_PUBLIC_RECOGNITION_KEY`
  - `EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS` (15000)
  - `EXPO_PUBLIC_SYNC_URL`
  - `EXPO_PUBLIC_SYNC_KEY`
  - `EXPO_PUBLIC_SYNC_TIMEOUT_MS` (60000)
  - `EXPO_PUBLIC_ENV` (development)

  It does not list `EXPO_PUBLIC_HOUSEHOLD_ORIGIN`, which `config.ts:73` supports. Its comments require https in shipped builds (the recovery code is a bearer token, `.env.example:26-29`).
- **`.env.local`** (gitignored, `.gitignore:42,53`; 194 bytes): not readable in this session. Presumably a subset of the keys above.
- **`eas.json`**: see §8.2. Submission: `submit.production.ios.ascAppId = 6795274058`.
- **`app.json` `extra`**: `router: {}` and `eas.projectId`. No runtime config is read from `extra`. There are two `expo-constants` uses: `Constants.expoConfig.version` (`appInfo.ts:4`) and `Constants.deviceName` (`JoinForm.tsx:93`, §8.1). `app.json` `ios.buildNumber: "1"` (`:14`) is ignored because `appVersionSource` is `remote`.
- **`babel.config.js`**: `babel-preset-expo` only. No module resolver.
- **`tsconfig.json`**: alias `@/*` → `./src/*`; strict; `noUncheckedIndexedAccess`. Swift modules replace the alias (§13.1).
- **`expo-env.d.ts`**: generated and gitignored (`.gitignore:12`). It contains only `/// <reference types="expo/types" />`. Nothing to port.

---

## 9. Telemetry

### 9.1 Design (`src/services/telemetry/index.ts`)

- **API:** `logEvent(name, payload = {})` and `logError(name, payload = {})` (`:85-91`).
- **Payload:** `Record<string, string | number | boolean | null>` (`:15-16`).
- **Sink:** a `TelemetrySink` protocol `{event(name, payload), error(name, payload)}` (`:18-21`), swappable with `setTelemetrySink` (`:81-83`).
- **Redaction (allowlist, not denylist)** (`:56-67`). Keep a key only if it is in `ALLOWED_KEYS` **and** its value is `null`, a string, a number or a boolean. Everything else is dropped silently. `ALLOWED_KEYS` (`:29-53`), exactly 23:

  `durationMs, latencyMs, outcome, errorClass, contractVersion, statusCode, itemCount, containerCount, spaceCount, resultCount, termCount, queryLength, confidence, source, permission, screen, step, schemaVersion, byteSize, attempt, hasPhoto, suggestionAccepted, hinted`
- **Sinks in use:** only `consoleSink` (`:70-77`). It prints **only when `__DEV__`**: events with `console.log('[telemetry] <name>', payload)`, errors with `console.warn('[telemetry:error] <name>', payload)`. Natively, map events to `Logger.debug` and errors to `Logger.error`.
- **`errorClass` values in RN** are `Error.name` strings: `'HouseholdHttpError'` (`client.ts:11`), `'ConflictError'` (`conflict.ts:14`), `'TypeError'`, `'AbortError'`, `'Error'`, or `'unknown'` for non-`Error` throws. Some call sites send a `describeError` kind instead (see the catalogue). Swift has no `Error.name`. Use `String(describing: type(of: error))` and **never** `localizedDescription`, which can carry user text or paths.
- **Vendor and endpoint:** none. No network, no persistence, no crash reporter. `setTelemetrySink` is never called.
- **Consent / opt-out:** none exists or is needed, because nothing leaves the device. The privacy screen states this (`strings.privacy.diagnosticsTitle`, `strings.privacy.diagnosticsBody`, `src/i18n/strings.ts:1050-1052`). **Any native vendor (MetricKit upload, Crashlytics, analytics) requires changing that copy, a consent decision, and the App Store privacy label.**
- **Privacy rule** (issue #8, `:9-12`): item names, notes, photo URIs, QR tokens, search text, the recovery code and sync tokens must never reach telemetry.

### 9.2 Event catalogue (payload shown **after** redaction)

E = `logEvent`, X = `logError`. `kind` = `describeError(...).kind` (§10).

| Event | E/X | Source | Payload |
|---|---|---|---|
| `database_ready` | E | `src/providers/DatabaseProvider.tsx:50` | `durationMs` |
| `database_open_failed` | **E** | `DatabaseProvider.tsx:54` | `durationMs` |
| `fonts_failed` | X | `src/providers/FontProvider.tsx:54` | — (dropped natively) |
| `household_fetch_failed` | X | `src/services/household/client.ts:184` | `errorClass` = `Error.name` (network errors only; not timeouts). Also fires for every failed offline health ping (§4.3) |
| `household_shadow_failed` | **E** | `src/services/household/shadow.ts:106` | `errorClass` = `Error.name` |
| `household_join_failed` | X | `src/ui/household/JoinForm.tsx:130` | `outcome` = `refused\|offline\|other`, `statusCode` (or null), `errorClass` = `Error.name` |
| `household_imported` | E | `src/services/household/importHousehold.ts:74` | `itemCount` |
| `household_import_failed` | X | `app/household.tsx:155` | `errorClass` |
| `device_removed` | E | `app/household.tsx:187` | — |
| `household_remove_failed` | X | `app/household.tsx:191` | `statusCode` (or null), `errorClass` |
| `household_left` | E | `app/household.tsx:227` | — |
| `onboarding_finished` | E | `app/onboarding.tsx:52` | `outcome` = `completed\|skipped`, `step` |
| `search_performed` | E | `src/hooks/useSearch.ts:102` | `termCount`, `resultCount` (items + locations), `queryLength`; once per distinct trimmed query |
| `item_created` | E | `app/item/new.tsx:538` | `hasPhoto`, `suggestionAccepted`, `hinted` |
| `item_create_failed` | X | `app/item/new.tsx:525` | `errorClass` = kind |
| `item_updated` | E | `src/hooks/useSavedQuantity.ts:104`, `src/ui/item/NameItInline.tsx:148`, `app/item/[id]/edit.tsx:197` | — |
| `item_update_failed` | X | `app/item/[id]/edit.tsx:225` | `errorClass` = kind |
| `item_name_failed` | X | `src/ui/item/NameItInline.tsx:163` | `errorClass` = kind |
| `item_deleted` | E | `app/item/new.tsx:481`, `app/capture/review.tsx:159`, `app/item/[id]/index.tsx:239` | — |
| `item_delete_failed` | X | `app/item/new.tsx:487`, `app/capture/review.tsx:166`, `app/item/[id]/index.tsx:254` | `errorClass` = kind |
| `item_moved` | E | `src/hooks/useMove.ts:132` | — |
| `item_move_failed` | X | `useMove.ts:180` | `errorClass` = kind (context `move`) |
| `item_move_undone` | E | `useMove.ts:92` | — |
| `item_move_undo_failed` | X | `useMove.ts:100-105` | `outcome` = `gone\|conflict\|failed`; plus `errorClass` = kind when `failed` |
| `space_created` / `space_updated` | E | `app/space/new.tsx:179` / `app/space/[id]/edit.tsx:104` | — |
| `space_deleted` | E | `app/space/[id]/edit.tsx:165` | `containerCount`, `itemCount` (only if this phone deleted it) |
| `container_created` / `container_updated` | E | `app/container/new.tsx:77` / `app/container/[id]/edit.tsx:119` | — |
| `container_deleted` | E | `app/container/[id]/edit.tsx:177` | `itemCount` |
| `qr_generated` / `qr_unbound` | E | `app/container/[id]/qr.tsx:162` / `:187` | — |
| `qr_bound` | E | `app/c/[token].tsx:128`, `app/container/[id]/link.tsx:175` | — |
| `qr_bind_failed` | X | `app/c/[token].tsx:140` | `errorClass` = kind (`label`, `container`) |
| `qr_scan` | E | `app/(tabs)/scan.tsx:234,242,248` | `outcome` = `bound\|unknown\|invalid` |
| `qr_scan_failed` | X | `scan.tsx:226` | `errorClass` = kind |
| `qr_deeplink` | E | `app/c/[token].tsx:87` | `outcome` = `bound\|unknown\|invalid` |
| `qr_deeplink_failed` | X | `app/c/[token].tsx:96` | `errorClass` = kind |
| `permission_result` | E | `src/ui/components/CameraPermission.tsx:97` | `permission` = `camera`, `outcome` = `granted\|denied` |
| `photo_captured` | E | `app/capture/index.tsx:182` / `:285` | `source` = `camera\|library`, `byteSize` / `source` = `camera` (**`mode: 'fast'` dropped**) |
| `photo_capture_failed` | X | `app/capture/index.tsx:212` | `source` |
| `fast_capture_failed` | X | `app/capture/index.tsx:295` | `source` = `camera` |
| `recognition_unusable` | E | `app/capture/index.tsx:289` | — (**`reason` dropped**) |
| `fast_review_done` | E | `app/capture/review.tsx:187` | — (**`kept`, `unnamed` dropped**) |
| `photo_stored` | E | `src/services/capture/imageStore.ts:121` | `durationMs`, `byteSize` |
| `photo_store_failed` | X | `imageStore.ts:128` | `durationMs`, `errorClass` = `Error.name` |
| `recognition_skipped` | E | `src/services/ai/recognition.ts:72` | `outcome` = `not_configured` |
| `recognition_completed` | E | `recognition.ts:132` | `outcome` = `success` or a failure reason, `latencyMs`, `contractVersion`, `confidence` (or null), `hinted` |
| `recognition_failed` | X | `recognition.ts:107,121,143` | `outcome` = reason, `statusCode` (HTTP case only), `latencyMs`, `contractVersion`, `hinted` |
| `photo_uploaded` | E | `src/services/sync/client.ts:90` | `latencyMs`, `byteSize` |
| `photo_upload_failed` | X | `sync/client.ts:82` | `outcome` = `SyncFailureReason`, `latencyMs`, `byteSize` |
| `backup_uploaded` | E | `sync/client.ts:143` | `latencyMs`, `byteSize`, `schemaVersion` |
| `backup_upload_failed` | X | `sync/client.ts:132` | `outcome`, `latencyMs`, `byteSize`, `schemaVersion` |
| `backup_snapshot_failed` | X | `src/services/sync/backup.ts:74` | `durationMs`, `errorClass` |
| `backup_too_large` | X | `backup.ts:84` | `byteSize` |
| `restore_rejected` | X | `backup.ts:135` | `schemaVersion`, `outcome` = `newer_schema` |
| `restore_failed` | X | `backup.ts:145` | `durationMs`, `errorClass` |
| `restore_succeeded` | E | `backup.ts:152` | `durationMs`, `byteSize`, `schemaVersion` |
| `photo_sync_pass` | E | `src/services/sync/photoSync.ts:185` | `durationMs`, `itemCount` (= uploaded + deleted + restored), `outcome` = `interrupted\|complete` |
| `backup_enable_failed` / `backup_restore_failed` / `backup_now_failed` | X | `app/backup.tsx:134` / `:182` / `:325` | `errorClass` |

**Keys dropped by the allowlist today** (silently, because they are not listed): `mode`, `reason`, `kept`, `unnamed`. See §15 Q9.

### 9.3 Native design (RECOMMEND)

```swift
public enum TelemetryKey: String, Sendable, CaseIterable { case durationMs, latencyMs, outcome, errorClass, /* … all 23 */ hinted }
public enum TelemetryValue: Sendable, Equatable { case string(String), int(Int), double(Double), bool(Bool), null }
public protocol TelemetrySink: Sendable { func event(_ name: String, _ payload: [TelemetryKey: TelemetryValue]); func error(_ name: String, _ payload: [TelemetryKey: TelemetryValue]) }
public enum Telemetry { public static func install(_ sink: any TelemetrySink); public static func event(_ name: String, _ payload: [TelemetryKey: TelemetryValue] = [:]); public static func error(...) }
```

- Typed keys make the allowlist a compile-time guarantee. Still keep a `redact(_ raw: [String: Any]) -> [TelemetryKey: TelemetryValue]` for parity with the RN test (§14).
- Sinks:
  - `OSLogSink`, `Logger(subsystem: "com.wystudio.inventory", category: "telemetry")`, installed in **Debug only**. Mark values `privacy: .public`; they are allowlisted, non-identifying measurements.
  - `NoopSink` in Preview and Release, which matches `__DEV__ == false`.
- Store the sink in a `Mutex` (Synchronization framework) so it is safe from any isolation domain.
- Event names: a `String`-backed `enum TelemetryEvent` listing the catalogue above avoids typos.

---

## 10. Errors

### 10.1 Error taxonomy (what can reach `describeError`)

| Type | Shape | Produced by |
|---|---|---|
| `HouseholdHttpError(status, code)` | `status` (0 when no answer), `code` string (`client.ts:5-13`) | household client |
| `ConflictError(updatedAt?)` | `status = 409`, `code = 'conflict'`, `updatedAt: number \| null` (`src/core/conflict.ts:8-16`) | local `items.update` with a stale stamp; household HTTP 409 (`client.ts:125-131`) |
| `null` (a read result) | "gone" | a record deleted elsewhere returns `null` |
| anything else (`Error`, `undefined`, SQLite errors) | — | local DB and misc |

`HouseholdHttpError.code` values:

| Code | Meaning | Source |
|---|---|---|
| `offline` | network error, status 0 | `client.ts:187` |
| `timeout` | abort after the timeout, status 0 | `client.ts:181-183` |
| `invalid_json` | non-JSON body | `client.ts:122` |
| `invalid_response` | pair response missing fields | `client.ts:92` |
| `http_<status>` | non-OK without an `error` field | `client.ts:133-137` |
| server-provided `error` string | e.g. `unauthorized`, `not_found`, `photo_missing`, `photos_not_configured` (see tests) | server |

Separate result-value taxonomies, which are not thrown:
- `SyncFailureReason` (`src/services/sync/contract.ts:39-50`, classified by `sync/client.ts:196-211`), worded by `backupReason` (`src/ui/household/status.ts:166-190`);
- `RecognitionFailureReason` (`src/services/ai/contract.ts:22-31`, classified by `recognition.ts:40-51`);
- `joinFailure` = `refused | offline | other` (`src/ui/household/join.ts:73-81`).

These belong to their areas, but natively they live in the same `Errors` module.

### 10.2 `describeError(cause, context = 'read', subject = 'list') -> {kind, title, body}` (`src/ui/errors.ts:41-82`)

Types (`:5-7`):
- `ErrorKind = offline | revoked | conflict | gone | photo | server | local`
- `ErrorContext = read | save | move | quantity | delete | label | join`
- `ErrorSubject = item | space | container | list`

`reading = context in {read, join}` (`:46`). Evaluate **in this order**:

1. `cause is ConflictError` gives `conflict`: `strings.errors.conflict.{title,body}` (`:48-50`).
2. `cause === null` gives `gone`: title by subject (space, container, otherwise item, `:26-30`); body `strings.errors.gone.body` (`:52-54`).
3. `cause is HouseholdHttpError` (`:56-75`):
   1. **unreachable** (`isUnreachable`, `:16-24`) gives `offline`, with title `strings.errors.offline.title` and body `.read` if reading, else `.save`. Unreachable means:
      - `code` is `offline`, `timeout` or `http_502`; or
      - `status' == 502` or `520 <= status' <= 530`, where `status'` is the 3 digits from `code` if it matches `^http_(\d{3})$`, else `error.status`.
   2. `context != join` and (`status == 401` or `code == 'unauthorized'`) gives `revoked`: `strings.errors.revoked.{title,body}` (`:65-67`). This means a 403 with code `unauthorized` is also revoked. While joining, a 401 is a refused code, not a removed phone.
   3. `status == 404` or `code == 'not_found'` gives `gone`, same as step 2 (`:68-70`).
   4. `code == 'photo_missing'` gives `photo`: `strings.errors.photo.{title,body}` (`:71-73`).
   5. otherwise `server`: `strings.errors.server.{title,body}` (`:74`).
4. Anything else, including `undefined`, gives `local`, with title `strings.errors.local.title` and body `.read` if reading, else `.save` (`:77-81`).

**Raw codes and `Error.message` never reach the screen** (`:33-40`). The cause itself goes only to telemetry, and only as the `kind` or `Error.name`.

### 10.3 Helpers

- `needsRefreshBanner(refreshFailed, cause)` (`:90-94`): `false` if `!refreshFailed`; otherwise true unless `describeError(cause).kind` is `offline` or `revoked`. Those already have the connection banner and the revoked layer. The banner copy is `strings.errors.refreshFailed`.
- `isOffline(cause)` (`:97-99`): `describeError(cause, 'save').kind == offline`.

### 10.4 Native design

```swift
public enum ErrorKind: String, Sendable { case offline, revoked, conflict, gone, photo, server, local }
public enum ErrorContext: Sendable { case read, save, move, quantity, delete, label, join }
public enum ErrorSubject: Sendable { case item, space, container, list }
public struct HouseholdHTTPError: Error, Sendable, Equatable { public let status: Int; public let code: String }
public struct ConflictError: Error, Sendable { public let updatedAt: Int64? }      // status 409, code "conflict"
public enum QueryCause: Sendable { case gone; case error(any Error) }               // models JS null vs thrown
public struct DescribedError: Sendable, Equatable { let kind: ErrorKind; let title: String; let body: String }
public func describeError(_ cause: QueryCause?, context: ErrorContext = .read, subject: ErrorSubject = .list) -> DescribedError
```

The JS `undefined` cause is Swift `nil` and maps to `local`. Keep the function pure (strings injected or read from the String Catalog) so the tests in §14 port one-to-one.

---

## 11. Logging

- The only console output in the app is the telemetry console sink, and only in `__DEV__` (`telemetry/index.ts:72,75`). There is no other `console.*` call (grep).
- There is no global error handler, no `ErrorUtils`, and no error boundary.
- **Native:**
  - `Logger` per subsystem and category (`telemetry`, `boot`, `db`, `household`, `sync`, `recognition`).
  - Debug-level detail only, with `privacy: .private` as the default for any dynamic value that is not a telemetry measurement.
  - **Never log** the recovery code, household token, `x-inventory-key`, item names, notes, QR tokens or photo paths. The recovery code must never appear in a URL, a log or telemetry (`sync/client.ts:20-30`).
  - Release builds should emit nothing above `.debug` except unexpected-failure `.error` lines without payloads.

---

## 12. RN/Expo-specific workarounds that disappear natively

| RN mechanism (source) | Why it existed | Native replacement |
|---|---|---|
| `FontProvider` + `fontContext` + typography font switching (`FontProvider.tsx`, `src/ui/fontContext.ts`) | custom font load without blocking; Bold Text not applied to custom fonts | System font; Dynamic Type and Bold Text automatic. Delete. |
| `configureRandomBytes` injection (`DatabaseProvider.tsx:13-15`, `id.ts:15-33`) | share id code with the Node home server | `SecRandomCopyBytes`; inject a generator only in tests |
| `SafeAreaProvider` / `SafeAreaView` edges (`_layout.tsx:225`, `ScreenFrame.tsx:16-28`) | RN has no safe-area layout | SwiftUI safe areas; `.ignoresSafeArea` for camera |
| `SystemUI.setBackgroundColorAsync` (`_layout.tsx:113-115`) | avoid white flashes behind RN views | not needed |
| `navigationTheme` / `screenOptions` (`_layout.tsx:40-55,122-140`) | style native-stack headers | stock `NavigationStack`; large titles where RN drew them in content (tab roots, detail screens), inline elsewhere (§2.5); iOS 26 Liquid Glass bars |
| `useInventoryQuery` `runRef` and string-key hashing (`useInventoryQuery.ts:73-80,130-138`) | React closure staleness; lint-checkable dependencies | `.task(id:)` with a `Hashable` trigger |
| derived-state-during-render tricks (`useInventoryQuery.ts:65-69`, `ConnectionProvider.tsx:69-72`) | React render rules | plain model state changes |
| `useDelayedFlag` (`src/hooks/useDelayedFlag.ts`) | no setState in effect body | `.task { try? await Task.sleep(for: .milliseconds(400)); show = true }` |
| `FullWindowOverlay` (`Toast.tsx:243-251`) | draw above native modals | pass-through overlay `UIWindow` (§7.7) |
| `useBottomChrome` / `registerChrome` (`ToastProvider.tsx:241-295`) | toast must clear the RN tab bar or bottom bar | still needed (overlay window cannot see the bars); report heights with `onGeometryChange` |
| `useKeyboardInset` (`src/hooks/useKeyboardInset.ts`) | RN does not move content with the keyboard | `.safeAreaInset(edge: .bottom)` handles it |
| `AppState` listeners | — | `scenePhase` |
| `AccessibilityInfo.*` listeners, `announceForAccessibility*` | — | accessibility environment values; `AccessibilityNotification.Announcement` |
| `accessibilityLiveRegion` (`BootScreen.tsx:22`, `ErrorState.tsx:65`) | Android only | omit; explicit announcements where RN did them on iOS |
| `BackHandler` (`ConnectionBanner.tsx:66`) | Android back | not applicable |
| `expo-sqlite` wrapper, `SqlDatabase` interface (`expoDatabase.ts`, `src/db/types.ts`) | Expo/Node adapter parity for tests | one GRDB `DatabaseQueue` (`01-data.md` §2.2); tests use in-memory or temp-file GRDB |
| `expo-secure-store` | — | Security framework, same item attributes (§3.1) |
| AsyncStorage | — | `UserDefaults` (after the one-time import, §3.3) |
| `expo-constants` version | — | `Bundle.main` |
| `EXPO_PUBLIC_*` inlining, `eas.json` env | build-time config | xcconfig and Info.plist (§8.4) |
| `Stack.Protected` guards (`_layout.tsx:165,208`) | expo-router auth-style gating | root `switch` on `onboarding.status` |
| `unstable_settings.anchor` (`_layout.tsx:37`) | Home under a cold deep link | the deep-link handler builds the navigation path with Home as root (navigation area) |

---

## 13. Proposed native architecture skeleton

### 13.1 Folder and module layout

```
native-ios/
├── Inventory.xcodeproj                 # app target "Inventory" (+ UI test target)
├── Config/                             # §8.4 xcconfigs (Secrets/Local gitignored)
├── App/                                # thin app target
│   ├── InventoryApp.swift              # @main; owns AppContainer; scenePhase → AppLifecycle
│   ├── AppContainer.swift              # composition root (live / preview / test factories)
│   ├── RootView.swift                  # boot gate (§3.2) + onboarding/main switch + overlay install
│   ├── Shell/                          # BootView, BootFailedView, ErrorStateView, ScreenFrame,
│   │                                   # BottomBar, ConnectionBanner, RevokedOverlay, ToastHost, OverlayWindow
│   ├── Navigation/                     # router/paths, ScreenFocus, deep links (navigation area)
│   ├── Features/                       # Home, Spaces, Scan, DropZone, Item, Container, Space, Capture,
│   │                                   # Settings, Backup, Household, Onboarding, Privacy, DeepLink
│   └── Resources/                      # Info.plist, Localizable.xcstrings (keys mirror strings.ts paths,
│                                       # e.g. "boot.opening"), Assets.xcassets (AccentColor = brand tape),
│                                       # PrivacyInfo.xcprivacy, Inventory.entitlements (empty)
└── Packages/InventoryKit/              # local SwiftPM package; `swift test` runs all logic tests
    ├── Package.swift                   # tools 6.x; platforms iOS 26 / macOS 26; dep: GRDB 7
    ├── Sources/
    │   ├── InventoryCore/              # pure: AppConfig(+parser), Telemetry(+redact), describeError & error types,
    │   │                               # ConflictError, ids/QR tokens, base32, quantity, tokenize, shortCode, serverHost
    │   ├── InventoryStorage/           # GRDB DatabaseStore, MigrationRunner (user_version), repositories,
    │   │                               # ExpoCompatibleKeychain (02 §4.3), Preferences (UserDefaults), LegacyImport (02 §5.4)
    │   ├── InventoryNetwork/           # HouseholdClient + ReachabilityHub, SyncClient, RecognitionClient (total-timeout helper)
    │   ├── InventoryServices/          # Backup, PhotoSync, ImageStore, HouseholdShadow, HTTP repositories, SyncCoordinator
    │   └── InventoryAppModels/         # @MainActor @Observable: DatabaseModel, HouseholdModel, ConnectionModel,
    │                                   # SyncModel, OnboardingModel, ToastCenter, InventoryQuery, AppLifecycle
    └── Tests/                          # Swift Testing, one target per module (§14)
```

Mapping from TypeScript: `src/core` → InventoryCore; `src/db` and `src/repositories` → InventoryStorage; `src/services/*` → InventoryNetwork and InventoryServices; `src/providers` and `src/hooks/useInventoryQuery` → InventoryAppModels; `src/ui/components` and `app/` → App/Shell and App/Features; `src/i18n/strings.ts` → String Catalog.

### 13.2 Composition root and dependency injection

```swift
@main struct InventoryApp: App {
  @State private var container = AppContainer.live()          // builds config, telemetry, stores, clients, models
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(container.database).environment(container.household)
        .environment(container.connection).environment(container.sync)
        .environment(container.onboarding).environment(container.toasts)
        .environment(\.appConfig, container.config)               // @Entry environment values for services
    }
    .onChange(of: scenePhase) { _, phase in container.lifecycle.scenePhaseChanged(phase) }
  }
}
```

- `AppContainer.live()` does no I/O (§3.2 step 0).
- `AppContainer.preview()` and `.test()` use an in-memory GRDB database, a `URLProtocol` stub, a fake keychain, a `UserDefaults(suiteName:)` suite and a test clock.
- Services (`HouseholdClient`, `SyncClient`, `RecognitionClient`, `ImageStore`) are `Sendable` values passed into models through their initialisers and exposed to views through `@Entry` environment values where needed.

### 13.3 App models summary

| Model | State exposed | Commands | Lifecycle hooks |
|---|---|---|---|
| `DatabaseModel` | `state`, `revision` | `open`, `retry`, `invalidate` | boot |
| `HouseholdModel` | `session`, `ready`, `remoteRepositories` | `load`, `pair`, `disconnect` | boot |
| `RepositoryProvider` (computed) | `repositories` (local, or shadowed remote) | — | — |
| `ConnectionModel` | `state` | `retry` | session change, scenePhase |
| `SyncModel` | `status` | `enable`, `backupNow`, `restoreFromCode`, `refresh` | DB ready, account loaded, scenePhase `.active` |
| `OnboardingModel` | `status` | `complete`, `replay` | boot |
| `ToastCenter` | `current`, `leaving`, `chromeHeight` | `show`, `dismiss`, `pause`, `resume`, `registerChrome` | VoiceOver state |
| `InventoryQuery<T>` (per screen) | `data`, `isLoading`, `cause`, `refreshFailed` | `reload` | focus, revision |
| `DropZoneModel` (tabs) | items, count, loading, ... | `reload` | as `InventoryQuery` |

### 13.4 Concurrency model (Swift 6 strict)

- **UI and models:** `@MainActor`. Every published state change happens on the main actor.
- **Database:** `final class DatabaseStore: Sendable` wrapping **one GRDB `DatabaseQueue`** (cross-spec decision: `01-data.md` §2.2, `02-device-storage-migration.md` §2.3), which is thread-safe and Sendable and serialises all access on one connection, like RN. It keeps the pre-snapshot `wal_checkpoint(TRUNCATE)` and the restore backup API free of reader interference, and keeps `synchronous = FULL`. Repositories are `Sendable` structs with `async throws` methods (`try await queue.read {}` / `write {}`). No custom actor is needed; if one is preferred, a single `actor InventoryDatabase` must not hold the queue across suspension points it does not need. The data volume (one household's inventory) does not need concurrent readers.
- **Network:** `Sendable` client structs over `URLSession` async APIs.
  - A `withTotalTimeout(ms)` helper races the request against `Task.sleep`, matching the JS `AbortController` semantics (§8.4).
  - `ReachabilityHub` is a `final class: Sendable` with `Mutex<[UUID: AsyncStream<Reachability>.Continuation]>`. `report(_:)` yields to every stream. `ConnectionModel` consumes one stream in a main-actor `Task`. A listener can never fail a request (`client.ts:39-47`).
- **Exclusive work:** `actor SyncCoordinator { private var isRunning = false }`. Check and set the flag synchronously before the first `await`, because actors are reentrant. RN parity:
  - automatic passes **skip** when busy;
  - restore sets the flag unconditionally;
  - `enable`/`backupNow` ignore it.

  RECOMMEND: automatic passes skip, restore **waits** for an in-flight pass, and `enable`/`backupNow` take the flag too (§15 Q13).
- **Timers:** `Task` with `try await clock.sleep(for:)`, cancelled on state change. Inject the clock (`any Clock<Duration>`) for tests.
- **Cancellation:** query reads use `.task(id:)`, which cancels on a trigger change or disappear. Boot uses structured `async let`.

### 13.5 Persistence facts that boot depends on (summary; details in the persistence area)

- **Use the `PRAGMA user_version` runner, not GRDB's `DatabaseMigrator`** (it would add `grdb_migrations`). The algorithm is `src/db/migrations.ts:284-313`:
  1. read `user_version`;
  2. for each migration with `version > current`:
     - if `rebuild`, record the current `PRAGMA foreign_keys` and execute `PRAGMA foreign_keys = OFF` **outside** a transaction;
     - in one transaction, execute the migration SQL and then `PRAGMA user_version = N`;
     - restore `foreign_keys = ON` afterwards if it was on. This sits in a `finally`, so it also runs when the migration throws (`:305-309`);
  3. return the new `user_version` (7).

  - The first migration that throws aborts the loop, and the error reaches `DatabaseProvider`, which shows the boot error screen.
  - **`user_version > 7`** (a file from a newer build, e.g. a TestFlight downgrade) skips every migration **silently and opens normally** (`:291`). Keep this; `01-data.md` §3 says the same.

  Run it through `writeWithoutTransaction` on the single `DatabaseQueue`, so the FK pragma toggles outside any transaction (`01-data.md` §3.1; `02-device-storage-migration.md` §2.3 rule 6).
- SQLite engine: the RN build links expo-sqlite's bundled SQLite **3.50.3** (`node_modules/expo-sqlite/vendor/sqlite3/sqlite3.h:149`), compiled with FTS3/4/5, math functions and the session extension (`ExpoSQLite.podspec:38-42`). GRDB uses the iOS system SQLite. The file format is compatible. A grep of `src/db`, `src/repositories` and the services finds no SQL that uses FTS, math functions, `STRICT`, `RETURNING`, JSON operators or generated columns, so nothing relies on the bundled build's extras. Re-check this if a migration adds any of them.
- Open-time pragmas: `journal_mode = WAL` (set in `prepareDatabase`; already persistent in the file header) and `foreign_keys = ON` (GRDB default), plus `synchronous = FULL` for parity (02 §2.3).
- Backups snapshot the whole file (`PRAGMA wal_checkpoint(TRUNCATE)`, then serialize, `expoDatabase.ts:31-34`), so **any extra table or index the native app adds becomes part of backups and household imports**. Avoid schema additions outside numbered migrations.

### 13.6 Testing approach

- Logic in `InventoryKit` is tested with Swift Testing (`@Test`, `#expect`, parameterised `arguments:` for the RN `it.each` tables) on macOS and iOS simulators.
- Fake clock for timers; `URLProtocol` stubs for HTTP; temporary directories for legacy-import fixtures (manifest with inline and null-plus-MD5-file values); a keychain test double plus one device or simulator integration test against the real keychain with expo-style attributes.

---

## 14. Unit tests to port (and new ones to add)

### 14.1 Existing RN tests that cover this area

| File | Test | Asserts | Port |
|---|---|---|---|
| `src/ui/__tests__/errors.test.ts:8-20` | describeError › "treats %p as the home server not answering" | Five cases: `(0,'offline')`, `(0,'timeout')`, `(502,'http_502')`, `(530,'http_530')`, `(520,'origin_down')`. Each gives kind `offline`; title equals `strings.errors.offline.title`; the read body contains "Nothing on this phone was lost"; the save body contains "What you typed is still here". | yes, parameterised |
| `errors.test.ts:22-26` | "treats a 401 as a removed phone, except while joining" | `(401,'unauthorized')` and `(403,'unauthorized')` give `revoked`; `(401,'unauthorized')` with context `join` gives `server` | yes |
| `errors.test.ts:28-39` | "treats null, 404 and not_found as gone, named by subject" | `null`/read/item gives `strings.errors.gone.item`; `(404,'http_404')`/read/space gives `gone.space`; `(400,'not_found')`/read/container gives kind `gone` and `gone.container` | yes |
| `errors.test.ts:41-43` | "separates a missing photo from a missing item" | `(0,'photo_missing')` gives `photo` | yes |
| `errors.test.ts:45-50` | "reads %p as a home-server problem" | status 500 with codes `http_500`, `invalid_json`, `invalid_response`, `photos_not_configured` gives `server` | yes |
| `errors.test.ts:52-54` | "reads a conflict as a change on another phone" | `ConflictError(1)` gives `conflict` | yes |
| `errors.test.ts:56-64` | "reads anything else as the local database" | `Error('SQLITE_BUSY')` read gives `local` with body `strings.errors.local.read`; save gives `strings.errors.local.save` | yes |
| `errors.test.ts:66-97` | "never puts a raw code or message on screen" | 12 causes (all codes above, `ConflictError()`, `Error('http_500 invalid_json')`, `null`, `undefined`) × 7 contexts, default subject `list`: neither title nor body matches `/http_\|invalid_\|offline\|timeout\|unauthorized\|not_found\|photo_missing/`. **This constrains the String Catalog copy**: no `errors.*` string may contain the word "offline", for example. | yes |
| `errors.test.ts:105-108` | "needsRefreshBanner and isOffline" › "leaves offline and removed phones to their own banner and layer" | `(true, offline)` and `(true, 401)` give `false` | yes |
| `errors.test.ts:110-114` | "explains any other failed refresh, and nothing when the refresh worked" | `(true, 500)` gives true; `(true, Error)` gives true; `(false, 500)` gives false | yes |
| `errors.test.ts:116-121` | "tells a connection failure from any other" | `isOffline`: offline gives true, `530` gives true, `500` gives false, a plain `Error` gives false | yes |
| `src/services/household/__tests__/reachability.test.ts:44-55` | household reachability › "reports ok for any answer from the home server" | token GET answered 200, and `householdRequest` answered 404 (rejects with `status: 404`), give `['ok','ok']` | yes (input to `ConnectionModel`) |
| `reachability.test.ts:57-60` | "reports unauthorized for a 401 on a request that carried a token" | token GET answered 401 gives `['unauthorized']` | yes |
| `reachability.test.ts:62-72` | "treats a refused household code while pairing as an answer, not a removed phone" | `pairWithHousehold` answered 401 `{error:'unauthorized'}` rejects with `status: 401` and reports `['ok']` (no token) | yes |
| `reachability.test.ts:74-82` | "reports offline when the request never gets an answer" | fetch throws `TypeError('Network request failed')`; rejects with `code: 'offline'`; reports `['offline']` | yes |
| `reachability.test.ts:84-89` | "reports offline when Cloudflare says the home box is down" | 530, 502, 500 give `['offline','offline','ok']` | yes |
| `reachability.test.ts:91-95` | "stops reporting to a listener that unsubscribed" | `[]` | yes (stream termination) |
| `reachability.test.ts:97-104` | "never fails a request because a listener threw" | a throwing listener still lets the response return 200 | adapt (Swift listeners cannot throw; assert one stalled consumer does not block others) |
| `src/core/__tests__/id.test.ts:10-13` | newId › "throws until an RNG is configured" | with no source, `newId()` throws `/not configured/` | yes (owned by the data area; listed because the CSPRNG install is a boot side effect, §2.1) |
| `id.test.ts:15-22` | newId › "formats RFC 4122 version-4 UUIDs from the injected bytes" | bytes `0…15` give `'00010203-0405-4607-8809-0a0b0c0d0e0f'` (lowercase) | yes |
| `id.test.ts:26-29` | newQrToken › "hex-encodes the injected 16 bytes" | 16 × `0xab` gives `'abab…ab'` (32 chars) | yes |
| `src/services/household/__tests__/client.test.ts:31-40,70-…` | pairWithHousehold › "maps 401 to HouseholdHttpError"; createHttpRepositories › "… maps 409 to ConflictError" | produce the error types consumed by `describeError` (§10.1) | yes (owned by the household area) |
| `src/services/ai/__tests__/recognition.test.ts:251-262` | telemetry redaction › "keeps only allowlisted measurement keys" | `{latencyMs, outcome, itemName, notes, photoUri, qrToken}` gives `{latencyMs, outcome}` | yes (`redact`) |
| `recognition.test.ts:264-266` | "drops non-primitive values even under an allowed key" | `{outcome: {nested}}` gives `{}` | yes |
| `recognition.test.ts:142-152` | "never sends a provider credential from the client" | header names exclude `authorization` and `x-api-key` (`x-inventory-key` is allowed) | yes (config and header contract) |
| `recognition.test.ts:235-247` | "reports not_configured when no endpoint is set, without calling fetch" | nil endpoint gives `{failed, not_configured}` and fetch is not called | yes (config nil gives feature off) |
| `src/ui/household/__tests__/status.test.ts:23-38` | backupSummary › "always has a value, including Off"; "marks a failed backup in signal" | `unavailable`→`notConfigured`, `off`→`off`, `working`→`working`, `idle(lastBackupAt:nil)`→`notYetRun`, `idle(t)`→`on`, all tone `ink`; `error`→`attention`, tone `signal` (keys under `strings.settings.backupSummary`) | yes (uses the `SyncStatus` shape owned here) |
| `status.test.ts:41-57` | showBackupRow (3 tests) | unpaired: always true; paired: false for `off` and `unavailable`, true for `idle` (with or without a last backup), `working`, `error` | yes |
| `src/ui/household/__tests__/join.test.ts:83-89` | serverHost › "keeps only the host of the address" | `https://inventory.wystudio.be` gives `inventory.wystudio.be`; `http://192.168.1.5:8788/` gives `192.168.1.5:8788`; `inventory.example` is unchanged | yes (config display) |
| `src/ui/__tests__/typography.test.tsx:3-30` | textStyle (5 tests: system font until fonts are ready, family per weight once ready, Bold Text bump, tabular numbers, location size) | — | **no**: system fonts natively |

There are **no RN tests** for providers, `useInventoryQuery`, `config.ts`, `BootScreen`, `ScreenFrame`, `BottomBar`, `ToastProvider` or the telemetry sink.

### 14.2 New Swift tests to add (behavior specified in this document)

- `AppConfigTests`: each §8.1 rule.
  - Trim; empty → nil.
  - Trailing-slash strip for sync and household but not recognition.
  - Environment fallback to `development`.
  - Timeout defaults, including empty, non-numeric and ≤ 0 values (per the §15 Q14 decision).
  - The `https:/$()/` xcconfig form resolves to `https://`.
- `ConnectionModelTests`: every row of the §4.3 table with a test clock.
  - The 2.5 s unsure-to-offline transition.
  - Recovery invalidates only once per 5 s.
  - Revoked is sticky until the session changes.
  - Pings every 10 s only while offline and active.
  - The resume refresh: the first evaluation while paired and active (including the session load resolving while active) only arms; it throttles to 5 s; a session change while active is evaluated too.
  - `ok` while revoked does not invalidate. `offline` while unsure, offline or revoked is ignored.
  - The announcement fires on each transition into `offline`.
  - `retry()` pings and invalidates.
  - `markJoinedBefore` is called on every new session key.
- `InventoryQueryTests`: §5 rules.
  - `cause == nil` whenever the current read succeeded, including a `nil` ("gone") result.
  - Data kept on a same-key failure and dropped on a different key.
  - `refreshFailed`, `loading` and `cause`.
  - A revision change while unfocused does not refetch, and focus refetches once.
  - `reload()`.
  - A stale result is ignored.
- `ToastCenterTests`: §4.6.
  - 5 s / 9 s lifetimes, doubled with VoiceOver.
  - The error hold of 1 500 ms; newest pending wins; an error is never replaced by an info toast.
  - `pause` and `resume` with a 2 500 ms minimum.
  - `dismiss` of a pending toast.
  - The id sequence.
  - The announcement text.
- `DatabaseModelTests`: open success and failure; retry closes and reopens; `invalidate` increments.
- `BootGateTests`: precedence (DB error beats loading; all three are needed; fonts and account never gate).
- `LegacyImportTests` (owned by `02-device-storage-migration.md` §11; listed here because boot depends on them):
  - inline values;
  - a null value with an MD5 file (lowercase hex MD5 of the UTF-8 key);
  - a null value whose file is missing gives an absent key;
  - only the 7 known keys are copied;
  - a fresh install (no manifest) sets the marker;
  - an unparsable manifest is treated as empty and sets the marker;
  - an unreadable or non-UTF-8 manifest leaves the marker unset;
  - an existing `UserDefaults` value is not overwritten;
  - `ExpoSystemUI.backgroundColor` is removed;
  - the import is a no-op once the marker (Int 1) is set.
- `ExpoCompatibleKeychainTests` (owned by 02 §11): read order `app:no-auth`, then legacy `app` (02 §4.3 skips `app:auth`); a non-`errSecItemNotFound` status throws, and the session/account loaders map that to `nil`; write = add with `WhenUnlocked`, then delete the `app` and `app:auth` variants on success, or update the value only on duplicate; delete removes all three variants and never throws; `kSecAttrAccount`/`kSecAttrGeneric` are `Data`.
- `MigrationRunnerTests` (owned by the data area): `user_version > 7` is a silent no-op; FK state is restored after a failing rebuild migration.
- `OnboardingModelTests`: `"true"` gives `completed`, anything else gives `pending`; `complete` and `replay` update the status before persisting.
- `SyncModelLifecycleTests`:
  - initial status from config;
  - a pass needs DB, account and no running pass;
  - a pass runs on `.active`;
  - restore blocks passes;
  - a restore failure forgets the account and sets `off`;
  - a completed automatic pass overwrites `error` with `idle`;
  - no keychain read when `syncEndpoint == nil` (status stays `unavailable`);
  - a stored code that does not decode to 16 bytes means no account;
  - whatever §15 Q13 decides about `enable`/`backupNow`/restore versus an in-flight pass.

---

## 15. Open questions

1. **Production `x-inventory-key` values.** They are not in `eas.json`. Are they EAS project environment variables (expo.dev, production environment)? Are the recognition and sync keys the same value? Who provisions them as CI secrets for the native build? This document never handled the values.
2. **Preview builds** get no recognition or sync URL from `eas.json`, so both features are off unless set in EAS. Should the native "Preview" configuration point at production endpoints, stay feature-off, or use staging?
3. **Version numbering.** What is the live App Store version and the highest uploaded build number (EAS remote counter)? The native build must exceed both.
4. **Minimum iOS 26** strands devices on iOS 16.4–25 on the last RN build. Confirm that is acceptable.
5. **Signing team.** Keychain continuity requires the same Team ID as the EAS-signed builds. Confirm.
6. ~~**Photo URIs** stored as absolute paths (`imageStore.ts:86`): resolve at read time or rewrite rows?~~ **Resolved by `02-device-storage-migration.md` §3.3**: resolve by file name at read time (`PhotoPathResolver`) and keep writing absolute `file://` URIs in the current container. Whether to *also* rewrite stale rows in that same format is optional and tracked as 02 Q4.
7. **Keychain unavailable at launch** (`errSecInteractionNotAllowed` while protected data is unavailable). RN reports no session, so the phone looks unpaired. Defer `ready` until protected data is available, or keep RN behavior?
8. **Telemetry vendor.** Keep a no-op release sink, which matches today and the privacy copy, or add one? Adding one requires a consent design and a `strings.privacy.diagnosticsBody` update.
9. **Dropped telemetry keys** `mode`, `reason`, `kept`, `unnamed` (`app/capture/index.tsx:285,289`, `app/capture/review.tsx:187`): extend the allowlist natively, or drop them at the call sites to match today's output?
10. `database_open_failed` and `household_shadow_failed` are sent as *events*, not errors. Keep that classification?
11. **Toast and revoked overlay above sheets**: approve the pass-through overlay `UIWindow` approach, and decide how bottom chrome heights (native `TabView` tab bar, bottom bars) reach `ToastCenter`.
12. **Focus definition for queries** in SwiftUI: does a presented sheet make the screen beneath "unfocused", as in RN, where it does? The navigation area must provide `ScreenFocus`.
13. **Sync exclusivity races.** In RN:
    - an automatic pass can run at the same time as `enable`'s first backup (two uploads);
    - `backupNow` takes no guard either, and a pass that finishes later resets its `error` to `idle`;
    - `restoreFromCode` sets the guard without waiting for an in-flight pass, whose `finally` then clears it early.

    Fix natively by running all four through `SyncCoordinator` (restore waits for an in-flight pass), or keep RN parity?
14. **Timeout parsing**: an empty or non-numeric value means 0 ms or NaN in RN, which aborts immediately. Adopt "invalid → default" natively?
15. **Background work**: add `BGAppRefreshTask` for backups? This would be new behavior and is out of scope by default.
16. **`com.wystudio.inventory` URL scheme** (Expo-added, unused by app code): keep for safety or drop?
17. **Launch screen and boot look** under the fully native style: system background with the brand mark?
18. **Brand accent**: tracked as `08-design-i18n-platform.md` Q3 (owner). Candidates: label-tape yellow (`#FFD23F` light / `#F4CA3C` dark, `src/ui/tokens.ts:40,77`), which fails text contrast as a tint, or ink (`#1C211E` / `#E8ECE8`, today's interactive tint). 08 recommends `AccentColor` = ink plus a named `Tape` colour.
19. **Deep link while onboarding is pending**: RN effectively drops it (the guarded route is unavailable). Keep, or queue it until onboarding completes?
20. `.env.local` could not be inspected in this session; confirm no extra keys exist beyond `.env.example`.
21. `NSAllowsLocalNetworking`: Debug only, or all configurations, as in the generated RN Info.plist? A Debug build that talks to a LAN dev server also needs `NSLocalNetworkUsageDescription` (Debug-only).
23. **Automatic pass clears a backup error** (§4.4): keep this RN behaviour, so the error banner vanishes on the next foreground, or keep `error` until a backup succeeds?
22. **Preferences backup scope**: AsyncStorage was excluded from iCloud backup and `UserDefaults` is included. Acceptable (e.g. the onboarding flag restores to a new device)?

---

## 16. Dependencies on other areas

| Area | What this area needs from it |
|---|---|
| Device storage migration (`02-device-storage-migration.md`) | **Owner** of the legacy AsyncStorage import (`LegacyImport`, §5.4), the Expo-compatible keychain (`ExpoCompatibleKeychain`, §4.3), `PhotoPathResolver` (§3.3), the generated-project settings the target must keep (§9) and the privacy manifest (§9.9). Boot step 2a calls `LegacyImport.runIfNeeded()`. |
| Persistence / schema / repositories (`01-data.md`) | Migration SQL v1–v7 and the user_version runner (§3), the repository APIs (`LocalRepositories`), snapshot and restore. Boot calls `DatabaseStore.open()` and `migrate()`. |
| Household (`04-household.md`: client, session, HTTP repositories, shadow, devices, import offer) | `HouseholdClient` with reachability reporting, `pairWithHousehold`, `HouseholdSession` JSON, `withLocalShadow`, `markJoinedBefore`, the `/v1/health` endpoint. |
| Sync / backup / account identity / photo sync (`03-sync-account.md`) | `SyncClient` (headers: `Authorization: Bearer <recovery code>`, `X-Contract-Version: 1`, optional `x-inventory-key`), `runBackup`, `maybeBackup`, `restoreBackup`, `syncPhotos`, account create, import and forget, `lastBackupAt`. |
| Recognition (`05-capture-ai.md`) | Endpoint, key and timeout config; `x-inventory-key` header; telemetry events. |
| Capture / image store (`05-capture-ai.md`) | Photo directory; URI resolution via `PhotoPathResolver` (02 §3.3, §15 Q6 resolved); free-space check (privacy manifest reason). |
| Navigation / IA (`06-screens-shell-home.md`, `07-screens-entities.md`) | Tab structure, route presentation (§2.5), `ScreenFocus` for queries, deep links `inventory://c/<token>` with Home underneath, dismiss-all for the revoked overlay, dirty guard on sheets (`SheetClose` behavior). |
| Onboarding screens | Call `OnboardingModel.complete()`; telemetry `onboarding_finished`. |
| Settings / Backup / Household / Privacy screens | Read `AppConfig` (environment, endpoints on/off, server host), `LATEST_SCHEMA_VERSION`, `SyncModel.status`, `HouseholdModel.session`, `ConnectionModel.state`. |
| Drop zone | `DropZoneModel` built on `InventoryQuery` (§4.8). |
| Theming / accessibility (`08-design-i18n-platform.md`) | Brand accent, reduce motion, VoiceOver announcements, the `stacked` threshold (`>= .xxxLarge` or width < 360). |
| Strings / i18n (`08-design-i18n-platform.md`) | String Catalog keys mirroring `src/i18n/strings.ts` paths used here: `boot.*`, `errors.*`, `connection.*`, `revoked.*`, `common.tryAgain`, `common.cancel`, `common.close`, `common.goBack`, `a11y.availableAction`, `a11y.dismissToast`, `a11y.searchHousehold`, `a11y.searchHint`, `settings.*`, `privacy.diagnostics*`. The `errors.*` copy must keep passing the raw-code test (§14.1). |
| Every screen that writes | Calls `DatabaseModel.invalidate()` after writes; uses `ToastCenter` and `describeError`. |

---

## Reviewer notes

An adversarial review re-read every source file in scope and the sibling specs `01-data.md` and `02-device-storage-migration.md`. Changes made in this file:

**Corrected (wrong in the previous draft)**
- §14.1: every `reachability.test.ts` citation was wrong (`:166-226`). The tests are at `:44-104`. Re-cited each one and sharpened the assertions.
- §3.2 step 4 and the §2.6 timeline: the connection subscription and the first sync pass were described as starting "once the gate passes". In RN both providers sit **above** `RootNavigator` (`app/_layout.tsx:231-242`), so they run regardless of onboarding status. Rewritten.
- §3.2 step 2a referred to non-existent steps "2c/2d". Now: before any `UserDefaults` read.
- §3.3: the legacy import contradicted the owning spec (`02` §5.4) in four ways:
  - the marker was a Bool; it is an Int (`1`);
  - it imported every manifest key; it imports only the 7 known keys;
  - it used a "first location that exists" order over four directories;
  - it had no rule for an unparsable or non-UTF-8 manifest.

  Aligned with 02, including removing `ExpoSystemUI.backgroundColor`.
- §3.1 photos and §15 Q6: the draft proposed resolving or rewriting rows. 02 §3.3 already decides: use `PhotoPathResolver`, keep writing absolute `file://` URIs, never rewrite.
- §2.4 retry: "the previous handle is leaked" was wrong. expo-sqlite returns its cached connection for the same path (`SQLiteModule.swift:107-111`).
- §4.3: the announcement fires on **every** transition into `offline`, on both platforms, not "once".
- §4.3 and TL;DR: the resume refresh "skips the first activation" was misleading. The first evaluation that passes the guard is usually the session load resolving. Session-key changes are evaluated too.
- §5: "only read mechanism, 19 call sites" corrected to 30 call sites in 19 files. Added `useSearch` (same revision rule) and `c/[token]` (deliberately one-shot).
- §8.1: the Join form shows `serverHost(appConfig.householdOrigin)`, not `session?.origin ?? …`. `serverHost` trims first.
- §8.6: `Constants.expoConfig.version` is not the only `expo-constants` use. `Constants.deviceName` is used for the default phone name (`JoinForm.tsx:93`).
- §8.5: iPhone orientations are Portrait **and** PortraitUpsideDown (generated `Info.plist:68-72`).
- §7.4: `ScreenFrame` usage counts corrected (`detail` 17 in 10 files, `modal` 10 in 7 files).
- §3.2 failure table: the "prewarmed launch" rationale for `errSecInteractionNotAllowed` was inaccurate (prewarm stops before `UIApplicationMain`). Rewritten around `WhenUnlocked` and the absence of background launches.

**Added (missing from the previous draft)**
- §2.1: the persisted id formats (lowercase v4 UUID layout, 32-hex QR token) and the `UUID().uuidString` upper-case trap.
- §3.1 keychain:
  - exact write semantics: add, then delete the legacy variants on success, update on duplicate;
  - delete semantics;
  - throw-on-unexpected-status;
  - UTF-8 decoding;
  - the session JSON shape and defaults.
- §2.3 and §4.4 sync lifecycle:
  - the account is only loaded when `syncEndpoint` is set;
  - the 16-byte code check and account-id derivation;
  - a completed automatic pass overwrites `error`/`working` with `idle`;
  - `backupNow` takes no guard;
  - restore does not wait for an in-flight pass;
  - `refresh()` is unused and unconditional;
  - `createAccount` throws propagate;
  - JS-`Number` parsing of `lastBackupAt`.
- §4.2: after pairing, every household request uses the server-returned `session.origin`, not `appConfig.householdOrigin`.
- §4.3:
  - rows for `ok` while revoked and for `offline` while not online;
  - `household_fetch_failed` on every failed ping;
  - the Home subtitle consumer.
- §4.6 toast details: the first id is `toast-1`; a mid-exit toast is replaced; VoiceOver doubling is not reapplied on resume; the action is disabled while leaving.
- §5: `cause` is `null` whenever a read did not fail. Screens branch on truthiness and pass `null` explicitly for "gone", which matters because native `nil` maps to `local`.
- §6: system alerts cause `inactive → active` (parity). Appearance and keyboard listeners noted.
- §8.3: household requests never send `x-inventory-key`; an unset secret disables the check on both backends.
- §8.5: device family and `UIRequiredDeviceCapabilities` must be kept; `NSLocalNetworkUsageDescription` for Debug LAN servers.
- §9.1: `console.log` vs `console.warn`, the RN `errorClass` value set, and a native rule (type name, never `localizedDescription`).
- §13.5: FK restore in `finally`; the first failure aborts boot; `user_version > 7` opens silently; bundled SQLite 3.50.3 vs system SQLite, with no SQL depending on the extras.
- §14: `id.test.ts`, the household `client.test.ts` error-type tests, and the full `backupSummary` mapping. The raw-code test constrains String Catalog copy. New Swift tests for keychain write and delete, the import aligned with 02, the migration runner, and the new sync and connection rows.
- §15: Q13 widened to all sync exclusivity races; new Q23 (automatic pass clears a backup error); Q21 extended.
- §0 and §16: sibling spec file names, with 02 marked as owner of the legacy import, keychain, photo resolver and target settings.

**Completeness / consistency pass (cross-spec critic)**
- §2.5 / §12: "inline titles" contradicted 06 §5.2 / §16.6 and 07 §0.11, which map RN's in-content large titles to system large titles. Now: large titles on tab roots and detail screens, inline on sheets and other pushes.
- §3.1 keychain and §14.2: the three-service read probe was stated as a MUST. The owner (02 §4.3) reads `app:no-auth` then `app` and skips the impossible `app:auth`; aligned.
- §3.1 photos, Q6 and the earlier reviewer note ("never rewrite"): 02 §3.3 makes read-time resolution mandatory but leaves the same-shape row rewrite optional (02 Q4). Corrected.
- §3.2, §4.1, §12, §13.4, §13.5: `DatabasePool` replaced by a single `DatabaseQueue`, the decision 01 §2.2 already made (single connection like RN; no checkpoint or restore interference; `synchronous = FULL` preserved). 02 and 03 aligned too.
- Q18: points at 08 Q3 as the single brand-accent decision.

**Verified unchanged:** the provider tree and gate precedence; `describeError` order and `isUnreachable`; the 23 allowlisted telemetry keys and the event catalogue payloads; toast timings (1500 / 5000 / 9000 / 2500 / 120 ms, 12 pt gap, 24 pt swipe); connection constants (10 s / 5 s / 5 s / 2.5 s); config parse rules and defaults; `eas.json` per-profile env; `app.json` values; the AsyncStorage manifest format and MD5 naming; the `useInventoryQuery` rules; `BottomBar` and `ScreenFrame` constants; all `errors.test.ts` rows.
