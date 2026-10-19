# 00 — Index: native iOS port of Inventory

This is the entry point to the porting specs in this folder. The specs describe how to rebuild the Expo / React Native app (Expo SDK 57, RN 0.86, expo-router, TypeScript, at commit `40c0616`) as a **native Swift 6 + SwiftUI app for iOS 26+**. The native app ships as an **App Store update** to the existing app: same bundle id `com.wystudio.inventory`, same Apple team. On first launch it must open and keep using the data the Expo build left on the device (SQLite database, photo files, keychain items, AsyncStorage values). Android and web stay on React Native. The backends (`server/` recognition on Vercel, `worker/` sync on Cloudflare, `home-server/` household hub) do not change, so the native app must speak their wire contracts exactly.

User decisions already made: replace in place (same bundle id); fully native look (system fonts, stock SwiftUI controls, Liquid Glass, only the brand accent colour kept); minimum iOS 26; Swift 6 strict concurrency; GRDB for SQLite with the schema preserved exactly.

**How to read the specs**
- Every behaviour cites `path:line` in the RN repo. User-facing copy is referenced by key in `src/i18n/strings.ts` (for example `strings.tabs.home`).
- Each source file has one **owner spec** (§3). Where two specs touch the same thing, the owner wins. The cross-spec decisions in §2 override any older wording.
- Each spec ends with **Reviewer notes**. The last block in each, "Completeness / consistency pass (cross-spec critic)", lists what this pass changed.

---

## 1. The nine specs

**`01-data.md` — data layer.** Owns the on-device SQLite database: its exact location (`Documents/SQLite/inventory.db` with `-wal`/`-shm`), the open pragmas, the seven verbatim migrations keyed on `PRAGMA user_version` (with the v7 rebuild that must toggle foreign keys outside any transaction), the byte-exact final `sqlite_master`, the seeded drop-zone rows, the domain types, and every repository's exact SQL (spaces, containers, items, QR bindings, search with `LIKE` and the nested-`REPLACE` compaction). It also owns the pure core logic (UUID/QR token formats, short codes, quantity rules, the Unicode tokenizer and folding with test vectors), place matching, recent places, category memory, and the app-wide invalidation model (`revision` + focus-driven re-reads) with `useSearch`, `useSavedQuantity` and `useMove`. It lists every repository and core test to port.

**`02-device-storage-migration.md` — in-place upgrade and target settings.** Owns every byte the Expo build persists and how native adopts it: the database path and the GRDB open recipe (a single `DatabaseQueue`), the photo files and the required `PhotoPathResolver` (stored URIs are absolute container paths that move), the household photo cache, the exact expo-secure-store keychain coordinates and the canonical `ExpoCompatibleKeychain` recipe, the legacy AsyncStorage v2 manifest format (with MD5 overflow files) and the one-time `LegacyImport` of the seven preference keys into `UserDefaults`, the first-launch adoption sequence gated on protected data, and the Xcode target settings an App Store update must keep (bundle id, team, version/build numbering, iPad family, `arm64` capability, Info.plist keys, URL schemes, entitlements, privacy manifest, xcconfig environments).

**`03-sync-account.md` — personal backup and the recovery-code account.** Owns the opt-in off-device backup against the Cloudflare Worker: the Crockford base32 recovery code (codec, display, typing normalisation, account-id derivation, test vectors), its keychain lifecycle, the Worker contract v1 (headers, endpoints, status classification, limits, retention), whole-database snapshot and restore (checkpoint + serialize, backup API + `migrate`, newer-schema refusal), the photo upload/delete/rehydrate queue that lives in the schema, the sync engine's status, triggers and concurrency, and the Backup screen. It catalogues 14 known RN bugs (B1–B14) with parity-vs-fix recommendations.

**`04-household.md` — household sharing via the home server.** Owns the household model (bootstrap code, pairing, bearer tokens, devices), the full HTTP contract of `home-server/` (request rules, response parsing, error codes, every endpoint, JSON shapes, absent-vs-`null` tri-state patches), the reachability side channel, session persistence, the HTTP repositories and photo hydration, the local shadow mirror with its exact UPSERT SQL, the household photo cache, the connection state machine (`local/online/unsure/offline/revoked`, health ping, resume refresh), the one-time copy of a phone's own inventory into the household, and the Household screen and join form.

**`05-capture-ai.md` — camera, Quick Snap, photos and recognition.** Owns the capture screen (single, request and fast modes, library import, permission gate), the Quick Snap pipeline and live review, camera configuration (the expo-camera patch mapped to AVFoundation, tap-to-focus), image processing and storage (scale-to-fit 1400/320, WebP q0.8/q0.7, EXIF stripped, file naming), the recognition wire contract and response validation, how suggestions fill the Add form, inline naming, the photo viewer, thumbnails and camera permissions. It opens with critical findings: absolute photo URIs (C1), WebP labelled as JPEG to recognition (C2, likely a live production bug), WebP needs libwebp (C3), preview-aspect cropping (C4), and a probable AVFoundation exception from the patched quality setting (C5).

**`06-screens-shell-home.md` — navigation shell and the tab screens.** Owns the route map and presentation of every route, navigation helpers and route results, the one-shot search-focus request, deep links (`inventory://c/<token>`), the tab bar (including the Add action and Quick Snap long-press), Home (overview, search model, results, quantity chips, announcements), Spaces, Drop zone, Scan and the `/c/<token>` label screen, the Add sheet's `src/ui/add` logic (initial state, where-list, draft, save, photo and recognition state machine), Onboarding, Settings, Privacy, toasts, and the mapping of shared RN components to stock SwiftUI, with accessibility and haptics catalogues for these screens.

**`07-screens-entities.md` — item, container and space screens.** Owns the entity screens and forms (Add item, item detail with filing runs, edit, move/file with Undo, new/detail/edit container, QR label, link a printed sticker, new/detail/edit space), their pure logic (item form validation, item details, move flow, container rules, space setup), the shared pickers, steppers (`QuantityStepper`, write-through `SavedQuantityStepper`), place picker, text and code inputs, dirty guards, and QR label payload, on-screen card, share picture and binding rules.

**`08-design-i18n-platform.md` — copy, formatting, brand, icons, haptics, motion, accessibility.** Owns the port of `strings.ts` to a String Catalog (key mapping, characters that must survive, all 157 function-valued strings), `format.ts` (`plural`, `sentenceList`, `ago`, `longDate`), the brand colours and the data-bearing colours, emoji and container types stored in the database, the glyph → SF Symbol table, typography under system fonts, the haptic events and call sites, motion and timing constants with Reduce Motion semantics, accessibility conventions, and the primitive components' behaviour.

**`09-app-shell-lifecycle-config.md` — boot, providers, lifecycle, config, telemetry, errors.** Owns the boot sequence and gate precedence (database error first, then database/onboarding/session loading), the native boot order (legacy import before any `UserDefaults` read), the provider → `@MainActor @Observable` model mapping (database + revision, household, connection, sync, onboarding, toasts, drop zone), the exact `useInventoryQuery` semantics, foreground/background handling, shell components (boot views, error state, screen frame, connection banner, revoked overlay, overlay window, bottom bar), build configuration (`AppConfig`, xcconfig design, the `x-inventory-key` app secret), telemetry (allowlist redactor, event catalogue), `describeError` and the error taxonomy, logging rules, and a proposed module layout and concurrency model.

---

## 2. Cross-spec decisions (canonical)

These were inconsistent between specs before this pass. They are now the same everywhere.

| # | Decision | Canonical section |
|---|---|---|
| D-1 | One GRDB **`DatabaseQueue`** (single connection, like RN), not a `DatabasePool`. `journal_mode = WAL`, `foreign_keys = ON`, `synchronous = FULL` on open. | 01 §2.2, 02 §2.3 |
| D-2 | `PRAGMA user_version` runner with the seven migrations verbatim. Never GRDB `DatabaseMigrator`, never extra tables. FK toggle for v7 outside any transaction. | 01 §3, 02 §2.3 rule 6 |
| D-3 | One keychain wrapper, `ExpoCompatibleKeychain`: generic password, service `app:no-auth`, account **and** generic = `Data(key.utf8)`, `WhenUnlocked`, no access group; read `app:no-auth` then legacy `app`; add-then-update on duplicate; delete all three services. | 02 §4.3 |
| D-4 | One photo resolver, `PhotoPathResolver`: resolve stored `file://` URIs by file name under the current `Documents/item-photos/` or `Caches/household-photos/`; `r2:`/http → not local. Native writes keep the absolute shape-1 URI. Row rewrite ("self-heal") optional (open, §5). | 02 §3.3 |
| D-5 | One AsyncStorage importer, `LegacyImport`: copy the seven keys **verbatim as strings** under the same names into `UserDefaults`, Int marker `native.legacyImport.v1`, only when protected data is available, never overwrite, leave the RN directory in place. Readers parse on read with the RN rules. `sync.lastBackupAt.v1` stays a string. | 02 §5.3-5.4 |
| D-6 | Reactivity: keep the global `revision` + focus-driven re-read model (`InventoryQuery`) for both local and paired (HTTP) reads. No GRDB `ValueObservation` by default. | 01 §9.1, 09 §5 |
| D-7 | Network deadlines are **total wall-clock** (upload + server + full body), because RN `fetch` resolves only after the body is buffered. One shared `withTotalTimeout` helper for household (20 s default), sync (60 s) and recognition (15 s). | 03 §4.1, 04 §3.1, 09 §8.4 |
| D-8 | Toasts and the removed-phone layer render in one pass-through overlay `UIWindow` above sheets. | 09 §7.6-7.7, 06 §2.2 |
| D-9 | Large titles on tab roots and on space/container/item detail screens (RN drew them in content); inline titles elsewhere. | 06 §5.2, §16.6; 07 §0.11; 09 §2.5 |
| D-10 | Keep `NSPhotoLibraryUsageDescription` (the label share sheet offers Save Image). Keep the `inventory` URL scheme forever. | 02 §9.4, §9.6 |
| D-11 | `parseQuantityInput` has one owner (01 §6.4, Q4); 07 defers to it. | 01 §6.4 |

### 2.1 Persisted artefacts and their owners (quick reference)

| Artefact | Location / key | Format | Owner |
|---|---|---|---|
| Inventory database | `Documents/SQLite/inventory.db` (+ `-wal`, `-shm`) | SQLite, WAL, `user_version` 0–7 | 01 (path and adoption: 02) |
| Item photos | `Documents/item-photos/<uuid>.webp`, `<uuid>-thumb.webp`, legacy `.jpg` | absolute `file://` URIs in `item_photos.uri/thumb_uri` | 05 (adoption: 02 §3) |
| Household photo cache | `Library/Caches/household-photos/<photoId>[-thumb].webp` | bytes | 04 §8 |
| Recovery code | keychain `sync.accountSecret.v1` | 26-char Crockford base32 | 03 §3.7 (coordinates: 02 §4) |
| Household session | keychain `household.session.v1` | JSON `{origin, token, deviceId, deviceName, householdName}` | 04 §5 (coordinates: 02 §4) |
| `onboarding.completed.v1` | AsyncStorage → `UserDefaults` | `"true"` or absent | 06 §11.1 |
| `places.recent.v1` | same | JSON `string[]`, ≤ 6, never `drop-zone` | 01 §8.2 |
| `categories.recent.v1` | same (may be in an MD5 overflow file) | JSON `string[]`, ≤ 20 | 01 §8.3 |
| `notice.unpaired.dismissed.v1` | same | `"1"` | 04 §12.8 / 06 §5.5 |
| `sync.lastBackupAt.v1` | same | integer ms as a string (server time) | 03 §5.3 |
| `household.importOffer.v1` | same | `{"spaces":n,"items":n}` | 04 §11.1 |
| `household.joinedBefore.v1` | same | `"true"` | 04 §11.1 |
| `ExpoSystemUI.backgroundColor` | standard `UserDefaults` | Int | removed by the import (02 §6) |
| Temporary caches | `Library/Caches/{ImageManipulator,Camera,ImagePicker}/`, `label-*.png` | disposable | 02 §3.5 |

---

## 3. Coverage: source file → spec

Scope: every non-test file under `app/` and `src/` (179 files), excluding `__tests__`, `src/testing`, `src/db/nodeDatabase.ts` and `src/db/testing`. Method: each file's path (or, for components cited by file name, its file name) was searched in all nine specs, and every exported function, constant, class, type and enum was checked for a mention. Result: **every file is covered by at least one spec**, and every exported symbol is referenced except screen component default-export names, the React-only `FontContext`/`useBoldText`/`useFontsReady` (font loading is dropped), the `GLYPHS`/`IconName` table (mapped glyph by glyph in 08 §5), `labelImage.ts`'s `QrSvg`/`writeLabelPicture` (behaviour in 07 §5.3), and the TypeScript input/impact type names in `src/repositories/{spaces,containers}.ts` (their fields are specified in 01 §7.1-7.2). No file needed new behaviour added in this pass. "Owner" is the spec that specifies the behaviour; "also" lists other specs that cite the file.

| Source file | Owner spec | Also specified in | Note |
|---|---|---|---|
| `app/(tabs)/_layout.tsx` | 06 | 09 |  |
| `app/(tabs)/drop-zone.tsx` | 06 | 05, 08 |  |
| `app/(tabs)/index.tsx` | 06 | 01, 02, 04, 05, 08, 09 |  |
| `app/(tabs)/scan.tsx` | 06 | 04, 07, 08, 09 |  |
| `app/(tabs)/spaces.tsx` | 06 | 04 |  |
| `app/_layout.tsx` | 09 | 01, 02, 03, 04, 05, 06, 07, 08 |  |
| `app/backup.tsx` | 03 | 02, 04, 06, 08, 09 |  |
| `app/c/[token].tsx` | 06 | 01, 02, 07, 08, 09 |  |
| `app/capture/index.tsx` | 05 | 01, 02, 06, 07, 08, 09 |  |
| `app/capture/review.tsx` | 05 | 01, 02, 04, 06, 08, 09 |  |
| `app/container/[id]/edit.tsx` | 07 | 01, 02, 05, 06, 08, 09 |  |
| `app/container/[id]/index.tsx` | 07 | 01, 05, 06, 08 |  |
| `app/container/[id]/link.tsx` | 07 | 01, 06, 08, 09 |  |
| `app/container/[id]/qr.tsx` | 07 | 01, 02, 06, 08, 09 |  |
| `app/container/new.tsx` | 07 | 01, 06, 08, 09 |  |
| `app/household.tsx` | 04 | 01, 02, 06, 08, 09 |  |
| `app/item/[id]/edit.tsx` | 07 | 01, 02, 05, 06, 08, 09 |  |
| `app/item/[id]/index.tsx` | 07 | 01, 02, 04, 05, 06, 08, 09 |  |
| `app/item/[id]/move.tsx` | 07 | 06 |  |
| `app/item/[id]/photo.tsx` | 05 | 02, 06, 08 |  |
| `app/item/new.tsx` | 07 | 01, 02, 04, 05, 06, 08, 09 |  |
| `app/onboarding.tsx` | 06 | 02, 04, 08, 09 |  |
| `app/privacy.tsx` | 06 | 04, 05, 08, 09 |  |
| `app/settings.tsx` | 06 | 02, 03, 04, 08, 09 |  |
| `app/space/[id]/edit.tsx` | 07 | 01, 02, 05, 06, 08, 09 |  |
| `app/space/[id]/index.tsx` | 07 | 06, 08 |  |
| `app/space/new.tsx` | 07 | 01, 06, 08, 09 |  |
| `src/core/bytes.ts` | 01 | 03, 05, 06, 07, 09 |  |
| `src/core/conflict.ts` | 01 | 04, 09 |  |
| `src/core/id.ts` | 01 | 02, 03, 04, 05, 06, 07, 09 |  |
| `src/core/quantity.ts` | 01 | 07, 08 |  |
| `src/core/shortCode.ts` | 01 | 07, 08 |  |
| `src/core/tokenize.ts` | 01 | 07 |  |
| `src/db/constants.ts` | 01 | 04, 05, 06, 07, 08 |  |
| `src/db/expoDatabase.ts` | 01 | 02, 03, 04, 09 |  |
| `src/db/migrations.ts` | 01 | 02, 03, 04, 05, 06, 07, 08, 09 |  |
| `src/db/repositories.ts` | 01 | 02, 09 |  |
| `src/db/types.ts` | 01 | 03, 04, 07, 08, 09 |  |
| `src/hooks/useCollapsingTitle.ts` | 06 | 07 |  |
| `src/hooks/useDelayedFlag.ts` | 09 | 05, 06, 08 |  |
| `src/hooks/useDirtyGuard.ts` | 07 | 04, 09 |  |
| `src/hooks/useInventoryQuery.ts` | 09 | 01, 04, 05, 06, 07 |  |
| `src/hooks/useKeyboardInset.ts` | 09 | 07 | not ported (SwiftUI keyboard avoidance) |
| `src/hooks/useLayoutScale.ts` | 09 | 06, 08 |  |
| `src/hooks/useMove.ts` | 01 | 02, 07, 08, 09 |  |
| `src/hooks/useNow.ts` | 08 | 03, 04, 06, 09 |  |
| `src/hooks/useRecentPlaces.ts` | 01 | 06, 07 |  |
| `src/hooks/useSavedQuantity.ts` | 07 | 01, 08, 09 |  |
| `src/hooks/useSearch.ts` | 01 | 06, 08, 09 |  |
| `src/hooks/useSheetKeyboardOffset.ts` | 07 | — | not ported (RN layout workaround) |
| `src/hooks/useSpreadGap.ts` | 08 | 07 |  |
| `src/i18n/format.ts` | 08 | 03, 04, 06, 07 |  |
| `src/i18n/strings.ts` | 08 | 01, 03, 04, 05, 06, 07, 09 | String Catalog; every spec references keys |
| `src/providers/ConnectionProvider.tsx` | 04 | 01, 02, 08, 09 |  |
| `src/providers/DatabaseProvider.tsx` | 09 | 01, 02, 03, 04, 05 |  |
| `src/providers/DropZoneProvider.tsx` | 06 | 01, 09 |  |
| `src/providers/FontProvider.tsx` | 09 | 02, 08 | dropped (system fonts) |
| `src/providers/HouseholdProvider.tsx` | 04 | 02, 09 |  |
| `src/providers/OnboardingProvider.tsx` | 06 | 02, 09 |  |
| `src/providers/SyncProvider.tsx` | 03 | 01, 02, 09 |  |
| `src/providers/ToastProvider.tsx` | 09 | 06, 08 |  |
| `src/repositories/containers.ts` | 01 | 04, 06, 07 |  |
| `src/repositories/items.ts` | 01 | 02, 03, 04, 05, 06, 07 |  |
| `src/repositories/qr.ts` | 01 | 02, 04, 06, 07, 08, 09 |  |
| `src/repositories/search.ts` | 01 | 04, 06 |  |
| `src/repositories/spaces.ts` | 01 | 04, 06, 07 |  |
| `src/services/account/base32.ts` | 03 | 02, 04 |  |
| `src/services/account/identity.ts` | 03 | 02, 09 |  |
| `src/services/ai/contract.ts` | 05 | 06, 09 |  |
| `src/services/ai/recognition.ts` | 05 | 02, 09 |  |
| `src/services/appInfo.ts` | 09 | 02, 06 |  |
| `src/services/capture/fastCapture.ts` | 05 | 01 |  |
| `src/services/capture/fastReview.ts` | 05 | — |  |
| `src/services/capture/imageScaling.ts` | 05 | 02, 03, 06, 08 |  |
| `src/services/capture/imageStore.ts` | 05 | 01, 02, 03, 04, 07, 09 |  |
| `src/services/config.ts` | 09 | 02, 03, 04, 05, 06 |  |
| `src/services/household/client.ts` | 04 | 01, 02, 07, 08, 09 |  |
| `src/services/household/collectDump.ts` | 04 | 01 |  |
| `src/services/household/devices.ts` | 04 | 02 |  |
| `src/services/household/dump.ts` | 04 | — |  |
| `src/services/household/httpRepositories.ts` | 04 | 01, 02, 03, 05, 06, 07 |  |
| `src/services/household/importHousehold.ts` | 04 | 02, 03, 09 |  |
| `src/services/household/importOffer.ts` | 04 | 02, 09 |  |
| `src/services/household/photoCache.ts` | 04 | 02, 03, 05, 09 |  |
| `src/services/household/session.ts` | 04 | 02, 06, 08 |  |
| `src/services/household/shadow.ts` | 04 | 01, 02, 03, 05, 09 |  |
| `src/services/onboarding.ts` | 06 | 02, 04, 08, 09 |  |
| `src/services/places/recentPlaces.ts` | 01 | 02, 06, 07, 09 |  |
| `src/services/sync/backup.ts` | 03 | 01, 02, 09 |  |
| `src/services/sync/client.ts` | 03 | 04, 09 |  |
| `src/services/sync/contract.ts` | 03 | 02, 09 |  |
| `src/services/sync/photoSync.ts` | 03 | 01, 02, 05, 09 |  |
| `src/services/telemetry/index.ts` | 09 | 02, 03, 05, 06, 07 |  |
| `src/ui/a11y.ts` | 08 | 03, 05, 06, 07 |  |
| `src/ui/add/WhereList.tsx` | 06 | 07, 08 |  |
| `src/ui/add/addDraft.ts` | 06 | 02, 05, 07 | also 07 §2.8 |
| `src/ui/add/addSheet.ts` | 06 | 05, 07 |  |
| `src/ui/capture/CameraChrome.tsx` | 05 | 08 |  |
| `src/ui/capture/captureFlow.ts` | 05 | 06, 08 |  |
| `src/ui/categoryMemory.ts` | 01 | 02, 06, 07, 09 |  |
| `src/ui/code.ts` | 03 | 04, 07, 08 |  |
| `src/ui/color.ts` | 08 | 06, 07 |  |
| `src/ui/components/AppText.tsx` | 08 | 06 |  |
| `src/ui/components/Banner.tsx` | 06 | 01, 02, 04, 05, 07, 08, 09 |  |
| `src/ui/components/BootScreen.tsx` | 09 | 02, 06, 08 |  |
| `src/ui/components/BottomBar.tsx` | 09 | — |  |
| `src/ui/components/Button.tsx` | 08 | — |  |
| `src/ui/components/CameraPermission.tsx` | 05 | 04, 06, 08, 09 |  |
| `src/ui/components/CodeInput.tsx` | 07 | 03, 04, 08 |  |
| `src/ui/components/ConnectionBanner.tsx` | 04 | 01, 02, 06, 08, 09 |  |
| `src/ui/components/EmptyState.tsx` | 06 | — |  |
| `src/ui/components/ErrorState.tsx` | 09 | 06, 08 |  |
| `src/ui/components/Icon.tsx` | 08 | — |  |
| `src/ui/components/IconButton.tsx` | 08 | — |  |
| `src/ui/components/ItemForm.tsx` | 07 | 01, 05, 06 |  |
| `src/ui/components/ItemRow.tsx` | 06 | 02, 05, 07, 08 |  |
| `src/ui/components/LocationLine.tsx` | 07 | 06, 08 |  |
| `src/ui/components/Mark.tsx` | 08 | 07, 09 |  |
| `src/ui/components/PlacePicker.tsx` | 07 | 06, 08 |  |
| `src/ui/components/PlaceRows.tsx` | 07 | 06, 08 |  |
| `src/ui/components/PressFeedback.tsx` | 08 | — | dropped (native button styles) |
| `src/ui/components/QrScanner.tsx` | 06 | 07, 08 |  |
| `src/ui/components/QuantityChip.tsx` | 07 | 06, 08 |  |
| `src/ui/components/QuantityStepper.tsx` | 07 | 01, 08 |  |
| `src/ui/components/Row.tsx` | 06 | 08 |  |
| `src/ui/components/SavedQuantityStepper.tsx` | 07 | — |  |
| `src/ui/components/ScreenFrame.tsx` | 09 | 04, 06 |  |
| `src/ui/components/SearchField.tsx` | 06 | 08 |  |
| `src/ui/components/SettingsRow.tsx` | 06 | 08 |  |
| `src/ui/components/Sheet.tsx` | 06 | — |  |
| `src/ui/components/Skeleton.tsx` | 06 | 08 |  |
| `src/ui/components/SpacePip.tsx` | 06 | 08 |  |
| `src/ui/components/SpaceTile.tsx` | 06 | 07, 08 |  |
| `src/ui/components/StatusPill.tsx` | 06 | — |  |
| `src/ui/components/SuggestionBanner.tsx` | 05 | 06, 07, 08 |  |
| `src/ui/components/TabBar.tsx` | 06 | 05, 08 |  |
| `src/ui/components/TapToFocusLayer.tsx` | 05 | 08 |  |
| `src/ui/components/Tape.tsx` | 07 | 08 |  |
| `src/ui/components/TextField.tsx` | 07 | 08 |  |
| `src/ui/components/Thumb.tsx` | 05 | 02, 08 |  |
| `src/ui/components/Toast.tsx` | 09 | 04, 06, 08 |  |
| `src/ui/components/pickers/Chip.tsx` | 07 | — |  |
| `src/ui/components/pickers/ChoiceList.tsx` | 07 | 08 |  |
| `src/ui/components/pickers/EmojiPicker.tsx` | 07 | 08 |  |
| `src/ui/components/pickers/SegmentedControl.tsx` | 07 | 08 |  |
| `src/ui/components/pickers/SwatchPicker.tsx` | 07 | 08 |  |
| `src/ui/components/pickers/TypeGrid.tsx` | 07 | 08 |  |
| `src/ui/confirm.ts` | 07 | 03, 04, 06 |  |
| `src/ui/container/QrCard.tsx` | 07 | — |  |
| `src/ui/container/containerRules.ts` | 07 | 08 |  |
| `src/ui/container/labelImage.ts` | 07 | 02, 09 |  |
| `src/ui/errors.ts` | 09 | 01, 04, 05, 06, 07, 08 |  |
| `src/ui/fontContext.ts` | 09 | 08 | dropped (system fonts) |
| `src/ui/haptics.ts` | 08 | 05, 06, 07 |  |
| `src/ui/home/DropZoneCard.tsx` | 06 | 05, 08 |  |
| `src/ui/home/TotalLine.tsx` | 06 | 08 |  |
| `src/ui/home/homeList.ts` | 06 | 01 |  |
| `src/ui/home/unpairedNotice.ts` | 06 | 02, 04, 09 |  |
| `src/ui/household/JoinForm.tsx` | 04 | 01, 02, 08, 09 |  |
| `src/ui/household/join.ts` | 04 | 03, 06, 08, 09 |  |
| `src/ui/household/status.ts` | 04 | 03, 06, 08, 09 |  |
| `src/ui/icons/glyphs.tsx` | 08 | 07 |  |
| `src/ui/item/NameItInline.tsx` | 05 | 01, 07, 08, 09 |  |
| `src/ui/item/WhereCard.tsx` | 07 | 08 |  |
| `src/ui/item/itemDetails.ts` | 07 | 05, 08 |  |
| `src/ui/item/moveFlow.ts` | 07 | 01 |  |
| `src/ui/motion.ts` | 08 | 01, 04, 05, 06, 07, 09 |  |
| `src/ui/navigation.ts` | 06 | 05, 07 |  |
| `src/ui/placeMatch.ts` | 01 | 06, 07, 08 |  |
| `src/ui/routeResult.ts` | 06 | 05, 07 |  |
| `src/ui/scan/scanRules.ts` | 06 | 07 |  |
| `src/ui/searchFocus.ts` | 06 | — |  |
| `src/ui/spaces/FormLayout.tsx` | 07 | 06 |  |
| `src/ui/spaces/SpaceFields.tsx` | 07 | — |  |
| `src/ui/spaces/spaceSetup.ts` | 07 | 08 |  |
| `src/ui/spaces/usePullToRefresh.tsx` | 06 | 07 |  |
| `src/ui/theme.ts` | 08 | 07, 09 |  |
| `src/ui/tokens.ts` | 08 | 02, 05, 06, 09 |  |
| `src/ui/typography.ts` | 08 | — | scale mapped to Dynamic Type; font switching dropped |

---

## 4. Open questions that need the user's decision

Consolidated from every spec's open-question list. Each has a recommended default so work can start; the implementation should not ship the affected milestone until the user has confirmed or overridden it.

| # | Question | Recommended default | Source |
|---|---|---|---|
| U1 | **Release, signing and secrets.** What is live (App Store or TestFlight only; version and highest build number on the EAS remote counter)? Who builds and signs native (EAS, Xcode Cloud, fastlane), under the **same Team ID**? Where do the production `x-inventory-key` values for recognition and sync come from (they are not in `eas.json`; EAS environment variables?), and are they the same value? What should the Preview configuration point at? | Same team (mandatory). Xcode Cloud or fastlane with `Secrets.xcconfig` written from CI secrets; first build number above the EAS counter; Preview = production endpoints. | 02 Q1, Q2, Q16; 09 Q1-Q3, Q5, Q20; 03 Q1; 05 Q11 |
| U2 | **Which colour is "the brand accent"**: ink (`#1C211E` / `#E8ECE8`, today's interactive tint) or tape yellow (`#FFD23F` / `#F4CA3C`)? Also: keep the Drop zone badge yellow, keep the yellow code tape? | `AccentColor` = ink; named `Tape` colour for the code tape, mark, badge and camera accent (yellow fails contrast as a tint). | 08 Q3; 06 Q7; 07 Q8; 09 Q18 |
| U3 | **App icon and launch look.** The shipped icon is the stock Expo placeholder. Real artwork, as a Liquid Glass `.icon`? Launch screen plain system background or with the mark? | Ship real artwork if available; plain system-background launch screen. | 02 Q8; 08 Q7; 09 Q17 |
| U4 | **iPad.** The update cannot drop iPad (App Store rule). Which iPad layout (sidebar-adaptable tabs, 640 pt column), and capture orientation on iPad? | `TabView` with `.sidebarAdaptable`; 640 pt readable column; lock capture to portrait. | 02 Q14; 06 Q12; 05 Q16 |
| U5 | **Navigation IA under the native look.** Add action and its Quick Snap long-press (intercepted middle tab, `tabViewBottomAccessory`, or toolbar `+`); tab bar visible on pushed screens (per-tab stacks) vs hidden as in RN; keep search on Home vs `Tab(role: .search)`; Save in a bottom bar vs toolbar; which deep links (only `c/<token>` vs every route) and whether to queue one that arrives during onboarding; "How it works" replay landing. | Intercepted middle tab + Home Screen quick action for Quick Snap; per-tab stacks; search stays on Home; bottom bar kept for primary actions; only `inventory://c/<token>`, queued until onboarding completes. | 06 Q1-Q4, Q13; 07 Q3, Q4; 09 Q19 |
| U6 | **Policy for known RN bugs: parity or fix.** Recommended policy: fix anything that loses data, blocks a queue or double-writes; keep visible UX parity otherwise. Items needing an explicit answer: B12 reinstall with a surviving recovery code uploads an empty database over real backups (offer restore?); sync exclusivity races (double backup on enable, restore not waiting); photo queue B1 (only 10 newest ever rehydrated), B2 (one bad photo blocks uploads forever), B3 (decode throw aborts backups); B8 (unreadable keychain then Turn on/Restore destroys the code); B11 (failed migrate after restore swap); recognition `image/jpeg` label on WebP bytes (likely broken in production today; also fix RN); Quick Snap "Keep shooting" resets the expected count; automatic pass silently clears a backup error. | Fix all listed items; keep copy and timing parity. Fix recognition media type in RN too. | 03 Q2, Q5, B1-B3, B6, B8, B11, B12; 09 Q13, Q23; 05 Q1, Q4, Q17 |
| U7 | **Camera behaviour.** Keep expo-camera's crop to the preview aspect (WYSIWYG, about 646×1400) or store uncropped 4:3 stills (1050×1400)? Focus style (literal continuous AF at the point vs AVCam one-shot + subject-area reset)? Zero shutter lag off (quality) or on for bursts? Add pinch zoom / Camera Control shutter? | Keep the crop (stored photos stay comparable); AVCam-style focus; ZSL off; no extras in v1. | 05 Q2, Q3, Q5, Q8 |
| U8 | **Preferences in device backups.** `UserDefaults` is in iCloud/Finder backups; the RN AsyncStorage directory was excluded. Accept (onboarding flag, recent places, `lastBackupAt` survive a device restore) or keep strict parity with an excluded file? | Accept `UserDefaults`. | 02 Q3; 09 Q22 |
| U9 | **Copy and locale.** Generate the String Catalog from `strings.ts` (shared with Android/web) with a CI check, or fork? Pin en-GB dates and lists ("2 September 2026", no serial comma) or follow the device locale? Localise preset space names and the `'Home'` / `'This phone'` fallbacks? Move the hard-coded English search subtitles into strings? | Generate from `strings.ts`; pin en-GB; keep literals as today; move search subtitles to strings with the same format. | 08 Q1, Q2, Q4, Q11; 01 Q2 |
| U10 | **New behaviour (scope).** Background backups (`BGTaskScheduler`; would also need `AfterFirstUnlock` keychain items); a telemetry vendor (requires changing `strings.privacy.diagnosticsBody` and the privacy label); SSE live updates from the home server; replacing an existing item's photo; "Copy" for the recovery code; a whole-card share picture or a direct Print button; longer timeouts for 32 MiB snapshots. | None in v1 (parity). | 09 Q8, Q15; 03 Q4, Q6, Q9; 02 Q10; 04 Q6; 05 Q9; 07 Q7 |
| U11 | **File cleanup.** Sweep unreferenced files in `Documents/item-photos/` (lost drafts, paired captures, pre-restore files)? When to delete the RN AsyncStorage directory? | Purge only `Caches/{ImageManipulator,Camera,ImagePicker}` and `label-*.png` on first launch; no `item-photos` sweep in v1; delete the RN directory one release after GA. | 02 Q5, Q6; 05 Q15; 03 Q12; 04 Q14 |
| U12 | **Cross-platform data semantics** (need Android and server changes, so not native-only): fix one-sided accent folding in search (needs a v8 migration on every platform); fix household import UNIQUE collisions server-side; `strings.household.leaveBody` promises more than the shadow keeps; mirror tags on shadowed updates; exclude shadow photos from personal sync. | Parity for v1; track as backlog. Native must not ship a schema version Android and the home server have not shipped. | 01 Q1; 04 Q2, Q4, Q15; 03 Q11 |

---

## 5. Questions the implementer can resolve from source

No user input needed; the default below follows from source behaviour or from the native-look decision. Revisit only if the user objects.

- **Database:** `DatabaseQueue` (D-1). Verify on device that `LOWER()`/`LIKE` fold ASCII only on the system SQLite; bundle SQLite only if not (01 Q7, §2.1). Use `VACUUM INTO` if `sqlite3_serialize` is not exported by the SDK (02 Q12). Force `synchronous = FULL` (02 Q11). `user_version > 7` opens silently (01 Q3). `containers.create` keeps "retry on any constraint" (01 Q5). Tag order stays by tag id (01 Q9). The `useSavedQuantity` retry quirk is kept (01 Q8). No new repository guards (01 Q11; the home server runs the TS repositories).
- **Text:** use Foundation case mapping plus a shared Node/Swift vector file; treat any mismatch as a bug (01 Q10). `parseQuantityInput` accepts the pinned vectors plus JS integer forms such as `"1.0"` (01 Q4, 07 Q1).
- **Config:** empty, non-numeric or ≤ 0 timeouts fall back to the defaults (09 Q14). Keep the `com.wystudio.inventory` URL scheme (harmless); `NSAllowsLocalNetworking` in Debug only (02 Q7; 09 Q16, Q21).
- **Errors and telemetry:** map `URLError.timedOut` to `offline` (RN parity; 03 Q7). Strictly decode the backup 201 body and return `malformed_response` on mismatch (03 Q8). Keep the allowlist as is, so `mode`/`reason`/`kept`/`unnamed` stay dropped, and keep `database_open_failed` / `household_shadow_failed` as events (09 Q9, Q10).
- **Shell:** overlay `UIWindow` for toasts and the revoked layer (D-8; 09 Q11, 06 Q5). A screen under a presented sheet counts as unfocused, as in RN (09 Q12). Do not set the household session or sync account to "absent" while protected data is unavailable; wait for `protectedDataDidBecomeAvailable` (09 Q7, 02 Q17, 04 Q11).
- **Photos:** resolve at read time; self-heal rows only if cheap (02 Q4, 05 Q10, 01 Q6). Serialise image processing in one actor and cap in-flight recognitions (05 Q7). Send the photo upload `Content-Type` from magic bytes, which both servers allowlist (03 Q3, together with U6).
- **Screens (native look):** stock `ContentUnavailableView` empty states (06 Q6); no search spinner (06 Q9); keep the inline quantity-chip stepper (06 Q10); keep the in-tab Scan code phase (06 Q11); system large titles (07 Q9, D-9); unify container labels on `labelOf` (07 Q10); SF Symbols per 08 §5 (07 Q11, 08 Q6, Q12); explicit index tie-breaks wherever JS relied on stable sort (07 Q12); exact 400 ms / 80 ms hold-repeat (07 Q2); QR quiet zone parity (07 Q6); the review keeps swipe-back without `fast_review_done` (05 Q13); review rows appear when their pipeline settles (05 Q14, D-6).
- **Household and sync parity:** ignore `contractVersion` (04 Q1); keep the HTTP repository quirks (04 Q5); best-effort revoke on leave (04 Q9); `unsure` shown only on the Household card (04 Q10); no LAN discovery (04 Q12); no device rename (04 Q13); batch size 10 per direction (03 Q10, unless the B1 fix changes it).

---

## 6. Top porting risks (ranked)

| Rank | Risk | Consequence | Mitigation | Specs |
|---|---|---|---|---|
| 1 | The v7 migration toggles `PRAGMA foreign_keys` inside a transaction (for example inside GRDB `write {}`). | On every device still at `user_version` ≤ 6, `DROP TABLE items` cascades and **deletes all photo and tag rows**. | Runner in `writeWithoutTransaction`, pragma outside, migration in its own transaction. A v6 fixture test with a photo and a tag must pass before any TestFlight build. | 01 §3.1; 02 §2.3 rule 6, §11.2 #8 |
| 2 | Photo URIs are absolute container paths; the container can move on update or restore. | The first sync pass (which runs at launch, even before onboarding) **deletes the row of every not-yet-uploaded photo** whose file it cannot find. Thumbnails go blank. | `PhotoPathResolver` in `readStoredPhoto`, display, delete, import and upload from the first native build that can run a sync pass. Test the uploader against a stale-UUID fixture. | 02 §3.3; 05 C1; 03 B4 |
| 3 | Keychain coordinates differ from expo-secure-store (account as `String` instead of `Data`, wrong service, different Team ID), or items are read before first unlock. | The household session and the backup recovery code are lost: the phone looks unpaired, backups stop, and B8 can then overwrite or delete the real code. | `ExpoCompatibleKeychain` exactly as 02 §4.3; same Team ID; gate reads on protected data; simulator test seeded with expo-style items. | 02 §4; 03 §3.7, B8; 04 §5; 09 §3.1 |
| 4 | The AsyncStorage import runs late, misreads the MD5 overflow file, or marks itself done while protected data is unavailable. | Every existing user sees onboarding again; recent places, categories, the dismissed notice, `lastBackupAt` and the join markers are lost (an immediate re-backup, a re-shown import offer). | `LegacyImport` before any `UserDefaults` read; marker only on success; fixtures with inline and overflow values; the seven MD5 vectors. | 02 §5; 09 §3.2-3.3 |
| 5 | Schema or snapshot drift (GRDB migrator tables, extra indexes, `sqlite_master` text, a new `user_version`). | Backups and household dumps change; Android RN and the home server reject or mis-migrate them; an RN TestFlight build over native runs against an unknown schema. | D-2; the `sqlite_master` byte-equality test; schema-governance rule (native never ships a version Android and the home server have not); a cross-platform restore fixture. | 01 §3-4; 03 §5.1; 02 §8 |
| 6 | App Store update constraints are missed. | Upload rejected, or users lose data: wrong team, build number not above the EAS counter, version not above live, dropping iPad, adding a required capability, dropping the `inventory` URL scheme (printed labels stop opening the app), missing usage strings, missing privacy manifest. | 02 §9 checklist as a release gate; an upgrade rehearsal from the live RN build to native on real devices. | 02 §9; 09 §8.5 |
| 7 | Wire-contract drift against unchanged backends. | Silent data or UX bugs: absent-vs-`null` patches (`category: null` clears), strict `Codable` throwing on missing keys, idle instead of total timeouts, wrong reachability (offline vs revoked), missing `x-inventory-key` (401), wrong `Content-Type`. | Tri-state patch encoding, lenient list decoding with `invalid_response` mapping, `withTotalTimeout`, `URLProtocol`-stubbed contract tests from the server test suites. | 04 §3-4; 03 §4; 05 §10 |
| 8 | Text-folding parity (final sigma, NFKD after lowercasing, `jsTrim`, ASCII-only SQL folding). | Every native `items.update` rewrites `search_text` with different folding; local and household search diverge; places stop matching. | Port at Unicode-scalar level; the vector table in 01 §6.6 shared with Node; device check of SQLite `LOWER`/`LIKE`. | 01 §2.1, §6.5-6.6 |
| 9 | WebP encoding: ImageIO decodes but cannot encode WebP. | Without libwebp, the photo format changes and breaks household and worker expectations, restore naming and Android. | Bundle libwebp (for example SDWebImageWebPCoder via SPM); opaque 8-bit sRGB; no EXIF/GPS; dimension round-trip tests. | 05 C3, §9; 02 §13 |
| 10 | Recognition is probably failing in production today (`image/jpeg` declared for WebP bytes). | Parity testing against a broken baseline; users see "server error" for every photo. | Confirm against the deployed endpoint first; sniff the media type natively and fix RN (U6). | 05 C2, Q17 |
| 11 | SwiftUI architecture gaps. | Lists do not refresh after writes or on return from a sheet; toasts or the revoked layer appear behind sheets; route results resume twice or never. | `ScreenFocus` environment + `InventoryQuery` with `.task(id:)`; the overlay window; continuation-based results resumed exactly once. | 09 §5, §7.7; 06 §3.4 |
| 12 | AVFoundation specifics. | A crash when per-capture quality prioritisation exceeds the output maximum (C5); photo geometry differs from RN (C4); iPad orientations. | Raise `maxPhotoQualityPrioritization` before starting the session; decide U7; device tests on iPhone and iPad. | 05 C4-C5, §8 |

---

## 7. Proposed implementation order

Milestones are ordered by dependency. Each has an exit criterion that can be tested. Milestones M4–M6 can overlap once M3 is done; M7 and M8 need M5 for photos.

| Milestone | Content | Depends on | Exit criterion | Specs |
|---|---|---|---|---|
| **M0 Project and release skeleton** | Xcode project in `native-ios/` (bundle id, team, iOS 26, Swift 6 strict, iPhone + iPad, `arm64`); `InventoryKit` SwiftPM package with module layout; xcconfigs and Info.plist parity (usage strings, URL schemes, ATS, no entitlements); privacy manifest; `AppConfig` parser; telemetry (allowlist, debug `Logger` sink, no-op release sink); `describeError` and error types; String Catalog generated from `strings.ts`; CI writing `Secrets.xcconfig`. | U1 | `swift test` green for `AppConfig`, telemetry redaction and the full `errors.test.ts` port; an archive that App Store Connect accepts for app `6795274058`. | 09 §8-10, §13; 02 §9; 08 §2 |
| **M1 Pure core logic** | ids and QR tokens; base32 and account id; quantity; tokenizer and folding; short codes; `format.ts`; a11y helpers; colour helpers; code normalisation and `serverHost`; place matching; the pure UI logic modules (`captureFlow`, `containerRules`, `itemDetails`, `moveFlow`, `spaceSetup`, `addSheet`, `addDraft`, `scanRules`, `homeList`, household `status`/`join`, `routeResult`). | M0 | Every listed TS unit test ported to Swift Testing and passing; the folding vectors also pass in Node. | 01 §6, §8, §13; 03 §3; 07 §2; 08 §3, §9.1, §11; 06 §21 |
| **M2 Storage and in-place adoption** | GRDB `DatabaseQueue` at the legacy path; `user_version` runner with the verbatim migrations; local repositories (spaces, containers, items, QR, search); snapshot and restore primitives; `ExpoCompatibleKeychain`; `LegacyAsyncStorageReader` + `LegacyImport`; `PhotoPathResolver`; preference stores (onboarding, recent places, categories, notice, import offer, `lastBackupAt`); boot models and gate (`DatabaseModel`, `HouseholdModel` load only, `OnboardingModel`, boot views). | M1 | Ported `persistence.test.ts`, `search.test.ts`, `nodeDatabase.test.ts`; `sqlite_master` byte test; v6 → v7 FK-safety fixture; WAL-only rows survive open; fixtures captured from the RN app on a simulator (database at v4/v6/v7, keychain items, manifest with an overflow file) are adopted with nothing lost. | 01; 02; 09 §3-4 |
| **M3 App shell and navigation** | `RootView` gate; `MainShell` (`TabView`, per-tab stacks per U5); `Router` (routes, sheets, covers, continuation results, search focus); `inventory://c/<token>` handling; `InventoryQuery` + `revision` + `ScreenFocus`; `ToastCenter` + overlay window; `ScreenFrame`, `BottomBar`, confirm presenter, haptics wrapper; scene-phase routing. | M2 | `InventoryQueryTests`, `ToastCenterTests`, `BootGateTests`, `routeResult` tests; a cold deep link lands on the label screen with Home underneath. | 06 §1-4, §14, §16; 09 §2-7 |
| **M4 Local inventory screens** | Home (overview, search, quantity chips), Spaces, Drop zone, space/container/item detail, new and edit forms, move/file with Undo and filing runs, `QuantityStepper` + `SavedQuantityModel`, pickers and place picker, Add sheet without photo, Settings, Privacy, Onboarding (local path). | M3 | Full local-mode flows on device against an adopted RN database; `moveFlow`, `useSavedQuantity` coalescing (two writes for five taps) and dirty-guard behaviour verified; VoiceOver labels match the a11y catalogues. | 06; 07; 08 §7-10 |
| **M5 Photos, capture and recognition** | `ImageStore` (ImageIO decode, libwebp encode, thumbnails, free-space check); `Thumb` loader; photo viewer; capture screen (AVFoundation single, request and fast modes; tap to focus; library import via `PhotosPicker`); Quick Snap pipeline and review; camera permission; recognition client and `SuggestionBanner`; `NameItInline`; photos in the Add sheet. | M4 | `scaleToFit`, `recognition` and `contract` tests ported; WebP dimension round-trip; no EXIF; recognition verified against production (U6/C2); a Quick Snap burst does not exhaust memory. | 05 |
| **M6 QR labels and scanning** | Scan tab (`DataScannerViewController`), code-list phase, `/c/<token>` lookup and linking, QR label card and share picture (CoreImage, level M), link-a-sticker screen. | M4 | Printed RN labels open the native app from the system Camera; scan outcomes and telemetry match; the share sheet offers Save Image without a crash. | 06 §8-9; 07 §3.9-3.10, §5 |
| **M7 Household** | `HouseholdClient` (total deadline, reachability hub), pairing and session, HTTP repositories with hydration and the photo cache, `ShadowingRepositories`, `ConnectionModel` (state machine, health ping, resume refresh), connection banner and revoked overlay, Household screen, join form (also in onboarding), import offer and import. | M5 | Contract tests from `home-server/test` behaviours via `URLProtocol` stubs; `ConnectionModelTests` for every transition row; a phone paired by the RN build stays paired after upgrading. | 04; 09 §4.2-4.3 |
| **M8 Backup and sync** | `SyncClient`; recovery-code account; snapshot and restore with newer-schema refusal and `migrate`; photo sync queue (using `PhotoPathResolver`); `SyncCoordinator` triggers and exclusivity per U6; Backup screen and Settings row. | M2, M5 | Ported `identity`, `backup` and `photoSync` tests; a native snapshot restores in the RN Android app and an Android snapshot restores natively; an upgraded device with unsynced photos and a moved container keeps every row. | 03 |
| **M9 Hardening and release** | Accessibility and Dynamic Type pass; iPad layout (U4); Reduce Motion; performance (10 000-item search under 1 s); upgrade rehearsal (live RN build with real data → native; RN TestFlight build installed over native still reads everything); privacy label; TestFlight, then App Store. | all | Release checklist in 02 §9 signed off; no open U-questions affecting shipped features. | 02 §9; 08 §9; 09 §14 |

---

## 8. Consistency fixes made in this pass

Each item was checked against the RN source. The affected spec's reviewer notes record the change.

1. **SQLite connection type**: 01 recommended `DatabaseQueue`; 02, 03 and 09 used `DatabasePool`. All now use `DatabaseQueue` (D-1). (02 §2.3, §10; 03 §5.1, §6.2; 09 §3.2, §4.1, §12, §13.4-13.5)
2. **Keychain read order**: 09 (§3.1, §14.2) and 04 (§5) required the three-service probe as a MUST, while the owner 02 §4.3 reads `app:no-auth` then `app`. Aligned to 02 (D-3).
3. **Photo resolver**: 05 §9.7 defined a different resolver (`PhotoLocation`, suffix after the last `/Documents/`) that misses Android-restored paths. 05 now uses 02's `PhotoPathResolver` (D-4).
4. **Rewriting photo rows**: 09 claimed 02 forbids it; 02 leaves it optional (Q4), as do 03 B4 and 05. 09 corrected.
5. **RN database retry**: 01 said a retry leaks a connection; expo-sqlite returns its cached connection (`SQLiteModule.swift:107-111`), as 09 said. 01 corrected.
6. **Resume refresh "first run"**: 01 (§9.1, and its reviewer note) said the arming skip is per session; it is per process (`lastResumeRef` is never reset), as 09 and 04 say. 01 corrected.
7. **Household request timeout**: 04 said the body is not under the timeout; on device RN `fetch` resolves after the full body (`whatwg-fetch` over XHR), as 03 and 09 say. 04 corrected; its Q7 closed (D-7).
8. **Titles**: 09 said "inline titles"; 06 and 07 map RN's in-content large titles to system large titles. 09 corrected (D-9).
9. **Reactivity**: 05 recommended GRDB `ValueObservation` for the review and said the revision model is "replaced by GRDB observation app-wide", contradicting 01, 07 and 09. 05 corrected (D-6); live rows are now an option behind 05 Q14.
10. **Preference storage format**: 06 §20 allowed a typed `Bool` after import, 03 §5.3 stored `lastBackupAt` as `Int64`/`Double`, and 01 §10.2 / 07 §6.3 implied per-area importers that parse at import. All now defer to 02 §5.4 (raw strings, one importer, parse on read) (D-5). 04 Q8 closed.
11. **Shadow photo URIs**: 03 Q11 said shadow rows often carry `file:` cache URIs; the shadow mirror runs on the unhydrated create body, so they are always `r2:` (`httpRepositories.ts:248-268`, `shadow.ts:200-221`), as 02 and 04 say. 03 corrected.
12. **Photo-library usage string**: 02 and 08 called it optional with `PhotosPicker`; the label share sheet's Save Image writes to the library, and 05 kept the key. 02 and 08 corrected (D-10).
13. **Brand accent**: 02 §9.8 stated tape yellow as decided; it is open (08 Q3, U2). 02 corrected.
14. **Quantity parsing owner**: 07 recommended plain `Int()`; 01 §6.4 specifies JS `Number()` grammar with `jsTrim()`. 07 now defers to 01 (D-11).
15. **Removed-phone layer presentation**: 04 suggested a `.fullScreenCover`; the shell decision is the shared overlay window. 04 now defers to 09 §7.7 (D-8).
