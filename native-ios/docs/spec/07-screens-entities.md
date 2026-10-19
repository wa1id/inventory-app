# 07: Item, container and space screens, forms, pickers and QR labels

Porting spec for the native iOS app (Swift 6, SwiftUI, iOS 26+). It covers the entity screens (item, container, space), their forms, the shared pickers and steppers, and QR label generation and sharing. Source citations use `path:line` relative to `/home/walid/inventory-app`. User-facing copy is referenced by its key in `src/i18n/strings.ts` (written `strings.x.y`); function-valued keys take the arguments shown.

> Scope: `app/item/new.tsx`, `app/item/[id]/{index,edit,move}.tsx`, `app/container/new.tsx`, `app/container/[id]/{index,edit,link,qr}.tsx`, `app/space/new.tsx`, `app/space/[id]/{index,edit}.tsx`, `src/ui/item/**`, `src/ui/container/**`, `src/ui/spaces/**`, the listed components and pickers in `src/ui/components/**`, `src/ui/confirm.ts`, `src/ui/code.ts`, the listed hooks, and `src/repositories/qr.ts`. Supporting modules that these files depend on (`src/ui/add/*`, `src/ui/placeMatch.ts`, `src/ui/categoryMemory.ts`, `src/services/places/recentPlaces.ts`, `src/core/quantity.ts`) are specified here too, as far as these screens use them.

---

## 0. Conventions shared by every screen in this area

### 0.1 System records: the drop zone

- `DROP_ZONE_CONTAINER_ID = 'drop-zone'` and `DROP_ZONE_SPACE_ID = 'drop-zone-space'` (`src/db/constants.ts`). The migration seeds them as real rows with `kind = 'system'`: the space `('drop-zone-space', 'Drop zone', '📥', '#0F9BB0')` and the container `('drop-zone', 'drop-zone-space', 'Drop zone', 'other', 'DROP-ZONE')` (`src/db/migrations.ts:124-141`).
- List queries filter `kind = 'normal'`, so the drop zone never shows up as a space or container row (`src/repositories/containers.ts:66-83,225-240`, `src/repositories/spaces.ts:63-82`).
- No screen in this area works on the drop zone. Each route guards it:
  - Container detail with `id == 'drop-zone'` goes to the Drop zone tab in an effect (`app/container/[id]/index.tsx:51-56,152-156`).
  - Space detail with `id == 'drop-zone-space'` does the same (`app/space/[id]/index.tsx:34-39,59-63`).
  - Edit container, edit space, new container (`spaceId == 'drop-zone-space'`), the QR screen and link sticker show a "locked" state instead of a form. It uses `strings.errors.dropZoneLocked.{title,body,action}`, and the action goes to the Drop zone tab (`src/ui/spaces/FormLayout.tsx:85-99`, `app/container/[id]/qr.tsx:75-87`, `app/container/[id]/link.tsx:189-199`).
  - The repositories refuse to update or delete them and throw `Error('system_record')` (`assertNotDropZone` at `src/repositories/containers.ts:57-59`, called at `:154` (update) and `:199` (delete); `src/repositories/spaces.ts:44-46`, called at `:111` and `:169`). `qr.bind` refuses the drop zone (`src/repositories/qr.ts:119`). `containers.create` does **not** check for `spaceId == 'drop-zone-space'`; only the UI route guard stops it.
- `openContainer(id)` and `openSpace(id)` send drop zone ids to the Drop zone tab instead of pushing (`src/ui/navigation.ts:27-38`).

### 0.2 Repositories: local and paired

Every screen calls `repos.<entity>.<method>`. The implementation depends on the phone's mode:
- **Local**: SQLite through `src/repositories/*.ts` (exact SQL is summarised in §6).
- **Paired** (household): HTTP through `src/services/household/httpRepositories.ts`, which has the same method signatures. Behaviour differences the UI relies on:
  - For the calls that go through `callIgnoring404` (`httpRepositories.ts:42-52`), a household 404 comes back as `null` (`spaces/containers/items.getById`, `getWithCounts`, every `update`, `qr.getByContainer`), `{deleted:false, orphanedPhotoUris:[]}` (every `delete`) or `false` (`qr.unbind`). Screens treat `null` from `update`/`getById` as "gone". **Every other call throws a 404 as `HouseholdHttpError(404, code)`**: the list calls, `spaces/containers/items.create`, `qr.resolveScan`, `qr.bind` and `qr.createAndBind` (`httpRepositories.ts` `call(...)`). `describeError` maps that to `gone` (§0.4). This is why Add's failure banner uses subject `container` (a 404 on `POST /v1/items` means the container went) and why `labelFailureMessage` can return `strings.qr.containerGone`.
  - A 409 response is thrown as `ConflictError(updatedAt)`. `updatedAt` is read from the JSON body, or is `null` when the body has none (`src/services/household/client.ts:124-130`). A 204 response resolves to `{}` (line 115).
  - `spaces.deletionImpact` over HTTP is `GET /v1/spaces/:id`, then `GET /v1/spaces`, using that row's `containerCount`/`itemCount`. It always reports `photoCount: 0` and `qrBindingCount: 0` (`httpRepositories.ts:142-153`). The edit space screen makes up for the label count (§2.6 `labelsInSpace`).
  - `containers.deletionImpact` over HTTP is `GET /v1/containers/:id`: `{itemCount: itemCount ?? 0, photoCount: 0, hasQrBinding: Boolean(qrToken)}` (`httpRepositories.ts:198-205`).
  - `qr.getByContainer` is derived from `GET /v1/containers/:id` `qrToken`. The binding it returns uses the **container's** `id`/`createdAt`/`updatedAt`, not the binding row's (`httpRepositories.ts:322-337`). Only `.token` is used by the UI.
  - Containers and spaces have **no optimistic lock** in either implementation: `containers.update` and `spaces.update` write unconditionally (last writer wins) and never throw `ConflictError` (`src/repositories/containers.ts:153-175`, `src/repositories/spaces.ts:110-129`). Only items carry `expectedUpdatedAt`. Do not add locks natively: the household contract has no lock field for them.

**Native:** expose one `Repositories` protocol with the same method set (async, `throws`). Provide a GRDB implementation and an HTTP implementation. The HTTP contract belongs to the household spec. See §6 for the endpoints these screens hit.

### 0.3 Reads: `useInventoryQuery` semantics (`src/hooks/useInventoryQuery.ts:53-133`)

Each screen read is `useInventoryQuery(run, key)` and returns `{data, loading, cause, refreshFailed, reload}`:
- It re-runs on mount, on **every screen focus**, on `reload()`, and when a global `revision` changes (bumped by `invalidate()` after a write). A screen in the background only catches up with `revision` when it is focused again (lines 64-69).
- A failed refresh **keeps the previous data for the same key**. `refreshFailed = failed && data != nil` (lines 99-107,121-131).
- `loading` is true while the newest request has not settled.
- `data` is not cleared when the key changes. Until the new key's read settles, the previous key's data is still returned. A failure under a new key yields `data = nil` (lines 89-101,120-127). Example: the container screen's space query moves from key `space:none` to `space:<id>`.
- Screens show the info banner `strings.errors.refreshFailed`, with `strings.common.tryAgain` → reload, when `needsRefreshBanner(refreshFailed, cause)` is true. That is "refresh failed and the cause is not offline or revoked" (`src/ui/errors.ts:90-95`). Offline and revoked have their own app-level banners, owned by the connection area.

**Native:** an `@Observable @MainActor` store with a `revision: Int`. Each screen model reloads on `.task(id: revision)` / `.onAppear`, keeps the last good value on failure, and exposes `refreshFailed`. In local mode a GRDB `ValueObservation` could replace this, but parity with paired mode (HTTP) argues for one "reload on focus + revision" mechanism.

### 0.4 Errors → words (`src/ui/errors.ts:41-87`)

`describeError(cause, context = 'read', subject = 'list') -> {kind, title, body}`:

| cause | kind | title / body |
|---|---|---|
| `ConflictError` | `conflict` | `strings.errors.conflict.{title,body}` |
| `null` | `gone` | title by subject: `errors.gone.space` / `.container` / `.item` (item and list share the item title); body `errors.gone.body` |
| `HouseholdHttpError`, unreachable (code `offline`/`timeout`/`http_502`, or status 502 or 520–530) | `offline` | `errors.offline.title`; body `errors.offline.read` when context is `read`/`join`, else `errors.offline.save` |
| HTTP 401 or code `unauthorized` (context ≠ `join`) | `revoked` | `errors.revoked.*` |
| HTTP 404 or code `not_found` | `gone` | as for `null` |
| code `photo_missing` | `photo` | `errors.photo.*` |
| other HTTP | `server` | `errors.server.*` |
| anything else (SQLite, JS error) | `local` | `errors.local.title`; body `errors.local.read` for read/join, else `errors.local.save` |

`isOffline(cause) = describeError(cause,'save').kind == 'offline'` (line 97-99). Raw messages are never shown. The `describeError` tests (`src/ui/__tests__/errors.test.ts`) belong to the errors/infra spec.

### 0.5 Writes and toasts

- After every successful write the screen calls `invalidate()`. Every focused query re-reads.
- Toasts come from the app's ToastProvider (another area). Plain toasts stay 5000 ms; toasts with an action (Undo) stay 9000 ms (`src/ui/motion.ts` `delay.toast`, `delay.toastWithAction`). An action runs at most once. Error toasts use `tone: 'error'`.
- A screen in a modal sheet reports failures **inline** (a banner above the form). It uses a toast only when the sheet was closed under the save, by the header Cancel or the "removed phone" layer. After awaiting a write, the save, create, move, name and item-delete paths check `navigation.isFocused()` before they navigate. **Exceptions:** container delete (`router.dismissAll()` + push, `app/container/[id]/edit.tsx:179-184`) and space delete (`goToTab('/spaces')`, `app/space/[id]/edit.tsx:170-171`) navigate unconditionally. Link sticker uses its own mounted flag `openRef` instead (§3.10).

### 0.6 Haptics (`src/ui/haptics.ts`)

| name | iOS feedback | used for |
|---|---|---|
| `step` | selection | stepper ±, every 5th step while holding |
| `reachedZero` | impact light | stepper reached 0 |
| `choice` | selection | a choice changed (place, space, type, colour, icon, segment) |
| `undo` | selection | Undo applied |
| `success` | notification success | add, move, file, create, label made/linked/removed |
| `warning` | notification warning | conflict shown, item moved elsewhere |
| `error` | notification error | failed write, invalid QR, quantity not saved |

**Native:** `.sensoryFeedback(...)` or `UISelectionFeedbackGenerator` / `UINotificationFeedbackGenerator` / `UIImpactFeedbackGenerator(style: .light)`. Fire and forget.

### 0.7 Telemetry

`logEvent`/`logError` (`src/services/telemetry/index.ts`) have no remote sink and print in DEV only. Payload keys are allow-listed. The event names used in this area are listed for each screen. **Native:** `os.Logger` with the same names. Never log names, notes or tokens.

### 0.8 Confirm dialogs and action sheets (`src/ui/confirm.ts`)

- `confirm({title, body, confirmLabel, cancelLabel = strings.common.cancel, destructive = true}) -> Promise<Bool>` shows a system alert with a Cancel button (cancel style) and a confirm button (destructive style unless `destructive:false`). It resolves `false` on Cancel or dismiss (`confirm.ts:25-47`).
- Confirms are used only for deletes, replacing or removing a label, moving or replacing a sticker, and discarding a dirty form. Moves, files and adds use Undo instead (`confirm.ts:17-24`).
- `showActionSheet({title?, options:[{label, destructive?, onPress}], cancelLabel})`. On iOS it shows `ActionSheetIOS` with Cancel last and the destructive indices marked (`confirm.ts:62-87`). On Android it falls back to an alert with at most 2 options (lines 89-101). That fallback is not needed natively.

**Native:** a small `ConfirmPresenter` (`@Observable`) that holds a pending `ConfirmRequest` and a `CheckedContinuation<Bool, Never>`. The view hosts `.alert(title, isPresented:) { Button(confirmLabel, role: .destructive) ; Button(cancelLabel, role: .cancel) } message: { Text(body) }`. Dismissal must resume with `false`. Action sheet → `.confirmationDialog(..., titleVisibility: .hidden)` with `Button(role: .destructive)` for destructive options.

### 0.9 Route results (`src/ui/routeResult.ts`)

A screen opens another with a `request` id and awaits a value. `deliverResult(id, value) -> Bool` (false if nobody waits) and `abandonResult(id)` (idempotent, resolves `undefined`) are called by the opened screen, the latter on unmount. The shapes are in `src/ui/navigation.ts:64-96`:
- `MoveResult {itemId, from, to, updatedAt, waiting?: [String]}`
- `NewContainerResult {containerId, name: String?, shortCode, visualType, spaceId}`
- `NewSpaceResult {spaceId, name}`
- `PhotoResult = StoredImage {uri, thumbUri?, width, height, byteSize: Int?}` (capture area)

Tests: `src/ui/__tests__/routeResult.test.ts`. "passes a request id… resolves with the delivered value"; "resolves only once" (second deliver → false); "resolves undefined when abandoned, and ignores a delivery after that"; "keeps concurrent requests apart"; "ignores a missing or unknown request id".

**Native (RN workaround, not needed):** pass closures instead. For example `.sheet(isPresented:onDismiss:)` presents `NewContainerSheet(spaceId:onCreated:)`, and `onDismiss` without a delivery means "abandoned". Keep the *semantics*: a sheet closed without creating anything must tell the waiting picker "nothing", and a delivery must happen at most once.

### 0.10 Routes and presentation (`app/_layout.tsx:87-95,166-206`)

| Route | Presentation | Header title | Params |
|---|---|---|---|
| `/item/new` | modal sheet | dynamic (§3.1) | `containerId?`, `name?`, `photoUri?`, `photoThumbUri?`, `photoWidth?`, `photoHeight?`, `photoBytes?` (all strings) |
| `/item/[id]` | push | empty until the title scrolls under the header; filing progress (§3.2) | `id`, `filing?='1'` |
| `/item/[id]/edit` | modal sheet | `strings.editItem.title` | `id` |
| `/item/[id]/move` | modal sheet | dynamic (§3.5) | `id`, `filing?='1'`, `request?` |
| `/item/[id]/photo` | full-screen modal, fade (other area) | none | `id` |
| `/container/new` | modal sheet | `strings.containerForm.newTitle` | `spaceId`, `request?` |
| `/container/[id]` | push | collapsing title | `id` |
| `/container/[id]/edit` | modal sheet | `strings.containerForm.editTitle` | `id` |
| `/container/[id]/qr` | push | `strings.qr.title` | `id` |
| `/container/[id]/link` | full-screen modal, no header | none | `id` |
| `/space/new` | modal sheet | `strings.spaceForm.newTitle` | `request?` |
| `/space/[id]` | push | collapsing title | `id` |
| `/space/[id]/edit` | modal sheet | `strings.spaceForm.editTitle` | `id` |

Every modal sheet has a top-left Cancel: the word `strings.common.cancel` on iOS, and it goes back (`app/_layout.tsx:62-90`). Add item and Edit item replace it with their own (§3.1, §3.4).

**Native:** one `NavigationStack` per tab. Pushed screens use `navigationDestination`. Sheets use `.sheet` with their own inner `NavigationStack` and a `ToolbarItem(placement: .cancellationAction)`. Link sticker uses `.fullScreenCover`. Register the URL scheme `inventory` (printed labels encode `inventory://c/<token>`; §5).

### 0.11 Collapsing title (`src/hooks/useCollapsingTitle.ts`)

On detail screens the title lives in the content in large type. The nav bar title stays `''` until the title block's bottom edge scrolls under the header, then it shows the title and a header shadow. **Native:** this is what iOS large titles do. Use `.navigationTitle(title)` with `.navigationBarTitleDisplayMode(.large)`. Where extra content sits above the title (the container's space crumb, the space tile), use `.inline` plus `onScrollGeometryChange` to toggle `navigationTitle` between `""` and `title` (open question Q9).

---

## 1. Domain constants

| Constant | Value | Source |
|---|---|---|
| `MIN_QUANTITY` / `MAX_QUANTITY` | `0` / `9999` | `src/core/quantity.ts:8-9` |
| Default new item quantity | `'1'` (string in form) | `src/ui/components/ItemForm.tsx:25-31` |
| Stepper hold delay / repeat | 400 ms / every 80 ms | `src/ui/motion.ts` `delay.stepRepeat`, `delay.stepRepeatEvery` |
| Haptic during hold | every 5th step | `src/ui/components/QuantityStepper.tsx:32` |
| Quantity conflict retries | 3 | `src/hooks/useSavedQuantity.ts:11` |
| Container types (ordered) | `box, drawer, shelf, cabinet, bin, bag, crate, other` | `src/db/types.ts:56-65` |
| Short-code prefixes | box `BOX`, drawer `DRW`, shelf `SHF`, cabinet `CAB`, bin `BIN`, bag `BAG`, crate `CRT`, other `CTR`. An unknown type falls back to `CTR` | `src/core/shortCode.ts:10-19,36` |
| Short-code suffix | 4 chars from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (uses `Math.random`). Format `PFX-XXXX`, joined with `-` | `src/core/shortCode.ts:7-8,21-37` |
| Short-code collision retries | 10 | `src/repositories/containers.ts:62` |
| QR token | 32 lowercase hex = 16 CSPRNG bytes | `src/core/id.ts` `newQrToken` |
| QR payload prefix | `inventory://c/` | `src/repositories/qr.ts:29` |
| Space colours | `#5B8DEF, #2E9E4F, #E4572E, #B15BEF, #E0A800, #0F9BB0` | `src/ui/theme.ts:38-45` |
| Space icons | `🛋️(U+1F6CB U+FE0F) 🍳 🛏️(U+1F6CF U+FE0F) 🚗 🧰 📚 🧺 🏠 🪴 🎒` | `src/ui/theme.ts:47` |
| Space presets | Garage 🚗 `#5B8DEF`; Wardrobe 👕 `#B15BEF`; Loft 🏠 `#E4572E`; Cellar 🚪 `#E0A800` | `src/ui/theme.ts:57-62` |
| Recent places kept / shown | 6 stored; 4 in picker; 3 in Add | `recentPlaces.ts:8`, `PlacePicker.tsx:67`, `addSheet.ts:156` |
| Category memory | 20 saved; 6 suggestions | `src/ui/categoryMemory.ts:3-5` |
| Add draft TTL | 30 min | `src/ui/add/addDraft.ts:20` |
| Fresh arrival | 10 000 ms either side | `src/ui/container/containerRules.ts:62-71` |
| Arrival highlight | hold 600 ms then fade 1200 ms | `app/container/[id]/index.tsx:37-39` |
| "Changed" stamp threshold | 60 000 ms | `src/ui/item/itemDetails.ts:152` |
| Share picture | 1024×1024 px PNG; 4000 ms timeout | `src/ui/container/labelImage.ts:12,15` |
| Delayed spinner / skeleton | 150 ms / 180 ms | `src/ui/motion.ts` `delay.spinner`, `delay.skeleton` |
| Arrival focus fallback | 700 ms | `app/item/new.tsx:88`, `app/item/[id]/index.tsx:48` |

**Emoji exactness:** icons are stored as the exact strings above, including U+FE0F variation selectors. Swift `String ==` treats `"🛋"` and `"🛋️"` as different. Use the literal scalars from `theme.ts` and never normalise. Spoken names: `strings.entities.iconNames` (`strings.ts:88-101`), fallback `strings.entities.currentIcon`.

**Text length limits:** no client or server limit exists for names, categories, tags or notes. No `maxLength`, and the home server does no length check (`home-server/src/inventory.ts:79-160` only checks presence: `POST /v1/spaces` answers 400 `invalid_body` when `name`, `icon` or `color` is missing or not a string). The only input cap is the quantity field's 4 characters (`QuantityStepper.tsx:346`).

**Quantity bound is UI-only:** the repository only requires an integer ≥ 0 (`requireQuantity`, `src/repositories/items.ts:30-35`) and enforces no upper bound. The 9999 cap exists only in `clampQuantity`, the stepper and `useSavedQuantity`. Rows written by other clients may hold larger values. The native app must display them and must not "repair" them on read. Parity edge: on such a value plus is disabled (`value >= 9999`), and a minus tap writes `stepQuantity(v, -1) = clamp(v - 1) = 9999`.

---

## 2. Pure logic (port first, with Swift Testing)

### 2.1 Quantity (`src/core/quantity.ts`)

- `clampQuantity(v)`: non-integer (including NaN) → 0; `< 0` → 0; `> 9999` → 9999; else `v` (lines 12-17).
- `parseQuantityInput(raw)`: trim; empty → nil; `Number(trimmed)` must be an integer `>= 0`, else nil; values above 9999 are returned unclamped (lines 26-32). **Owner: `01-data.md` §6.4** (one shared implementation in the core module; Q4 there decides how much of the JS `Number()` grammar to accept). Constraints that apply whatever Q4 decides: trim with `jsTrim()` (not `.whitespacesAndNewlines`); accept only ASCII digits (Swift `Int(_:)` already rejects `"٣"`, which JS also rejects); at least `'1.0'` → 1 is recommended there. A bare `Int(trimmed)` passes the RN tests but rejects `'1.0'`, `'1e3'` and `'0x10'`, which JS accepts; only paste can produce those (Q1 here is the same question as 01 Q4).
- `stepQuantity(c, d) = clampQuantity(c + d)` (line 34).

Tests (`src/core/__tests__/quantity.test.ts`): clamp keeps 0/8/9999; 1.5 and NaN → 0; −1 → 0, 10000 → 9999. parse rejects `'' '   ' 'abc' '1.5' '-1'`; accepts `'0'` → 0 and `' 12 '` → 12. step 3+1=4, 3−1=2, 0−1=0, 9999+1=9999.

### 2.2 Item form (`src/ui/components/ItemForm.tsx`)

`ItemFormValues {name, category, tags, quantity, notes}`, all `String`. `EMPTY_ITEM_FORM = {'', '', '', '1', ''}` (lines 12-31).

`validateItemForm(values) -> (errors {name?, quantity?}, parsed?)` (lines 48-79):
- `name = trim(name)`; empty → `errors.name = strings.forms.itemNameRequired`.
- `quantity = parseQuantityInput(values.quantity)`; nil → `errors.quantity = strings.forms.quantityInvalid`.
- Any error → `parsed = nil`. All errors are reported together.
- `parsed = {name, category: trim || nil, tags: split(',').map(trim).filter(nonEmpty), quantity, notes: trim || nil}`.

`applySuggestion(current, suggestion {name?, category?, tags:[String], confidence}, overwrite = false)` (lines 97-114):
- `tags = suggestion.tags.joined(", ")`.
- `name = current.name.isEmpty ? (suggestion.name ?? "") : current.name`. The check is on the raw field, not the trimmed one, and the name is never overwritten.
- `overwrite == false`: `category = current.category.isEmpty ? (s.category ?? "") : current.category`; `tags = current.tags.isEmpty ? tags : current.tags`.
- `overwrite == true`: `category = s.category ?? ""`, `tags = tags` (replace, even with blanks).
- `quantity` and `notes` are never touched.

Tests (`src/ui/components/__tests__/ItemForm.test.tsx`):
- validate: minimal `{name:'Drill'}` → `{Drill, nil, [], 1, nil}`, no errors; `'   '` name → name error; quantity `'-1' '1.5' 'abc' ''` → quantity error; `'0'` accepted; tags `' power tool ,, dewalt , '` → `['power tool','dewalt']`; empty name + `'-1'` → both errors.
- applySuggestion: fills an untouched form (tags `'dewalt, 18v'`); never takes back typed name/category/quantity/notes but fills blank tags; overwrite replaces category and tags; overwrite keeps the corrected name; overwrite leaves quantity and notes alone; overwrite with `category:nil, tags:[]` clears both to `''`.

### 2.3 Item details (`src/ui/item/itemDetails.ts`)

- `detailsSeed(item)` → `{name, category ?? '', tags.joined(', '), quantity: String(quantity), notes ?? ''}` (lines 21-30).
- `tagList(s)` = split `,`, trim, drop empties, join `,` (lines 32-38).
- `detailsDirty(values, seed)`: true if trimmed name, trimmed category, `tagList(tags)` or trimmed notes differ. Quantity is ignored (lines 45-52).
- `rebaseDetails(values, seed, theirs)`: for each of name/category/notes, if `trim(values.f) != trim(seed.f)` keep `values.f`, else take `theirs.f`. Tags compare by `tagList`. `quantity = theirs.quantity` (lines 59-71).
- `keepsUnnamed(storedName, typedName) = storedName == '' && trim(typedName) == ''` (lines 79-81).
- `attemptDetails(items, id, patch {name?, category, tags, notes}, base {updatedAt, values})` → `saved | gone | conflict(base) | failed(cause)` (lines 120-149):
  1. `items.update(id, patch + expectedUpdatedAt: base.updatedAt)`. A value → `saved`; nil → `gone`; a non-conflict throw → `failed(cause)`.
  2. On `ConflictError`: `fresh = getById(id)`. nil → `gone`. `theirs = {fresh.updatedAt, detailsSeed(fresh)}`. If `detailsDirty(theirs.values, base.values)` → `conflict(theirs)`, with no write.
  3. Otherwise only quantity or place changed. Retry once with `expectedUpdatedAt: fresh.updatedAt`: value → `saved`, nil → `gone`, any throw (a second conflict included) → `failed`.
- `itemStamp(createdAt, updatedAt, now)`: `added = strings.item.stampAdded(longDate(createdAt))`. If `updatedAt − createdAt > 60_000` → `"\(added) \(strings.item.stampChanged(ago(updatedAt, now)))"`, else `added` (lines 152-160). `longDate` is `Intl.DateTimeFormat('en-GB', {day:'numeric', month:'long', year:'numeric'})` ("2 September 2026") in the **device's local time zone** (`src/i18n/format.ts:46-55`). Swift: `DateFormatter` with `locale = en_GB`, `dateFormat = "d MMMM yyyy"`, `timeZone = .current`. Tests must pin the time zone (the test fixture uses 12:00 UTC so most zones give the same day). `ago` is hand-written: <1 min "just now", minutes, hours, <2 days "yesterday", days <30, months (days/30) <365, years (days/365). A future time reads "just now" (`src/i18n/format.ts:34-55`). Port it exactly. Do not use `RelativeDateTimeFormatter`, because the wording would differ.
- `attemptName(items, item {id, updatedAt}, name)` → `named | gone | namedMeanwhile(name, updatedAt) | failed` (lines 181-210):
  1. `update(id, {name, expectedUpdatedAt: item.updatedAt})`: value → `named`; nil → `gone`; non-conflict throw → `failed`.
  2. On a conflict: `fresh = getById`; nil → `gone`. If `fresh.name` is non-empty and `!= name` → `namedMeanwhile(fresh.name, fresh.updatedAt)`, with no write. Otherwise retry once over `fresh.updatedAt`: value → `named`, nil → `gone`, throw → `failed`.

Tests (`src/ui/item/__tests__/itemDetails.test.ts`):
- detailsSeed: `{Cordless drill, Tools, [garage,power], notes nil, qty 2}` → `{name, 'Tools', 'garage, power', '2', ''}`.
- detailsDirty: clean as seeded and with spaces added (`' Cordless drill '`, `'garage,power '`); dirty on name/category cleared/tags/notes; quantity ignored.
- rebaseDetails: keeps typed category and takes their notes; keeps typed when both changed the same field; re-spacing is not a change, so theirs wins.
- keepsUnnamed: `('', '')` and `('', '   ')` true; `('', 'Batteries')` and `('Batteries', '')` false.
- itemStamp: created 2026-09-02 12:00 UTC, updated +30 s, now +3 d → `'Added 2 September 2026.'`; updated +1 d, now +4 d → `'Added 2 September 2026. Last changed 3 days ago.'`.
- attemptName: names with lock 10; null → gone; recognition named it meanwhile → `namedMeanwhile('AA batteries', 20)`, the row is unchanged, and saving again over 20 stores it (stamps `[10,20]`); met the same name → named (stamps `[10,20]`); conflict then success → named `[10,20]`; offline throws → failed with no retry.
- attemptDetails: saves over base stamp `[10]`; null → gone; only the quantity changed → saved `[10,20]`; notes changed → `conflict(base:{20, seed(theirs)})` with one call; deleted after the conflict → gone; two conflicts → failed `[10,20]`; offline → failed `[10]`.

### 2.4 Move flow (`src/ui/item/moveFlow.ts`)

- `attemptMove(items, before {id, containerId, updatedAt}, target)` → `moved(updatedAt) | gone | movedElsewhere(fresh) | failed` (lines 50-77):
  1. `update(id, {containerId: target, expectedUpdatedAt: before.updatedAt})`: value → `moved(value.updatedAt)`; nil → `gone`; non-conflict throw → `failed` (no re-read).
  2. On a conflict: `fresh = getById`; nil → `gone`. If `fresh.containerId != before.containerId` → `movedElsewhere(fresh)`. Otherwise retry once over `fresh.updatedAt`: value → `moved`, nil → `gone`, throw → `failed`.
- `attemptUndo(items, {itemId, from, updatedAt})`: `update(itemId, {containerId: from, expectedUpdatedAt: updatedAt})`: value → `undone`; nil → `gone`; `ConflictError` → `conflict`; else `failed(cause)` (lines 91-104).
- `undoFailedMessage`: gone → `strings.move.undoGone`; conflict → `strings.move.undoConflict`; failed → offline ? `strings.move.undoFailed` : `strings.move.undoFailedOther` (lines 107-113).
- `containerLabel(place) = place.name ?? place.shortCode` (lines 116-118).
- `movedMessage({fromDropZone, filing, moreWaiting, container, space})`: not from the drop zone → `strings.move.movedTo(c, s)`; from the drop zone with `filing && moreWaiting == false` → `strings.move.filedLast(c, s)`; else `strings.move.filedIn(c, s)` (lines 130-147).
- `afterFiling(items, itemId)`: `waiting = listUnsorted().map(\.id)`; returns `{waiting, moreWaiting: waiting.contains { $0 != itemId }}`; on a throw `{moreWaiting: nil}` (lines 156-166).
- `movedElsewhereMessage(fresh)`: drop zone → `strings.move.alreadyMovedToDropZone`; else `strings.move.alreadyMoved(fresh.containerName ?? fresh.containerShortCode)` (lines 169-176).
- `moveFailedMessage(cause)`: offline → `strings.move.failed`, else `strings.move.failedOther` (lines 179-183).
- `nextInRun(before, currentId, waiting) -> String?` (lines 194-209): `left = Set(waiting − currentId)`. Empty → nil. `start = (before.firstIndex(of: currentId) ?? -1) + 1`. Scan `before[(start + k) % before.count]` for `k in 0..<before.count` and return the first in `left`. If none matches, return the first of `waiting` in `left`.

Tests (`src/ui/item/__tests__/moveFlow.test.ts`):
- attemptMove: moves with lock 100 → `moved(200)`, one call `{box-b,100}`; null → gone; conflict and fresh in `box-c` → `movedElsewhere(fresh)`, one call; conflict and fresh still in `box-a` → retry `[100,150]` → `moved(300)`; two conflicts → `failed(second)`, 2 calls; conflict then deleted → gone; offline `HouseholdHttpError(0,'offline')` → failed, 1 call, 0 reads.
- attemptUndo: back with stamp 200 → undone; null → gone, conflict → conflict, offline → failed; messages match /deleted/, /changed again/, /connection/; for HTTP 500 and SQLite errors the message does not match /connection/ but does match /Try again/.
- messages: `containerLabel` uses the code when unnamed; movedMessage → `'Moved to Tool chest (Garage).'`, `'Filed in Tool chest (Garage).'` (×2), `'Filed in Tool chest (Garage). Everything is filed.'`; moreWaiting nil → filedIn; movedElsewhere → `'Someone already moved it to Garage shelf on another device.'`, falls back to `SHF-1`, never contains `DROP-ZONE`; moveFailedMessage: offline and 502 → /connection/; SQLite → `'It was not moved. Try again.'`.
- nextInRun: `(['a','b','c'],'a',['b','c'])→'b'`; wraps `('c' → 'a')`; skips filed `→ 'c'`; never returns the current item `(['a','b'],'a',['a','b'])→'b'`, `(['a'],'a',['a'])→nil`; new arrivals last `(['a','b'],'a',['z'])→'z'`; current not in the list → from the top `(['a','b'],'x',['b','a'])→'a'`; empty → nil.
- afterFiling: `['b']` after filing `a` → `{waiting:['b'], moreWaiting:true}` with one read, and nextInRun gives `'b'`; `['a']` → `moreWaiting:false`; a read failure → `{moreWaiting:nil}`.

### 2.5 Container rules (`src/ui/container/containerRules.ts`)

- `labelOf(c) = trim(c.name ?? '') != '' ? c.name! : c.shortCode` (lines 19-21). This treats a whitespace name as unnamed. (`spaceSetup.containerLabel` uses plain `name ?? shortCode`; see Q10.)
- `typeNameOf(t) = strings.entities.typeNames[t] ?? typeNames.other` ("Container") (lines 24-26).
- `titleOf(c)`: non-blank name → name, else `strings.entities.unnamedContainer(typeNameOf(visualType))`, which is "Unnamed " + the lowercased type name (lines 29-33).
- `sortContents(items)` (lines 35-59): returns a sorted copy and never mutates. Comparator: trim both names; both non-empty → `localeCompare(en, sensitivity: base)`, tie → `createdAt` ascending; a named item sorts before an unnamed one; both unnamed → `createdAt` ascending. **Swift:** `a.compare(b, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))`.
- `FRESH_ARRIVAL_MS = 10_000`; `isFreshArrival(createdAt, now) = abs(now − createdAt) < 10_000` (lines 62-71).
- `planSticker(outcome, target {id, name, shortCode, qrToken?})` → `invalid | already | link(token, confirm?)` (lines 95-130):
  - `invalid` → `invalid`.
  - `label = labelOf(target)`; `replacing = target.qrToken != nil && target.qrToken != outcome.token`.
  - `bound`: if `outcome.container.id == target.id` → `already`. Otherwise `link` with confirm `{title: strings.link.moveTitle(label), body: moveBody + (replacing ? " " + strings.link.replaceBody(label) : ""), confirmLabel: strings.link.move}`, where `moveBody = strings.link.moveBody(labelOf(outcome.container), label)`.
  - `unknown`: `link(token, confirm: replacing ? {strings.link.replaceTitle(label), strings.link.replaceBody(label), strings.link.replace} : nil)`.
- `settleWrittenLabel(written {token?, reloading}, read {loading, failed})` (lines 150-158):
  - nil → nil.
  - `!reloading`: `read.loading ? {token, reloading:true} : written` (same instance).
  - `reloading && read.loading` → `written`.
  - `reloading && !read.loading`: `failed ? {token, reloading:false} : nil`.
- `labelFailureMessage(action, cause)`: `describeError(cause,'label','container').kind == gone` → `strings.qr.containerGone`; else make → `qr.makeFailed(offline)`, replace → `qr.replaceFailed(offline)`, remove → `qr.removeFailed(offline)` (lines 167-174).
- `shareText(c, payload, withPayload)`: `m = strings.qr.shareMessage(labelOf(c), c.shortCode)`, which is `"<label> (<code>)"`; with the payload: `"\(m)\n\(payload)"` (lines 181-188).

Tests (`src/ui/container/__tests__/containerRules.test.ts`):
- labelOf: `'Tool chest'`; `null` → `'BOX-7K2M'`; `'  '` → code. titleOf: `null`/box → `'Unnamed box'`; `''`/drawer → `'Unnamed drawer'`; named → name. typeNameOf: `'shelf'` → `'Shelf'`, `'suitcase'` → `'Container'`, and titleOf → `'Unnamed container'`.
- sortContents: `['', 'batteries', 'Éclairs', '  ', 'Allen keys', 'Zip ties']` sorts by id to `['a','b','e','z','u1','u2']`; `'Screws'` (9) vs `'screws'` (3) → first, later; the input array is not reordered.
- isFreshArrival: `(1000,1000)` true; `+9999` true; `+10000` false; `(5000,1000)` true; `(31000,1000)` false.
- planSticker: invalid → invalid; unknown, no label → `link(TOKEN, nil)`; unknown with another label → confirm `'Replace the label on Tool chest?'` / `'Tool chest already has a label. Its old sticker will stop opening it.'` / `'Replace'`; bound to self → already; bound to `Shelf A` → `'Move this sticker to Tool chest?'` / `'It opens Shelf A now. After this it opens Tool chest instead.'` / `'Move sticker'`; bound elsewhere plus own label, both unnamed → title `'Move this sticker to CAB-J92R?'`, body `'It opens SHL-4QW8 now. After this it opens CAB-J92R instead. CAB-J92R already has a label. Its old sticker will stop opening it.'`.
- settleWrittenLabel: nil stays nil; holds a write until a read starts (same instance while idle), then `{reloading:true}`, then nil when it comes back; a failed read keeps `{token:nil, reloading:false}` (same instance on further failure) until a later read succeeds.
- labelFailureMessage: replace offline → `'The label was not replaced, so the old sticker still works. Check the connection and try again.'`; remove on 500 → `'The label was not removed, so the sticker still opens this container. Try again.'`; make on SQLite → `'The label was not made. Try again.'`; 404 → `strings.qr.containerGone` text; 530 never shows `http_`/`offline`/`timeout`.
- shareText: `'Tool chest (CAB-J92R)'`; unnamed with payload → `'BOX-7K2M (BOX-7K2M)\ninventory://c/<token>'`.

### 2.6 Space and container form rules (`src/ui/spaces/spaceSetup.ts`)

- `SpaceValues {name, icon, color}`.
- `containerLabel(c) = c.name ?? c.shortCode` (lines 16-18).
- `byContainerLabel(a, b)`: compares `containerLabel` with `localeCompare(en, base)`. There is no tie-break (lines 25-30). JS `Array.sort` is stable and the input comes `created_at DESC`. **Swift:** `sorted(by:)` is not documented as stable, so add an index tie-break to keep the input order.
- `takenSpaceNames(spaces) = Set(spaces.map { trim($0.name).lowercased(en) })`; `isNameTaken(name, taken) = taken.contains(trim(name).lowercased())` (lines 32-47).
- `labelsInSpace(impactLabels, containers) = max(impactLabels, containers.filter { $0.qrToken non-empty }.count)` (lines 55-61).
- `spaceDeleteBody(impact {containerCount, itemCount}, labels)`: all three zero → `strings.spaceForm.deleteEmpty`, else `strings.spaceForm.deleteBody(containers, items, labels)` (lines 64-72).
- `containerDeleteBody({itemCount, hasQrBinding})`: 0 items → `strings.containerForm.deleteEmpty(hasQrBinding)`, else `strings.containerForm.deleteBody(itemCount, hasQrBinding)` (lines 75-79).
- `spaceValuesChanged(v, i)`: trimmed names differ, or icon differs, or colour differs. Exact compare (lines 85-91).
- `containerValuesChanged(v, i)`: trimmed names differ, or visualType differs, or spaceId differs (lines 101-107).

Tests (`src/ui/spaces/__tests__/spaceSetup.test.ts`):
- containerLabel name/code; byContainerLabel on `['drawer by the oven', null BOX-4F2A, 'Étagère', 'Attic box']` → `['Attic box','BOX-4F2A','drawer by the oven','Étagère']`.
- taken names: `[' garage ', 'Kitchen']` → `'Garage'` and `'KITCHEN'` taken, `'Loft'` not.
- labelsInSpace: `(0, [a, nil, b])` → 2; `(3, [a])` → 3.
- spaceDeleteBody: `(3,21,2)` → `'This also deletes 3 containers and 21 items, and unlinks 2 QR labels. This cannot be undone.'`; `(1,1,0)` → `'This also deletes 1 container and 1 item. This cannot be undone.'`; `(1,0,1)` → `'This also deletes 1 container and 0 items, and unlinks 1 QR label. This cannot be undone.'`; `(0,0,0)` → `'This space is empty.'`.
- containerDeleteBody: `(5,true)` → `'This also deletes 5 items and unlinks its QR label. This cannot be undone.'`; `(1,false)` → `'This also deletes 1 item. This cannot be undone.'`; `(0,true)` → `'This container is empty. Its QR label will be unlinked.'`; `(0,false)` → `'This container is empty.'`.
- spaceValuesChanged ignores `' Garage '` and notices name/icon/colour changes. containerValuesChanged ignores a trailing space and notices a new name, an emptied name, a type change and a space change.

### 2.7 Place matching and recent places

`src/ui/placeMatch.ts`:
- `PlaceOption {id, name?, shortCode, visualType, spaceId, spaceName, spaceColor, spaceIcon, itemCount}` (lines 6-16).
- `compact(s) = lowercased → NFKD → strip U+0300–U+036F → remove everything that is not \p{Letter} or \p{Number}` (`compactAlphanumeric`, `src/core/tokenize.ts:8,55-61`). Swift: `s.lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars`, drop scalars in `0x300...0x36F`, then keep only scalars whose `properties.generalCategory` is one of `.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber`. **Do not use `CharacterSet.letters`**: it also contains every mark category (Mn/Mc/Me), so combining marks outside U+0300–036F (Devanagari vowel signs, for example) would survive in Swift but are removed in JS. `CharacterSet.decimalDigits` alone misses Nl/No.
- `placeTerms(q) = q.split(whitespace).map(compact).filter(nonEmpty)` (lines 34-39).
- `matchesPlace(o, terms)`: empty → true; `hay = compact("\(name ?? "") \(shortCode) \(spaceName) \(typeNames[visualType] ?? "")")`; every term must be a substring of `hay` (lines 48-55).
- `toPlaceOption(container, space?)` copies fields, with `spaceColor = space?.color ?? ''` and `spaceIcon = space?.icon ?? ''` (lines 58-76). `joinPlaceOptions(containers, spaces)` joins by spaceId (lines 79-85).

`src/services/places/recentPlaces.ts` (AsyncStorage key **`places.recent.v1`**, JSON array of container ids):
- `mergeRecent(list, id, max = 6)`: remove `id` and the drop zone from the list; prepend `id` unless it is the drop zone; take the first `max` (lines 16-23).
- `readRecentPlaces()`: memory cache first; else parse storage (non-array or non-strings → `[]`), cap at 6, publish. A cache set while the read is in flight wins. Errors → `[]` (lines 40-54).
- `rememberPlace(id)`: ignores the drop zone; merges into the cache and persists. A storage failure is swallowed (lines 57-66). The only call sites are: Add's successful save (`app/item/new.tsx:547`, the resolved target), a successful move/file (`src/hooks/useMove.ts:134`) and the deep-link sticker bind (`app/c/[token].tsx`, scan area). The doc comment's "new-container pick" is not a separate call: a container created from a picker is remembered only when the Add or Move it was picked for succeeds. The **Link sticker screen in this area does not call it**.
- `useRecentPlaces()` returns the list **as it was when the screen first got it**, and holds it for the screen's lifetime. A place remembered by the closing pick does not reorder the open picker; the next picker sees it (`src/hooks/useRecentPlaces.ts:24-35`).

`src/ui/categoryMemory.ts` (AsyncStorage key **`categories.recent.v1`**, JSON array of strings):
- `saved` (max 20, most recent first, persisted) merged with `seen` (categories seen in lists loaded this session, keyed case-insensitively). The snapshot is `saved` first, then the other seen categories sorted `localeCompare(en, base)` (lines 28-37).
- `rememberCategories(items)` feeds `seen` and is called on every list result, including container contents (lines 76-86).
- `recordCategory(c)`: trim; nil or empty is ignored; move to the front of `saved`, dedupe case-insensitively (key = `trim().toLowerCase()`, first occurrence wins, stored trimmed), cap at 20, persist the whole array (lines 88-100, `mergeSaved` 63-73). A storage failure is swallowed.
- Loading (`loadSaved`, lines 45-61): once per process, on first use of a Category field. A stored value that is not a JSON array is ignored; non-string entries are dropped; the result is `mergeSaved([...savedThisSession, ...stored])`, so categories recorded before the read finished stay in front.
- `suggestCategories(categories, prefix, max = 6)`: key = trim + lowercase; skip empty keys, the exact match, duplicates, and keys that do not start with the typed key; stop at max (lines 106-122).

Tests:
- `src/ui/__tests__/placeMatch.test.ts`: compact `'DRW-7K2M'`→`'drw7k2m'`, `' Tool  chest! '`→`'toolchest'`, `'Küche'`→`'kuche'`, Cyrillic kept; placeTerms `'  drw-7k  garage - '`→`['drw7k','garage']`, `''`→`[]`; matches without the hyphen and with the full code; matches the space name and type name (`'cabinet'`, `'loft box'`); every term must match; empty terms match everything; accent-insensitive; Cyrillic partial match and no false match; joinPlaceOptions adds colour and icon; toPlaceOption with an unknown space gives `''` colour and icon.
- `src/services/places/__tests__/recentPlaces.test.ts`: mergeRecent prepends; moves to the front without duplicates; max 6 (and a custom 3); never stores the drop zone; rememberPlace persists `['a','b']` after a, b, drop-zone, a.
- `src/hooks/__tests__/useRecentPlaces.test.tsx`: an open screen keeps `['a','b','c']` after `rememberPlace('b')`; a newly mounted screen gets `['b','a','c']`.
- `src/ui/components/__tests__/textHelpers.test.tsx` → `suggestCategories`: `'to'` → `['Tools','Toys','Towels']` (dedupes `tools`); the exact `'Tools'` → `[]`; `''` → 6 results.
- `src/core/__tests__/tokenize.test.ts` › "short codes" (used by `containers.create`): "uses an unambiguous alphabet" (200 × `generateShortCode('box')` match `/^BOX-[2-9A-HJ-NP-Z]{4}$/` and the suffix never contains `O I 0 1`); "compares codes ignoring case and dashes" (`normalizeShortCode('box-7k2m') == 'BOX7K2M'`, `normalizeForCodeMatch('BOX-7K2M') == 'box7k2m'`). The rest of that file belongs to the search spec.

### 2.8 Add sheet helpers (`src/ui/add/addSheet.ts`, `src/ui/add/addDraft.ts`)

- `AddPhoto {uri, thumbUri?, width?, height?, byteSize?}`. `toPositiveInt(s)`: an integer > 0, else nil (lines 36-40). `photoFromParams(params)`: nil without `photoUri`; else map the string params (lines 43-52). `photoFromStored(stored)` maps `byteSize nil → nil` (lines 55-63). `photoFiles(photo) = photo ? [uri, thumbUri ?? nil] : []` (lines 68-70).
- `hasDetails(v)`: category, tags or notes non-blank after trim (lines 73-75).
- `formHasContent(v, photo, empty)`: photo present, or non-blank name, or `hasDetails`, or `trim(quantity) != empty.quantity` ("1") (lines 82-93). The place alone does not count.
- `initialAddState(params, draft, empty)` (lines 119-153):
  - `opened = containerId || name || photoUri` is non-empty.
  - Not opened and a draft exists: restore the draft with `restored = true`. If the draft's suggestion was `running` or `refreshing` (`cutOff`): with a photo → suggestion `running` and `recognize = true`; without one → `idle`. Otherwise keep the suggestion and set `recognize = false`.
  - Else: `values = empty` with `name = trim(params.name ?? '')`; `placeId = params.containerId || DROP_ZONE`; `picked = nil`; `photo = photoFromParams`; suggestion is `running` with a photo, else `idle`; `showMore = false`; `restored = false`; `recognize = photo != nil`.
- `whereEntries({param, recentIds, options, selectedId, picked, maxRecent = 3})` (lines 180-218):
  1. The param container first, if known (`source: param`); then the drop zone.
  2. Up to 3 recent ids, skipping `param.id`, the drop zone and ids missing from `options` (`source: recent`).
  3. `selected` = nil for the drop zone; else `options[selectedId]`, or `picked` when `picked.id == selectedId`. If `selected` is not listed, it becomes an extra. If `picked` is not listed and is not `selected`, it becomes an extra too, refreshed from `options` when present.
  4. Extras are **prepended** with `source: picked`, selected first.
- `entryId(e)`: the drop zone → `DROP_ZONE_CONTAINER_ID`, else the option id.
- `resolvePlace(selectedId, options?, picked?)` (lines 237-248): the drop zone → `(id, nil)`. A known option or matching picked → `(id, option)`. `options == nil` (loading or failed) → `(id, nil)`. Otherwise the container is gone → **`(DROP_ZONE, nil)`**, so the item saves to the drop zone.
- `containerTitle(o) = o.name ?? o.shortCode`.
- `saveA11yLabel(place)`: the drop zone → `strings.add.saveA11yDropZone`; no option → `strings.add.save`; else `strings.add.saveA11y(o.name ?? strings.a11y.labelCode(spellCode(code)), spaceName)` (lines 256-261).
- `savedMessage(place)`: the drop zone → `strings.add.savedInDropZone`; no option → `strings.add.saved`; else `strings.add.savedIn(containerTitle, spaceName)` (lines 264-268).
- Draft slot (`addDraft.ts`): **in memory only**, one slot `{owner, draft + savedAt}`. `DRAFT_TTL_MS = 1_800_000`. `isDraftFresh = now − savedAt <= TTL`. `restorableDraft(now)` has no side effects. `discardStaleDraft(now)` deletes a stale draft's photo files and clears the slot. `keepDraft(owner, draft?)`: nil clears only the owner's own slot; a new draft replaces the slot and deletes the old draft's photo files unless the new draft carries the same `photo.uri`. `clearDraft(owner)` clears only the owner's slot and never deletes the photo (lines 20-68).

Tests:
- `src/ui/add/__tests__/addSheet.test.ts`: toPositiveInt (`'1400'`→1400; `undefined`, `''`, `'0'`, `'-3'`, `'2.5'`, `'wide'` → nil); photoFromParams maps and drops an unparseable byteSize; photoFromStored drops a nil size; photoFiles `[]`, `['a','b']`, `['a', nil]`; formHasContent (blank no; name, notes, quantity `'0'`, photo yes); hasDetails; initialAddState from the tab bar (empty, drop zone, idle); from a container plus a name from search; a camera photo → running + recognize; a draft restored only on a plain open; cut-off recognition restarts with a photo and drops to idle without one; an applied suggestion is kept; whereEntries (drop zone plus up to 3 existing recents `['drop','recent:shelf','recent:bin','recent:bag']`; param first without repeating; a picked place on top; a picked place stays after choosing another `['picked:crate','picked:new','drop']`; no repeat of a listed picked place); resolvePlace (drop zone, listed, loading keeps the id, a picked new place, gone → drop zone); labels (`containerTitle`, `saveA11yLabel` → `'Save to the drop zone'`, `'Save in Drawer by the oven, Kitchen'`, `'Save in label B I N, 4 F 2 A, Loft'`, `'Save'`; `savedMessage` → `'Saved in the drop zone.'`, `'Saved in Drawer by the oven (Kitchen).'`, `'Saved in BIN-4F2A (Loft).'`, `'Saved.'`).
- `src/ui/add/__tests__/addDraft.test.ts`: restorable for exactly 30 min, not after; a stale draft's photo is deleted (both files) and a fresh one is kept; a replaced draft's photo is deleted unless carried over; only the owner clears it; `clearDraft` never deletes the photo.

### 2.9 Codes and spelling

- `spellCode(code)`: split on `-`; each group trimmed, its characters space-separated; drop empty groups; join with `", "` (`src/ui/a11y.ts:23-29`). Tests (`src/ui/__tests__/a11y.test.ts`): `'DRW-7K2M'`→`'D R W, 7 K 2 M'`; `'BOX1'`→`'B O X 1'`; `'-AB--C-'`→`'A B, C'`. The `whereSpoken` and `quantitySpoken` tests are in the same file (rows and lists area).
- `src/ui/code.ts` (household and recovery codes, Crockford base32; used by CodeInput in the household and backup areas):
  - `normaliseCode(s)`: remove `[\s-]+`, uppercase, `I` and `L` → `1`, `O` → `0` (lines 14-20).
  - `invalidCodeChars(n)`: unique characters not matching `^[0-9A-HJKMNP-TV-Z]$`, in first-seen order (lines 23-25).
  - `formatCode(n)`: groups of 5 joined by `-` (lines 28-30).
  - Tests (`src/ui/__tests__/code.test.ts`): `' mmwky-m2h78 '`→`'MMWKYM2H78'`; newlines and tabs are dropped; `'il0o'`→`'1100'`, `'ILO'`→`'110'`; invalid `'U'`→`['U']`, `'ABUU!'`→`['U','!']`; format `''`, `'MMWKY'`, `'MMWKYM2H78A'`→`'MMWKY-M2H78-A'`.

### 2.10 Space colour helpers used by pickers (`src/ui/color.ts`; tests belong to the theme spec)

- `safeColor(v)`: match `/^#?([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i` after trim (nil/undefined → `''`); 3 or 4 digits: each of the **first 3** digits doubled (the 4th, alpha, dropped); 8 digits: the first 6 kept; returns `#RRGGBB` uppercase; invalid → `#8A948D` (`src/ui/color.ts:11-23`).
- `onColor(hex)`: whichever of `#FFFFFF` and `#12161C` has the higher WCAG contrast (`src/ui/theme.ts:64-80`). It is used for the swatch checkmark.
- The space tile fill is a 24 % mix of the space colour over the surface, with a border of the colour at alpha 0.45 (`src/ui/components/SpaceTile.tsx`). Under the fully native direction this is optional styling (§4.12).

---

## 3. Screens

### 3.1 Add an item: `/item/new` (`app/item/new.tsx`)

**Purpose.** Add an item fast. A name is enough. The place defaults to the drop zone. An optional photo runs AI recognition in the background; recognition only fills blanks and never blocks saving. A draft survives a swipe-down. "Save and add another" supports runs.

**Entry points and params** (lines 139-147). `containerId` comes from the container screen "Add here" (§3.7). `name` comes from search (another area). `photoUri`, `photoThumbUri`, `photoWidth`, `photoHeight` and `photoBytes` come from single-mode capture (capture area). A plain tab-bar Add has no params.

**State** (lines 158-185):
- `initial = initialAddState(params, restorableDraft(now), EMPTY_ITEM_FORM)`, computed once.
- `values`, `placeId`, `picked`, `photo`, `suggestion`, `showMore`, `collapsedAt` (the details key when "More details" was collapsed), `restored`, `step: form | place`, `saving: save | another | nil`, `nameError`, `problem {cause}`, `savedNext` (bool).
- Refs: `savingRef` (synchronous double-submit guard), `cameraOpenRef`, `recognitionRef` (the uri recognition is running for), and the draft owner id (unique per sheet instance).

**Data** (lines 189-212):
- `recentIds = useRecentPlaces()`.
- Query key `'add-places'`: `Promise.all(containers.listAllWithSpace(), spaces.listWithCounts())` → `joinPlaceOptions` → `options: [id: PlaceOption]` (nil until loaded).
- `paramId = params.containerId` when non-empty and not the drop zone. `paramOption = options[paramId]`.
- `place = resolvePlace(placeId, options, picked)`.
- `entries = whereEntries({param: paramOption, recentIds, options ?? [:], selectedId: place.id, picked})`.
- `typedName = trim(values.name)`, `hasContent = formHasContent(values, photo, EMPTY)`, `staleName = staleSuggestionName(suggestion, typedName)`.
- `detailsKey = [category, tags, notes].joined("\u{0}")`.
- `detailsShown = showMore || (hasDetails(values) && detailsKey != collapsedAt)`. Details are visible when filled, unless collapsed over exactly these values. A suggestion that changes them reopens the section.

**Lifecycle effects:**
- On mount, if not restored → `discardStaleDraft(now)` (lines 221-223).
- On every change → `keepDraft(owner, hasContent ? {values, placeId, picked, photo, suggestion, showMore, savedAt: now} : nil)` (lines 226-233).
- If `initial.recognize` → `runRecognition(initial.photo.uri, trim(initial.values.name) or nil)` (lines 275-285).
- Focus on arrival: only when `initial.photo == nil`. Focus the name field after the sheet's present transition ends, or after a 700 ms fallback, whichever comes first, and only if the sheet is still the focused screen (lines 290-310). **Native:** `.task { try? await Task.sleep(for: .milliseconds(350)); focus = .name }` or `.defaultFocus`. The RN transition dance is a workaround.

**Recognition** `runRecognition(uri, nameHint?, overwrite = false)` (lines 247-273):
1. `recognitionRef = uri`. `result = await recognizeItem({imageUri: uri, nameHint})` (AI area).
2. If `recognitionRef != uri` → drop the answer (the photo was replaced or removed).
3. `failed` → `suggestion = .failed(reason)`.
4. Success → `values = applySuggestion(current, result.suggestion, overwrite)`, applied to the **latest** values. Then `suggestion = overwrite && nameHint != nil ? .refreshed(forName: nameHint) : .applied(confidence, forName: suggestion.name ?? '')`.

The callers set `running` or `refreshing` themselves.

`SuggestionState` (`src/ui/components/SuggestionBanner.tsx:5-19`): `idle | running | applied(confidence, forName) | stale(forName) | refreshing | refreshed(forName) | failed(reason)`. `staleSuggestionName(state, typed)`: only for `applied`/`refreshed`; trim; empty or equal to `forName` (exact, case-sensitive) → nil; else the trimmed typed name (lines 30-37). **`stale` is never stored.** The screen keeps `applied`/`refreshed` in state and renders the banner with `staleName != nil ? .stale(forName: staleName) : suggestion` (`app/item/new.tsx:715`), so staleness follows every keystroke, including a name typed before the first answer arrived. The draft therefore never holds `stale`. Banner copy (lines 45-130):
- running → `strings.suggestions.running`; refreshing → `.refreshing`.
- applied → title `.applied`, body `.check`; refreshed → title `.refreshed(name)`, body `.check`.
- stale → title `.stale(name)`, body `.staleBody`, action `.update` (hint `.updateHint`), not a live region.
- failed → title `.failed`, body `.failedBody[reason]`, action `.retry` unless the reason is `not_configured`.

**Photo actions:**
- `takePhoto` (lines 385-405): guard `savingRef || cameraOpenRef`; dismiss the keyboard; open capture for a result with `{containerId: place.id, mode: 'single', request}`. On a photo: `photo = photoFromStored`, `suggestion = .running`, `runRecognition(uri, typedName or nil)`.
- `photoOptions` (lines 407-421; ignored while saving): action sheet with `strings.add.retake` (`dropPhoto()` then `takePhoto()`) and `strings.add.removePhoto` (destructive → `dropPhoto()`).
- `dropPhoto` (lines 374-379): `recognitionRef = nil`; delete both photo files; `photo = nil`; `suggestion = .idle`.
- The suggestion banner shows only when there is a photo. Retry → `.running` and recognition with `typedName or nil`. Refresh, only offered when `staleName` is set → `.refreshing` and `runRecognition(uri, staleName, overwrite: true)` (lines 713-732).

**Place selection:**
- "Where it goes" (`strings.add.where`) is a `WhereList` (§4.4): rows for the entries, a checkmark on `place.id`, and a final "Somewhere else…" row.
- Choosing an entry → `haptics.choice`, `placeId = entryId(entry)` (lines 349-352).
- "Somewhere else…" (ignored while saving) → `step = .place`, which swaps the sheet to `PlacePicker(mode: 'choose', showDropZone: true, selectedContainerId: place.id, onPick: pickPlace)` (lines 614-628). `allowNewContainer` defaults to true here, so "New container in X…" and the no-spaces "make a space" flow (§4.1) work from Add. The created container comes back as `picked`. Title `strings.add.placeTitle`; the header left becomes the `strings.add.back` button.
- `pickPlace`: drop zone → `placeId = DROP_ZONE`; container → `placeId = option.id`, `picked = option`; then back to the form (lines 354-362).
- In the place step, a swipe-down, Back or the Back button returns to the form without changing the place, except while the phone is "revoked" (lines 327-331).
- The step swap cross-fades for 180 ms (ease-out cubic), with no animation under Reduce Motion (lines 313-325).
- While the places read is loading, or after it failed with nothing loaded, `whereEntries` gets an empty options map, so the list shows only the drop zone, plus `picked` when set. The param container and recents appear once the read lands. On failure with no data: an info banner `strings.add.placesFailed` with `strings.common.tryAgain` → reload, shown above the list (lines 738-748).
- **Native:** make the place step a push inside the sheet's NavigationStack (`NavigationLink` / `navigationDestination`). The system back button and swipe-back then give the "return without change" behaviour for free.

**Fields:**
- Name: label `strings.add.nameLabel` ("What is it?"), spoken `strings.add.nameA11y`, placeholder `strings.add.namePlaceholder`, `.sentences` capitalisation, return key "Done". Return **saves** (`save(false)`) and the keyboard stays up. The trailing accessory is a 40 pt photo thumbnail (opens photo options, a11y `strings.add.photoOptions`) when there is a photo, else a camera button (a11y `strings.add.addPhoto`) (lines 668-701).
- Typing a non-blank name clears `nameError` and `savedNext` (lines 343-347).
- `savedNext` banner under the name: `strings.add.savedNext` with a check icon (lines 704-711).
- How many: label `strings.add.howMany`. Compact `QuantityStepper` with `value = parseQuantityInput(values.quantity) ?? 1`. `onChange(next)` sets `values.quantity = String(next)` on the latest values. `itemName = typedName or nil`. `commitWhileTyping = true` (lines 759-777).
- "More details" toggle: `strings.forms.moreDetails`, a11y `strings.forms.moreDetailsA11y(expanded)`, chevron down or right. `toggleDetails`: shown → `showMore = false`, `collapsedAt = detailsKey`; hidden → `showMore = true` (lines 364-371,781-793). When shown: `ItemDetailsFields` (§4.6).
- "Snap several at once…" (`strings.add.snapSeveral`): ignored while saving; dismiss the keyboard; **replace** this sheet with capture `{containerId: place.id, mode: 'fast'}`. The draft keeps the typing (lines 456-461).

**Header** (lines 584-612): title `place step ? strings.add.placeTitle : paramOption ? strings.add.titleTo(containerTitle(paramOption)) : strings.add.title`. Interactive dismiss is disabled while saving. Header left in the form step is "Cancel" (`strings.common.cancel`).

**Cancel** (lines 438-454; ignored while saving): if `hasContent` → `confirm(strings.add.discardTitle, strings.add.discardBody, confirm: strings.forms.discard, cancel: strings.forms.keepEditing)`. Discard → `recognitionRef = nil` and delete the photo files. Then `clearDraft(owner)` and close.

**Swipe-down or system back keeps the draft** (no confirm). The next plain Add within 30 min restores it and shows the info banner `strings.add.draft` with action `strings.add.clearDraft`. `clearRestored` (ignored while saving) drops the photo, resets values, place (drop zone), picked, showMore, collapsedAt, restored, nameError and problem, then focuses the name (lines 424-436,655-666).

**Save** `save(andAnother)` (lines 498-582):
1. Guard `savingRef`. `validateItemForm(values)`. If invalid: when the name is missing → `nameError = strings.add.nameRequired` and focus the name. Return (a quantity error has no UI; the stepper always writes valid numbers).
2. `target = place` (resolved), `addedPhoto = photo`; `savingRef = true`; `saving = andAnother ? .another : .save`; clear `problem` and `savedNext`.
3. `item = await items.create({containerId: target.id, name, category, tags, quantity, notes, photo: addedPhoto})`. Item, photo and tags are written atomically.
4. **Failure:** `described = describeError(cause,'save','container')`; `logError('item_create_failed', {errorClass})`; `haptics.error`; release the guard. If still focused → `problem` banner (`SaveNotice` subject `container`; a 404 means the container went). Else → error toast `described.body`. The draft keeps everything.
5. **Success:** `logEvent('item_created', {hasPhoto, suggestionAccepted: applied|refreshed, hinted: refreshed})`; `clearDraft(owner)` (the item owns the photo now); `invalidate`; `haptics.success`; `rememberPlace(target.id)`; `recordCategory(parsed.category)`.
   - `andAnother && no photo && focused` → release the guard, `startNext()` (values empty, suggestion idle, showMore false, collapsedAt nil, restored false, scroll to top (animated unless Reduce Motion), focus the name), `savedNext = true`. No toast (lines 463-472,551-564).
   - `andAnother && photo && focused` → **replace** the sheet with capture `{containerId: target.id}`, with **no `mode` and no `request`**. The capture screen then starts in its default single mode (`app/capture/index.tsx:90-92`) and opens a fresh Add with the photo params (capture area). No toast. The guard stays set (lines 565-569).
   - `andAnother` but no longer focused → falls through to the close-and-toast path below.
   - Otherwise → close if focused, then toast `savedMessage(target)` with an Undo action (`strings.common.undo`, a11y `strings.add.undoA11y(parsed.name)`) → `undoAdd(item.id, addedPhoto)` (lines 571-581).

**Undo add** (lines 475-491): `result = items.delete(itemId)`; delete files `[...result.orphanedPhotoUris, ...photoFiles(addedPhoto)]`; `logEvent('item_deleted')`; invalidate; `haptics.undo`; toast `strings.add.removedAgain`. On failure: `logError('item_delete_failed', {errorClass})`, `haptics.error`, error toast `strings.add.undoFailed(kind == offline)`.

**While saving:** interactive dismiss is disabled and the hardware back is swallowed (lines 333-341). Bottom bar: "Save and add another" (`strings.add.saveAndAnother`, secondary, spinner when `.another`, disabled when `.save`) and "Save" (`strings.add.save`, primary, a11y `saveA11yLabel(place)`, spinner when `.save`, disabled when `.another`) (lines 805-824).

### 3.2 Item detail: `/item/[id]` (`app/item/[id]/index.tsx`)

**Purpose.** Answer "where is it?" first, then small edits. Quantity saves itself. Move or File. Delete. It also runs the "filing run" through drop-zone items.

**Params:** `id`; `filing == '1'` marks a filing run (lines 82-84).

**Data** (lines 96-101): `items.getById(id)` (key `item:<id>`). Only when filing: `items.listUnsorted()` (key `drop-zone`), giving `waitingIds`. `now` refreshes every 60 s while focused (`useNow(60_000)`).

**Optimistic name** (lines 108-116): after naming here, `namedHere = {id, name, over: item.updatedAt}`. The displayed name is `namedHere.name` while `namedHere.id == id && (stored.name is empty || stored.updatedAt == namedHere.over)`; otherwise `stored.name`. `item = stored` with that name. `inDropZone = item.containerId == DROP_ZONE`.

**States** (lines 275-301): no item → `cause` → ErrorState(subject item, retry); loading → skeleton; loaded nil → ErrorState(cause nil → `strings.errors.gone.item` + body, secondary `strings.common.goBack` → back, or the Home tab if nothing to pop).

**Layout (information architecture)** (lines 303-424):
1. Refresh-failed banner (§0.3).
2. Identity: an 88 pt thumbnail (`photoThumbUri ?? photoUri`). When `photoUri ?? photoThumbUri` exists it is tappable and opens `/item/[id]/photo`; a11y `strings.item.photoA11y(name)` or `photoA11yUnnamed`. Beside it:
   - `naming` → `NameItInline` (§3.3).
   - else the name as a header, plus the category (if any) in secondary text.
   - `naming = name == '' || namingId == id`: the field stays while it is in use (focused or holding text), even after a name arrives (lines 162-164).
3. `WhereCard` (§4.3) with Move / File.
4. Quantity card: label `strings.quantity.label` and a large `SavedQuantityStepper` (§4.8).
5. Facts card, only if there are tags or notes: "Tags" (`strings.forms.tagsLabel`) as display chips, "Notes" (`strings.forms.notesLabel`) as text.
6. "Edit details" button (`strings.item.editDetails`, a11y `strings.item.editDetailsA11y(name)` when named) → push `/item/[id]/edit`.
7. Caption `itemStamp(createdAt, updatedAt, now)`.
8. Separated by a rule: destructive "Delete item…" (`strings.item.delete`, a11y `strings.item.deleteA11y(name)`, spinner while deleting).

Header right: Search button (focuses Home search; other area). Header title: in a filing run, while the title is not collapsed and `waitingIds.contains(id)` → `strings.item.progress(waitingIds.count)` ("N waiting" / "Last one waiting"; the count includes this item) (lines 263-273). Otherwise the collapsing title (§0.11) is `name`, or `strings.entities.unnamedItem` when the item has no name (`useCollapsingTitle(name || strings.entities.unnamedItem)`, lines 119-121).

**Move / File** `moveOrFile` (lines 178-219), behind a busy guard:
1. `runStep = filing && inDropZone`; `before = waitingIds` (drop-zone order at start).
2. If `naming` → `await nameField.commit()`. If false (the save failed and the field says why) → stop. Nothing moves.
3. Open Move for a result: push `/item/[id]/move` with `{id, request}` and `filing: '1'` when `runStep`.
4. No result or not a run step → done (the screen re-reads on focus; the move sheet showed the toast).
5. `waiting = result.waiting`, or on absence re-read `listUnsorted().ids`; if that throws → `before.filter { $0 != id }`.
6. If no longer focused → stop.
7. `next = nextInRun(before, id, waiting)`. Next → **replace** with `/item/<next>?filing=1`; else back if possible, else the Drop zone tab.

**Filing-run accessibility** (lines 134-157,166-171): wait for the push transition (or 700 ms), then autofocus the name field (`autoFocus: filing && arrived`). With VoiceOver on, move focus to the title once. After naming, VoiceOver focus moves to "File it…" (drop zone) or "Edit details". **Native:** `@AccessibilityFocusState`.

**Delete** `deleteItem` (lines 221-260), behind the busy guard:
1. `confirm(title: name ? strings.item.deleteTitle(name) : strings.item.deleteTitleUnnamed, body: household paired ? strings.item.deleteBodyPaired : strings.item.deleteBodyLocal, confirm: strings.common.delete)`.
2. `deleting = true`; `result = items.delete(id)`.
3. `result.deleted` → delete the orphaned photo files, `logEvent('item_deleted')`, message `strings.item.deleted(name)` / `deletedUnnamed`. Else (another phone deleted it) → `strings.item.alreadyDeleted(name)` / `alreadyDeletedUnnamed`.
4. Go back **before** invalidating (only if still focused), so the screen does not re-read into "gone". Then invalidate and toast.
5. Failure → `deleting = false`, `logError('item_delete_failed')`, `haptics.error`, error toast `strings.item.deleteFailed(offline)`.

### 3.3 NameItInline (`src/ui/item/NameItInline.tsx`)

The "What is it?" field in place of the title of an unnamed item (Quick Snap captures).
- Props: `item {id, updatedAt}`, `incomingName` (the stored name or `''`), `autoFocus`, heading ref, `onEngagedChange(Bool)`, `onNamed(name)`. It exposes `commit() async -> Bool` (lines 17-47,175-185).
- Heading `strings.item.nameIt.label` (a header). Field placeholder `strings.item.nameIt.placeholder`, spoken label `strings.item.nameIt.a11y` (+ `strings.forms.errorA11y(error)`), return key "Done" submits and the keyboard stays up (lines 191-243).
- Engaged = focused or holding typed text. It reports via `onEngagedChange` unless already named (lines 109-111).
- `theirs = meanwhile != nil && meanwhile.updatedAt > item.updatedAt ? meanwhile.name : incomingName`. `offered = theirs != '' && theirs != trim(value) ? theirs : nil`. Notice: `meanwhile != nil ? strings.item.nameIt.namedMeanwhile(offered) : strings.item.nameIt.justNamed(offered)`. It is announced on iOS (lines 94-106).
- `save()` (lines 129-170): empty → error `strings.forms.itemNameRequired` (announced), return false. Guard double submit. `lock = max(meanwhile?.updatedAt ?? 0, item.updatedAt)`. `attemptName(repos.items, {id, lock}, name)`:
  - named → `logEvent('item_updated')`, `finish(name)` (dismiss the keyboard, `onNamed`), invalidate, return true.
  - namedMeanwhile → `haptics.warning`, `meanwhile = {name, updatedAt}`, invalidate. The typed text and keyboard stay.
  - gone → invalidate (the screen shows "gone").
  - failed → `logError('item_name_failed', {errorClass})`, `haptics.error`, error `strings.item.nameIt.failedOffline` if offline else `strings.item.nameIt.failed`.
- Buttons: "Save name" (`strings.item.nameIt.save`, secondary, spinner while saving). When `offered` exists: "Use “X”" (`strings.item.nameIt.useName(offered)`), which calls `finish(offered)` with no write, disabled while saving (lines 260-281).
- `commit()`: typed `''` → true (nothing to save); typed `== theirs` → `finish` and true; else `save()`.

### 3.4 Edit details: `/item/[id]/edit` (`app/item/[id]/edit.tsx`)

**Purpose.** Edit name, category, tags and notes, all visible. Quantity is **not** here (the stepper owns it), and neither is the place (that is Move). Saves use an optimistic lock and handle conflicts.

**Data:** `items.getById(id)` (key `item:<id>`).

**Seeding** (lines 126-144): once per item id, during render. `seed = {id, values: detailsSeed(stored), base: {updatedAt, values}}`, and `values = seeded`. A background re-read never overwrites typing.

**Dirty guard:** `dirty = detailsDirty(values, seed.values)`; `useDirtyGuard(dirty && !gone, saving)` (§4.18) (lines 155-156).

**Fields:**
- A read-only 56 pt photo thumbnail (`thumb ?? full`) beside the name. Photos cannot be replaced here (lines 284-294).
- Name: label `strings.editItem.nameLabel`, placeholder `strings.item.nameIt.placeholder`, `required = seed.values.name != ''` (an unnamed item may stay unnamed), error, `.sentences`, return → Category (lines 159,296-310).
- `ItemDetailsFields` (§4.6).
- Bottom bar: `strings.editItem.save` (spinner while saving).

**Header:** a custom Cancel (`strings.common.cancel`), disabled while saving (lines 59-86,231). Close is guarded by `useDirtyGuard`.

**Save** (lines 161-229):
1. Guard. `unnamed = keepsUnnamed(seed.values.name, values.name)`. Validate `{...values, name: unnamed ? strings.entities.unnamedItem : values.name, quantity: String(stored.quantity)}`. Invalid → `nameError = errors.name ? strings.forms.itemNameRequired : nil`, focus the name, return.
2. `saving = true`; clear problem and nameError. `outcome = attemptDetails(items, id, {name (omitted when unnamed), category, tags, notes}, seed.base)`.
3. `saved` → `logEvent('item_updated')`, `recordCategory(category)`, close if focused, invalidate, toast `strings.editItem.saved`. `saving` stays true so the guard lets the sheet close.
4. `gone` → `haptics.error`, `gone = true`. The screen shows ErrorState(nil, item) with secondary `strings.common.close`.
5. `conflict(theirs)` → `values = rebaseDetails(current, seed.values, theirs.values)`; `seed.values = theirs.values`; `seed.base = theirs`; `haptics.warning`; warning banner `strings.editItem.conflict` (assertive).
6. `failed(cause)` → `logError('item_update_failed', {errorClass})`, `haptics.error`. Warning banner: offline → described title + body; else `strings.editItem.notSaved` (lines 91-101).

**States:** `gone || stored == nil`: a cause → ErrorState retry; loading → skeleton; else ErrorState(nil, item, secondary Close) (lines 233-258).

### 3.5 Move or File: `/item/[id]/move` (`app/item/[id]/move.tsx` + `src/hooks/useMove.ts`)

**Purpose.** Pick a destination container for one item. The current container is shown as "Here now" and is disabled. On success it closes and shows a toast with Undo. It never navigates into the destination.

**Params:** `id`, `filing == '1'`, `request?`. **Data:** `items.getById(id)` (key `item:<id>`).

**Title** (lines 17-20,109): `filing || inDropZone ? (name ? strings.move.titleFile(name) : strings.move.titleFileUnnamed) : (name ? strings.move.titleMove(name) : strings.move.titleMoveUnnamed)`. Empty while loading.

**Body:**
- No item: a cause → ErrorState retry; loading → skeleton; else ErrorState(nil, item, secondary Close).
- Item: an optional warning banner (`move.notice.message`, assertive; with a Close action when `kind == gone`), then `PlacePicker(mode: inDropZone ? 'file' : 'move', currentContainerId: item.containerId, busyId, onPick: pick)` (lines 57-103).
- While a pick is writing (`busyId != nil`), interactive dismiss is disabled and back is swallowed. The header Cancel still closes; the move then finishes with its toast and navigates nowhere (lines 47-55,110).

**`useMove({item, request, filing})`** (`src/hooks/useMove.ts:72-187`):
- `current = newer(item, reread)` by `updatedAt` for the same id (lines 55-58).
- Unmount → `abandonResult(request)`.
- `pick(place)`:
  1. Ignore the drop zone, a missing item, busy (`busyRef`), or a target equal to the current container.
  2. `busyRef = true`, `busyId = target.id`, clear the notice. `outcome = attemptMove(repos.items, current, target.id)`. On `moved` the guard is **never released** (the sheet is closing; a second pick can't run). Every other outcome releases it (`busyRef = false`, `busyId = nil`) before setting the notice (lines 168-169).
  3. **moved:** `move = MoveResult{itemId, from: before.containerId, to: target.id, updatedAt: outcome.updatedAt}`; `logEvent('item_moved')`; `haptics.success`; `rememberPlace(target.id)`. If `filing && fromDropZone` → `after = afterFiling(...)`, `move.waiting = after.waiting`, `moreWaiting = after.moreWaiting`, all while the spinner shows. Then `deliverResult(request, move)`; close if focused (before invalidating); `invalidate`; toast `movedMessage({fromDropZone, filing, moreWaiting, container: containerLabel(target), space: target.spaceName})` with Undo (a11y `strings.move.undoA11y(name)` / `undoA11yUnnamed`) → `undo(move)`.
  4. **gone** → notice `{gone, strings.move.gone}`, `haptics.error`.
  5. **movedElsewhere(fresh)** → `reread = fresh` (so "Here now" follows it), notice `movedElsewhereMessage(fresh)`, `haptics.warning`.
  6. **failed** → `logError('item_move_failed')`, notice `moveFailedMessage(cause)`, `haptics.error`.
  7. Nothing is invalidated on failure.
- `undo(move)` (lines 89-108): `attemptUndo` → undone: `logEvent('item_move_undone')`, invalidate, `haptics.undo`, toast `strings.move.undone`. Otherwise: conflict → `haptics.warning`, others → `haptics.error`; `logError('item_move_undo_failed', {outcome, errorClass?})`; error toast `undoFailedMessage(outcome)`; invalidate.

### 3.6 New container: `/container/new` (`app/container/new.tsx`)

**Purpose.** Create a container in a known space. The type is required (default `box`); the name is optional, and an unnamed container goes by its code. On success it opens the new container (replacing this sheet), or hands it back to a waiting place picker.

**Params:** `spaceId`, `request?`. Unmount → `abandonResult(request)` (line 37). `spaceId == drop-zone-space` → the locked state (line 40).

**Data:** `spaces.getById(spaceId)` (key `space:<id>`). Loaded nil (deleted elsewhere) → ErrorState(nil, space, secondary `strings.common.goBack`) (lines 112-124). While loading, or when the read **failed**, the form still renders, just without the context line, and Create still works. There is no error state for a failed space read (lines 113, 141).

**Fields** (lines 141-173):
- Context line (when the space is loaded): a space pip and `strings.containerForm.inSpace(space.name)`.
- `TypeGrid` (label `strings.containerForm.typeLabel`). A change clears the failure banner.
- Name: label `strings.containerForm.nameLabel` + `strings.forms.optional` suffix, placeholder `strings.containerForm.namePlaceholder`, hint `strings.containerForm.nameHint`, return "Done" → save. Typing clears the failure banner. No validation at all: a blank name creates an unnamed container.
- Bottom bar: `strings.containerForm.create` (spinner while saving).

**Dirty guard:** `trim(name) != '' || visualType != 'box'`, with saving (line 66).

**Save** (lines 68-110): guard (ref) → `containers.create({spaceId, name, visualType})`. The repository trims the name and stores blank as NULL.
- Success: `logEvent('container_created')`, invalidate, `haptics.success`. If not focused (closed mid-save) → toast `strings.containerForm.created(containerLabel(container))` and stop. Else `delivered = deliverResult(request, NewContainerResult{containerId, name, shortCode, visualType, spaceId})`; delivered → close; else **replace** with `/container/<id>`.
- Failure: release, `haptics.error`; focused → `SaveNotice(cause, container)` banner; else error toast `strings.containerForm.notCreated(isOffline(cause))`.

### 3.7 Container detail: `/container/[id]` (`app/container/[id]/index.tsx`)

**Purpose.** "What's in this box?" This is where a scanned label lands. It shows the space crumb, title, type and count, the code tape, the QR label entry, and the contents with a compact stepper on each row. Add and photo actions sit at the bottom.

**Data** (lines 174-183):
- `containers.getWithCounts(id)` (key `container:<id>`) → `ContainerWithCounts` (including `itemCount`, `qrToken`).
- `items.listByContainer(id)` (key `items-of:<id>`).
- `spaces.getById(container.spaceId)` (key `space:<spaceId|none>`).
- `sorted = sortContents(items)`. `rememberCategories(items)` on each result.

**Blocking states** (lines 224-253):
- container nil + cause → ErrorState(container, retry all three).
- container nil + loading → skeleton.
- container loaded nil → ErrorState(nil, container, secondary `strings.common.goToSpaces` → Spaces tab).
- items nil without a cause → skeleton. Nothing renders until both reads are in, so the screen never flashes "empty".

**Header region** (lines 255-317):
- Space crumb, a link: pip, space name, chevron; a11y `strings.container.crumbA11y(space)`; → `openSpace`. The data comes from the space read, else from the first sorted row's `spaceId/spaceName/spaceColor`. Without either: a 48 pt placeholder, unless the space read failed.
- Title `titleOf(container)`.
- Sub line: items loaded and empty → `typeNameOf(visualType)` only; else `strings.container.sub(typeName, count)`, where `count = items?.count ?? container.itemCount`.
- Code row: a large tape with the short code (a11y `strings.a11y.labelCodeTitle(spellCode(code))`) and a small secondary button with a QR icon. Label `qrToken != nil ? strings.container.qrLinked : strings.container.qrNone`; a11y `strings.container.qrLinkedA11y` / `qrNone`; → push `/container/[id]/qr`.
- Refresh banner if the container or items refresh failed.
- Section header `strings.container.inHere` with the count, when there are items.

**Rows** (lines 374-395): `ItemRow(line: 'detail', tool: 'stepper')` (rows area). The second line is the item's category. The trailing control is a compact `SavedQuantityStepper` whose errors go to a toast. Tap → push `/item/<id>`. **Arrival highlight:** a row with `isFreshArrival(createdAt, now)` on first appearance gets the selected fill and a 3 pt leading ink bar. It holds 600 ms, then fades over 1200 ms. Under Reduce Motion it holds 1800 ms, then disappears instantly. The decision is made once per row (lines 118-150).

**Empty state** (lines 319-340): items nil (read failed) → ErrorState(cause, retry items). Else an empty state with the type icon, title `strings.container.empty.title(typeName)`, body `strings.container.empty.body`, primary `strings.container.addHere` → `/item/new?containerId=<id>`, secondary `strings.container.takePhoto` → `/capture?containerId=<id>`.

**Bottom bar (only when there are items)** (lines 342-371): a camera icon button (a11y `strings.container.takePhotoA11y`) → capture; primary `strings.container.addHere` → Add.

**Header right:** Search, plus Edit (pencil, a11y `strings.container.edit(title)`) → `/container/[id]/edit` once the container is known (lines 59-73).

**Pull to refresh** reloads all three reads. The spinner shows only for a user pull (`src/ui/spaces/usePullToRefresh.tsx`). **Native:** `.refreshable { await reloadAll() }`, which already behaves that way.

### 3.8 Edit container: `/container/[id]/edit` (`app/container/[id]/edit.tsx`)

**Purpose.** Rename, retype, move to another space, or delete. The code stays the same because it is printed.

**Data:** `containers.getById(id)` (key `container:<id>`), `spaces.listWithCounts()` (key `spaces`).

**Seeding** once per id: `{name: stored.name ?? '', visualType, spaceId}` (lines 80-89). **Dirty:** `containerValuesChanged(values, seed)` while not gone; the guard is passed `saving: busy != nil` (lines 91-94). A change clears the failure unless gone (lines 101-104).

**Fields** (lines 281-318):
- `TypeGrid` (`strings.containerForm.typeLabel`).
- Name: optional, **placeholder = the container's short code**, hint `strings.containerForm.nameHint`, return → save.
- Under the name: a small tape plus the caption `strings.containerForm.codeNote` (a11y `strings.containerForm.codeStays(spellCode(code))`).
- Space (`strings.containerForm.spaceLabel`): `ChoiceList` of all spaces (leading space tile, 32 pt), with a check on the current one. If the spaces failed: a warning banner with the described title and body plus Try again. While loading: a skeleton (lines 224-251).
- Separated: a destructive "Delete container…" (`strings.containerForm.delete`, hint `strings.containerForm.deleteHint`; spinner when deleting; disabled while saving or gone).
- Bottom bar: `strings.containerForm.save` (spinner when saving; disabled while deleting or gone).

**Save** (lines 106-130): guard → `containers.update(id, {name, visualType, spaceId})` with the raw (untrimmed) name. The repository trims and stores an emptied name as NULL. There is no validation, and Save is **not** gated on dirty: tapping it with nothing changed still writes and bumps `updated_at`. No lock, so a concurrent edit is silently overwritten (§0.2). nil → `fail(nil)` (gone). Success → `logEvent('container_updated')`, invalidate, close if focused, toast `strings.containerForm.saved` (the toast shows even when the sheet was already closed).

**fail(cause)** (lines 133-148): release; `haptics.error`. Focused → banner `SaveNotice(cause, container)`, with action `strings.common.goToSpaces` when gone (a nil cause). Not focused → error toast: nil → `strings.containerForm.alreadyDeleted(label)`, else `strings.containerForm.notSaved(label, isOffline)`, where `label = containerLabel(stored)`, or `values.name` when unknown.

**Delete** (lines 155-198):
1. Guard; `busy = delete`; `label = containerLabel(current)`.
2. `impact = containers.deletionImpact(id)`.
3. `confirm(strings.containerForm.deleteTitle(label), containerDeleteBody(impact), strings.common.delete)`. Cancel → release.
4. `result = containers.delete(id)`. Deleted → delete the orphaned photos, `logEvent('container_deleted', {itemCount: impact.itemCount})`.
5. invalidate; **dismiss every modal and pop to the root, then push `/space/<spaceId>`** (`router.dismissAll(); router.push(...)`, lines 179-184), with no focus check and no success haptic. This avoids leaving the deleted container in the stack when it was opened from search or a label. `spaceId` is the stored container's (`current.spaceId`), not the form's possibly edited value.
6. Toast `deleted ? strings.containerForm.deleted(label) : strings.containerForm.alreadyDeleted(label)`.
7. Any throw → release, `haptics.error`, error toast `strings.containerForm.deleteFailed(label, isOffline)`.

**States:** no stored container → cause → ErrorState retry; loading → skeleton; else ErrorState(nil, container, secondary Go to Spaces) (lines 200-222).

### 3.9 QR label: `/container/[id]/qr` (`app/container/[id]/qr.tsx`)

**Purpose.** Show the container's label so it can be printed or shared. Replace or remove it when the sticker is lost. Make one, or link a sticker printed earlier. Every write is caught and reported. The screen never offers "Make" before it knows there is no label, because a wrong "Make" would silently retire a printed sticker.

**Data:** `containers.getById(id)` (key `container:<id>`), `qr.getByContainer(id)` (key `qr-of:<id>`).

**Shown-token logic** (lines 48-62): `written` holds the label this screen last wrote (make, replace or remove). `next = settleWrittenLabel(written, {loading: binding.loading, failed: binding.cause != nil})`. `token = next?.token ?? binding.data?.token`. `known = next != nil`. `wrote(token) → written = {token, reloading:false}`.

**`labelKnown` latch** (lines 111-112): becomes true the first time the binding read succeeds, and stays true.

**Render order** (lines 241-304):
1. container nil: cause → ErrorState(container, retry both); loading → skeleton; else ErrorState(nil, container, secondary Go to Spaces).
2. `!known && binding.data == nil && binding.cause` → ErrorState(binding.cause, container, retry). The screen does not offer "Make".
3. `!labelKnown` → skeleton.
4. Refresh banner if the container refresh failed, or (`!known` and the binding refresh failed).
5. `token == nil` → an empty state with the QR icon, title `strings.qr.none.title(labelOf(container))`, body `strings.qr.none.body`. Primary `strings.qr.make` (spinner while making) → `makeLabel(.make)`. Secondary `strings.qr.link` → push `/container/[id]/link`.
6. Else: the `QrCard` (§5.2), the hint `strings.qr.hint`, a full-width secondary "Share label…" (`strings.qr.share`, spinner while preparing), then the section `strings.qr.problems` with two rows: "Replace label…" (`strings.qr.replace`) and "Remove label…" (`strings.qr.remove`, in destructive red). Both are disabled while busy and show a spinner for their own action (lines 306-360).

**Busy guard:** `begin(action) -> Bool` / `end()` (lines 118-127). Actions are `make | replace | remove | share`.

**makeLabel(action)** (lines 138-173):
- `replace` → `confirm(strings.qr.replaceTitle, strings.qr.replaceBody, strings.qr.replaceConfirm)`. Cancel → end.
- `make` → `current = qr.getByContainer(id)` (look before writing). If one exists → `wrote(current.token)`, reload the binding, toast `strings.qr.alreadyLabelled`, end.
- `made = qr.createAndBind(id)`; `logEvent('qr_generated')`; invalidate; `wrote(made.token)`; `haptics.success`; only for replace → toast `strings.qr.made`.
- Throw → `haptics.error`, error toast `labelFailureMessage(action, cause)`.

**removeLabel** (lines 176-198): `confirm(strings.qr.removeTitle, strings.qr.removeBody, strings.qr.removeConfirm)` → `qr.unbind(id)`. The return value is ignored: false means already gone, the same end state. Then `logEvent('qr_unbound')`, invalidate, `wrote(nil)`, `haptics.success`, toast `strings.qr.removed`. Throw → `labelFailureMessage('remove', cause)`.

**shareLabel**: see §5.3.

Title `strings.qr.title`. The drop zone → the locked empty state.

### 3.10 Link a printed sticker: `/container/[id]/link` (`app/container/[id]/link.tsx`)

**Purpose.** A full-screen camera that binds a scanned sticker to this container. It asks first only when an existing link would stop working. It closes back to the QR screen with a toast.

**Data:** `containers.getWithCounts(id)` (key `container:<id>`), which provides `qrToken`.

**Phase state machine** (lines 25-33):

```
scanning ──scan──▶ checking ──resolveScan throws──▶ failed(cause) ──Try again──▶ scanning
                      │
                      ├─ invalid ──▶ notOurs ──Scan again──▶ scanning
                      ├─ already ──▶ (close + toast strings.link.already(label))
                      ├─ link, confirm ≠ nil ──▶ deciding ──cancel/closed──▶ scanning
                      │                              └─confirm──▶ linking
                      └─ link, confirm = nil ──▶ linking
linking ──bind ok──▶ (close if still open + toast strings.link.linked(label))
linking ──bind throws──▶ failed(cause)  (or error toast strings.link.notLinked(label) if the screen already closed)
```

- The camera is active only when the container is loaded, it is not the drop zone, and the phase is `scanning` or `checking` (lines 111-113). The scanner pauses itself after each scan and re-arms when `active` toggles false → true (scanner component, scan area).
- `openRef` tracks whether the screen is still mounted. A late answer never navigates twice (lines 118-124). Closing while reading writes nothing and says nothing (line 142).
- `link(raw)` (lines 126-182): `label = labelOf(container)`; `plan = planSticker(await qr.resolveScan(raw), container)`. Haptics: invalid → error; already → success; bind ok → success; failures → error. On success: `logEvent('qr_bound')`, invalidate. The confirm uses `plan.confirm` (destructive style).
- The "checking" panel shows only after the phase has stayed `checking` for 180 ms (`useDelayedFlag`, lines 109,238-239).
- Panel precedence (bottom overlay; lines 188-240):
  1. locked → `strings.errors.dropZoneLocked.*` + action to the Drop zone tab.
  2. container read failed → `describeError(cause,'read','container')` + Try again (reload).
  3. container gone → `strings.errors.gone.container` / `strings.errors.gone.body` + Go back.
  4. notOurs → `strings.camera.notOurs.title/body` + `strings.camera.scanAgain`.
  5. failed → `describeError(cause,'read','container')` + Try again (→ scanning).
  6. linking → busy `strings.link.linking`.
  7. checking (after 180 ms) → busy `strings.link.checking`.

  Error panels have a coloured leading bar. Panels are announced on iOS (lines 47-87).
- Scanner title: `strings.link.title(labelOf(container))`, or `strings.link.titlePlain` while loading. The close button → back.

**Native:** `.fullScreenCover`. Use the Scan area's scanner view (VisionKit `DataScannerViewController` with `.barcode(symbologies: [.qr])`, or an AVFoundation metadata output). Panels are an overlay with `.glassEffect()` on iOS 26. Announcements: `AccessibilityNotification.Announcement(text).post()`.

### 3.11 New space: `/space/new` (`app/space/new.tsx`)

**Purpose.** A preset in one tap, or a space of your own (name, icon, colour). Success opens the new space (replacing this sheet), or returns it to a waiting picker.

**Params:** `request?`. Unmount → `abandonResult(request)` (line 152).

**Data:** `spaces.listWithCounts()` (key `spaces`) → `taken = takenSpaceNames(...)`. While it loads or after it fails, every preset stays available (lines 161-164).

**State:** `values = DEFAULTS = {name:'', icon:'🛋️', color:'#5B8DEF'}` (line 42), `nameError`, `failure`, `saving: String?` (a preset name, or `'custom'`).

**Dirty guard:** `spaceValuesChanged(values, DEFAULTS)`, with saving.

**Layout** (lines 228-276):
1. Heading `strings.spaceForm.quickAdd`, then the preset tiles (Garage, Wardrobe, Loft, Cellar). Each tile shows its space tile, its name, and, if taken, the caption `strings.spaceForm.alreadyAdded`. The tile is disabled when taken or when any save runs; it is dimmed only while another save waits. A spinner appears after 150 ms while that preset saves. A11y `strings.spaceForm.presetA11y(name)` or `presetAddedA11y(name)`. Layout is two per row when `!stacked && windowWidth >= 390 × max(fontScale, 1)`, else one per row (lines 50-57,75-132).
2. A divider.
3. Heading `strings.spaceForm.yourOwn`, then `SpaceFields` (§4.17) with `previewMeta = strings.spaceForm.previewNew`.
4. Bottom bar: `strings.spaceForm.create` (spinner when `saving == 'custom'`; disabled while a preset saves).

**Actions:**
- Preset tap → `create(preset, source: preset.name)`.
- `createCustom` (lines 213-220): blank name → `nameError = strings.spaceForm.nameRequired`, focus the name. Else `create(values, 'custom')`. The return key on the name field also calls `createCustom`. **A custom name is not checked against existing names.** A second "Garage" can be created by typing it; only the preset tiles use `taken`.
- `change(next)` (lines 222-226): if the name changed → clear nameError. Always clear the failure.
- `create(input, source)` (lines 168-211): guard (one ref for presets, the button and return). `name = trim(input.name)`. `spaces.create({name, icon, color})`.
  - Success: `logEvent('space_created')`, invalidate, `haptics.success`. Not focused → toast `strings.spaceForm.created(created.name)`. Else `deliverResult(request, {spaceId, name})` ? close : **replace** with `/space/<id>`.
  - Failure: release; `haptics.error`; focused → `SaveNotice(cause, space)`; else error toast `strings.spaceForm.notCreated(name, isOffline)`.

### 3.12 Space detail: `/space/[id]` (`app/space/[id]/index.tsx`)

**Purpose.** One space and its containers, sorted by label. There are no per-container peeks.

**Data:** `spaces.getById(id)` (key `space:<id>`), `containers.listBySpace(id)` (key `containers-of:<id>`). `sorted = containers.sorted(by: byContainerLabel)`, which needs a stable tie-break (§2.6). `itemTotal = Σ itemCount` (lines 80-99).

**States** (lines 113-139): space nil: cause → ErrorState(space, retry both); loading → skeleton; loaded nil → ErrorState(nil, space, secondary Go to Spaces).

**Head** (lines 148-173): a space tile (64 pt), the title `space.name`, and, only when there are containers, the meta `strings.entities.spaceCounts(sorted.count, itemTotal)`. Then the refresh banner if either refresh failed.

**Rows:** `ContainerRow(context: 'space')` (§4.5) → `openContainer`.

**Empty** (lines 176-199): containers nil: cause → ErrorState(retry containers); else skeleton. Empty list → an empty state with the box icon, title `strings.spaces.noContainers.title(name)`, body `.body`, action `.action` → `/container/new?spaceId=<id>`.

**Bottom bar (only with containers):** secondary `strings.spaces.newContainer` (plus icon) → new container.

**Header right:** Search, plus Edit (a11y `strings.spaces.edit(name)`) → `/space/[id]/edit`. Pull to refresh reloads both.

### 3.13 Edit space: `/space/[id]/edit` (`app/space/[id]/edit.tsx`)

**Purpose.** Rename, re-icon or recolour, or delete the space with everything in it.

**Data:** `spaces.getById(id)` (key `space:<id>`), `spaces.listWithCounts()` (key `spaces`; used only for the preview counts).

**Seeding** once per id: `{name, icon, color}` from the stored space (lines 70-75). The initial state before seeding is `{'', '', ''}`. **Dirty:** `spaceValuesChanged(values, seed)` while not gone, with saving (lines 77-80).

**Fields:** `SpaceFields` with `previewMeta = counts ? strings.entities.spaceCounts(counts.containerCount, counts.itemCount) : nil` (nil hides the preview) and `previewFallbackName = stored.name` (lines 213,243-253). Separated: destructive "Delete space…" (`strings.spaceForm.delete`, hint `strings.spaceForm.deleteHint`; disabled while saving or gone). Bottom bar: `strings.spaceForm.save` (disabled while deleting or gone).

**Save** (lines 87-115): guard. Blank name → `nameError = strings.spaceForm.nameRequired`, focus, return. `spaces.update(id, {name: trimmed, icon, color})`; all three fields are always sent. Not gated on dirty: an unchanged Save still writes and bumps `updated_at`. No lock (§0.2). nil → `fail(nil)`. Success → `logEvent('space_updated')`, invalidate, close if focused, toast `strings.spaceForm.saved`.

**fail** (lines 118-133): as for the container, with the name `stored?.name ?? values.name` and the copy `strings.spaceForm.alreadyDeleted(name)` / `strings.spaceForm.notSaved(name, offline)`. The banner action is Go to Spaces when gone.

**Delete** (lines 140-185):
1. In parallel: `impact = spaces.deletionImpact(id)` and `containers = containers.listBySpace(id)`.
2. `labels = labelsInSpace(impact.qrBindingCount, containers)`.
3. `confirm(strings.spaceForm.deleteTitle(current.name), spaceDeleteBody(impact, labels), strings.common.delete)`. Cancel → release.
4. `result = spaces.delete(id)`. Deleted → delete the orphaned photos, `logEvent('space_deleted', {containerCount, itemCount})`.
5. invalidate; go to the Spaces tab (pop everything); toast `deleted ? strings.spaceForm.deleted(name) : strings.spaceForm.alreadyDeleted(name)`.
6. Throw → release, `haptics.error`, error toast `strings.spaceForm.deleteFailed(name, isOffline)`.

`change(next)` clears nameError when the name changed, and clears the failure unless gone (lines 187-191).

---

## 4. Shared components → SwiftUI

### 4.1 PlacePicker (`src/ui/components/PlacePicker.tsx`)

The one place picker, used by Move/File (§3.5), Add's place step (§3.1), the deep-link bind (scan area, mode `bind`) and the Scan tab's typed code (scan area, mode `open`).

**Props** (lines 38-64):
- `mode: move | file | choose | bind | open`.
- `currentContainerId?` (move/file: "Here now").
- `selectedContainerId?` (choose).
- `showDropZone = false`.
- `allowNewContainer = mode != open`.
- `autoFocusFilter = mode == open`.
- `placeholder = strings.picker.filter`.
- `busyId?`.
- `notice?` (banner).
- `onPick(PickedPlace)`, where `PickedPlace = dropZone | container(PlaceOption)`.

**Data** (lines 129-135): `containers.listAllWithSpace()` (key `containers-all`; SQL order `s.name COLLATE NOCASE, c.created_at DESC`) and `spaces.listWithCounts()` (key `spaces`; `name COLLATE NOCASE`). `options = joinPlaceOptions(...)`. `recentIds = useRecentPlaces()`.

**Section building** (lines 139-205), with `terms = placeTerms(query)` and `filtering = trim(query) != ''`:
1. Not filtering, `mode == choose && showDropZone` → a top section with one drop-zone entry.
2. Not filtering → a "Recent" section (`strings.picker.recent`, clock icon): up to **4** recent ids that exist in options, in recent order. The current container is **not** excluded: in move/file mode it can appear here too, as a disabled "Here now" row. The same container then also appears again under its space.
3. `order` = spaces in the spaces-list order, then any space that only appears on a container (so a just-created space still shows).
4. Filtering and nothing matches → if `allowNewContainer` and `order` is non-empty: a single section `strings.picker.newContainerTitle` (plus icon) listing "New container in <space>…" for every space, with the space pip leading. Return.
5. Else for each space: `inSpace = matching.filter(spaceId).sorted(byLabel)`, where `byLabel` compares `name ?? shortCode` with en/base and has no tie-break (keep the input order). `offerNew = allowNewContainer && (!filtering || !inSpace.isEmpty)`. Skip the space if it has no options and no offer. Else a section titled with the space name and pip: its options, then "New container in <space>…" when offered.

**Header area** (lines 305-316): the notice, if any. Spacing above the top section. When filtering, there are options, but no section has an option → the text `strings.picker.noMatch(trim(query))`.

**Rows** (lines 429-552):
- Drop zone: tray tile, `strings.picker.dropZone` + `strings.picker.sortLater`. Selected when `selectedContainerId` is nil or the drop zone; checkmark. Busy → spinner. Radio role.
- New container: a pip (in the "new" section) or a plus, and the text `strings.picker.newContainerIn(space)`. Disabled while busy.
- Option: type tile. Text: the name, or `unnamedContainer(typeName)` in secondary text. Recent rows add the space name as a caption. `hereNow = (move|file) && id == currentContainerId` → caption `strings.picker.hereNow`, disabled, a11y `strings.picker.hereNowA11y(label)`. Otherwise a11y `strings.picker.optionA11y(label, spaceName, spellCode(code))`. Aside: a small tape and a checkmark when `choose && id == selected`. Busy → spinner. Role: radio in choose mode, button otherwise.
- While `busyId != nil`, all rows except the busy one are disabled and the list is dimmed (opacity 0.6) and non-interactive.

**Pick** (lines 267-272): ignored when busy; `haptics.choice`; `onPick`.

**Create inline** (lines 211-265):
- `openOnce` prevents stacking two forms.
- "New container in X…" (ignored while `busyId != nil`) → open `/container/new {spaceId, request}` for a result. On a result: `home = spaces.data.first { $0.id == created.spaceId }`, then `onPick(.container(toPlaceOption({created fields, spaceName: home?.name ?? spaceName, itemCount: 0}, home)))`. The new container is picked without a re-read. This calls the caller's `onPick` **directly**, not through `pick()`, so there is no `haptics.choice` (lines 225-248). In Move/File, `useMove.pick` then moves the item into the new container straight away. In Add, it becomes `picked` and the sheet returns to the form.
- No containers at all → the footer empty state (`strings.picker.none.{title,body,action}`). The action: in `open` mode push `/space/new` (no waiting); otherwise open `/space/new {request}` for a result, then `newContainer(created.spaceId, created.name)` and pick it.
- `nothingAtAll = !loading && options.isEmpty && (!allowNewContainer || spaces.isEmpty)` (lines 287-288).

**Loading and failure** (lines 279-286): skeleton while either list has no data and is loading. Failure → ErrorState with retry (reloads both) when containers failed with no data, or spaces have no data and a cause.

**Filter field** (lines 290-303): a search field with placeholder `placeholder`, a11y `strings.picker.filterA11y`, autofocus per prop, capitalisation `.characters` in open mode, else `.never`.

**Native mapping:** `List { Section(header: …) { … } }` with `.listStyle(.insetGrouped)` (or `.plain` for sticky headers), `.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: placeholder)`, and `.searchFocused($focused)` (iOS 18+) for autofocus. Use `.textInputAutocapitalization(.characters / .never)`. Rows are `Button`s with `.disabled`; use `ProgressView()` for busy and an SF Symbol `checkmark` for selected. "New container in…" is a row `Button` that sets sheet state. Present the container and space forms as nested `.sheet`s with callbacks (§0.9). The keyboard dismisses on drag (`.scrollDismissesKeyboard(.immediately)`).

### 4.2 WhereList (Add sheet) (`src/ui/add/WhereList.tsx`)

A radio group of `entries` (radio-group label `strings.add.where`). Drop zone row: tray tile, `strings.add.dropZone` / `strings.add.sortLater`. Container rows: a leading 40 pt type tile (`TypeTile(type: visualType)`), then a `LocationLine(size: row)` (pip, space › name or none, tape) (`src/ui/add/WhereList.tsx:63-108`). Checkmark on `selectedId`. Tapping the selected row is a no-op. A11y: drop zone `"\(strings.add.dropZone), \(strings.add.sortLater)"`; containers `strings.picker.optionA11y(label, space, spelled)`. Then a separate row "Somewhere else…" (`strings.add.elsewhere`, hint `strings.add.elsewhereHint`, search glyph, chevron) → `onMore`. **Native:** a `Section` in a `Form` with `Button` rows and checkmarks. "Somewhere else…" becomes a `NavigationLink`.

### 4.3 WhereCard (`src/ui/item/WhereCard.tsx`)

A card grouped for accessibility as `strings.a11y.whereItIs`. It shows:
- The label `strings.where.keptIn`.
- `LocationLine(size: card, linked: true)`.
- A footer: in the drop zone → the text `strings.where.notFiledNote`; else a medium spoken tape with the container code.
- The action button: in the drop zone → primary `strings.item.fileIt` (a11y `fileItA11y(name)` / `fileItA11yUnnamed`); else secondary `strings.item.move` (a11y `moveA11y(name)` / `moveA11yUnnamed`).

The card itself is not tappable (lines 34-84). **Native:** a `Section` / `GroupBox` with the location as links (§4.4) and a trailing `Button`.

### 4.4 LocationLine (`src/ui/components/LocationLine.tsx`)

"Where is it?" as one wrapping line, never truncated.
- Drop zone: a tray icon and `strings.where.dropZone`, plus `strings.where.notFiledYet` (" · not filed yet" with no-break spaces) except at card size (lines 113-132).
- Else: a space pip, the space name, a "›" separator (hidden from VoiceOver), the container label, and the tape (row and inline sizes). The container label is `containerName ?? (tape shown ? nil : shortCode)`. At card size there is no tape, so an unnamed container shows its code as text (line 134).
- `showContainer = false` shows only the space (search rows).
- `linked` (card only): the space name and container name become underlined links → `openSpace` / `openContainer`, with a11y hints `strings.a11y.opensSpace` / `opensContainer` (lines 39-87,139-176).
- Sizes: row (pip 12, tape), card (pip 14, no tape, larger "whereCard" type), inline (pip 10, tape, meta type) (lines 20-27).

**Native:** a custom flow `Layout` (or `ViewThatFits`) of `Circle` + `Text` + `Image(systemName: "chevron.right")` + `Text` + tape. Links use `Button(action:) { Text(...).underline() }`. A `Text` with `AttributedString` links plus an `openURL` handler with an internal URL scheme also works. The row a11y label is given by the parent (`whereSpoken`).

### 4.5 PlaceRows: SpaceRow, ContainerRow, PlaceRow (`src/ui/components/PlaceRows.tsx`)

- `SpaceRow`: space tile (56, or 48 in search), name (search terms highlighted), meta `strings.entities.spaceCounts(containerCount, itemCount)`, chevron. A11y `strings.rows.spaceA11y(name, counts)` (lines 35-51). Used by the Spaces tab and search (other areas).
- `ContainerRow` (lines 82-141): type tile (48); name, or `unnamedContainer(type)` in secondary text; a small tape on the same wrapping line; chevron. Context `space`: meta `strings.entities.contents(itemCount)`, plus `" · " + strings.rows.qrLabel` when `qrToken` is set. Context `search`: aside = contents; second line = `LocationLine(inline, showContainer: false)` when the space is known. A11y `strings.rows.containerA11y(label, type, spelled, items, hasLabel)`.
- `PlaceRow` (search hit join; search area): renders a SpaceRow or ContainerRow when the join succeeds, else the hit's title and subtitle as given (lines 163-212).

### 4.6 ItemDetailsFields (`src/ui/components/ItemForm.tsx:135-204`)

Category, Tags, Notes. The return key moves Category → Tags → Notes. Notes are multiline (return adds a newline).
- Category: label `strings.forms.categoryLabel`, placeholder `strings.forms.categoryPlaceholder`. While the field is **focused**, up to 6 suggestion chips appear, from `useCategorySuggestions(values.category)` (§2.7). Tapping a chip sets the category and moves focus to Tags. Chips never auto-fill.
- Tags: label `strings.forms.tagsLabel`, placeholder `strings.forms.tagsPlaceholder`, hint `strings.forms.tagsHint`. The raw comma-separated string is stored in the form.
- Notes: label `strings.forms.notesLabel`, multiline (120 pt minimum box).

**Native:** `TextField`s in a `Section` with `@FocusState` and `.onSubmit { focus = .next }`. Notes uses `TextField(axis: .vertical).lineLimit(4...)` or `TextEditor`. Chips are a flow layout of `Button` + `.buttonStyle(.bordered)` + `.buttonBorderShape(.capsule)`, shown when `focus == .category`.

### 4.7 QuantityStepper (`src/ui/components/QuantityStepper.tsx`)

Minus, number field, plus. A controlled component with no I/O.
- Sizes: `compact` (48 pt cells) and `large` (56 pt cells). The stacked layout fills the width (lines 34-37,295-298).
- **Tap ±** → `bump(±1)`: commit any open draft first; `next = stepQuantity(base, delta)`. At a bound → stop repeating, no change, no haptic. Else `onChange(next)`. Haptic: `next == 0` → `reachedZero`; else `step` (on a hold, only every 5th repeat) (lines 206-238).
- **Hold**: long press after **400 ms** → one immediate step, then a step every **80 ms** until release or a bound. Release stops. On Android it announces the final count; iOS VoiceOver uses the adjustable element (lines 240-254).
- **Typing**: tapping the number focuses it with the text selected. The number pad is limited to **4 chars**. `draft = String(value)` on focus. Blur, submit or the iOS "Done" accessory (`strings.quantity.done`) → `commitTyped`: parse; invalid → revert; clamp; `onChange` if changed. With `commitWhileTyping` (Add form only), every whole number typed is clamped and reported immediately; partial or empty input waits (lines 256-271,336-372,392-403).
- Disabled: minus at `value <= 0`; plus at `value >= 9999`; everything when `disabled` (opacity 0.45).
- Visual states: at 0 and not editing the number uses the error colour (signal); while editing it gets a highlight background (`numberFocus`). The `large` size shows an `error` message under the stepper (warning icon, signal colour), announced on iOS (lines 196-199,384-391).
- Labels: buttons `strings.quantity.increase(name)` / `decrease(name)`, or the `Plain` variants without a name. Field `strings.quantity.field(name)` / `fieldPlain`. Value text `strings.rows.noneLeft` at 0, else the number.
- **VoiceOver**: one adjustable element (label = field label, value = value text, min 0, max 9999). Swipe up or down steps. A custom action `strings.quantity.typeNumber` focuses the field (lines 299-315).

**Native:** a custom `HStack { Button(−) ; TextField(value:format:) ; Button(+) }`, not a stock `Stepper`, because a stock `Stepper` has no typed entry. Hold-repeat can use `.buttonRepeatBehavior(.enabled)`, but its timing is system-defined, not 400/80 ms (Q2). Exact parity needs a `LongPressGesture(minimumDuration: 0.4)` plus a `Task` loop sleeping 80 ms. Use `.keyboardType(.numberPad)` and a keyboard toolbar "Done" (`ToolbarItemGroup(placement: .keyboard)`), which replaces `InputAccessoryView`. Use `.accessibilityElement(children: .ignore)`, `.accessibilityValue`, `.accessibilityAdjustableAction { dir in … }` and `.accessibilityAction(named: strings.quantity.typeNumber)`. `numberFieldWidth` (lines 60-69) is an RN/web width workaround; drop it (the `textHelpers.test.tsx` "numberFieldWidth" cases need not be ported).

### 4.8 SavedQuantityStepper + useSavedQuantity (write-through quantity)

`SavedQuantityStepper(item {id, name, quantity, updatedAt}, size = large, onError?)` (`src/ui/components/SavedQuantityStepper.tsx:31-71`):
- `name = trim(item.name) != '' ? name : nil` for the labels.
- Large: the error sentence shows under the stepper. When `quantity == 0` and there is no error, the note `strings.quantity.noneRightNow` (signal) shows.
- Compact: no inline message. A failure calls `onError(message, kind)`, where `message = strings.quantity.notSavedNamed(name ?? strings.entities.unnamedItem, kind == offline)`, or shows an error toast with that message when no `onError` is given.

`useSavedQuantity(item, onError?)` (`src/hooks/useSavedQuantity.ts:30-158`). **No debounce**; it coalesces with an in-flight loop instead:
- State: `quantity` shown (optimistic), `errorKind: offline | gone | other | nil`. Refs: `confirmed {quantity, updatedAt}`, `pending: Int?`, `inFlight`, `retries`.
- A new `item.id` → reset everything to the item's values (lines 55-67).
- An external update of `item.quantity`/`updatedAt` while nothing is pending or in flight → adopt it (lines 69-73).
- `setQuantity(next)`: `clamped = clampQuantity(next)`; show it; clear the error; `pending = clamped`; `flush()` (lines 146-155).
- `flush()` (lines 80-144): if already in flight, return. The running loop picks up the newest `pending`. While `pending != nil && pending != confirmed.quantity`:
  - `target = pending`; `updated = items.update(id, {quantity: target, expectedUpdatedAt: confirmed.updatedAt})`.
  - `nil` → `pending = nil`, show `confirmed.quantity`, `fail(.gone)`, invalidate, break. No haptic.
  - Success → `confirmed = {updated.quantity, updated.updatedAt}`; `retries = 0`; `logEvent('item_updated')`; if `pending == target` → `pending = nil`; invalidate. The loop continues if newer taps arrived.
  - `ConflictError` with `retries < 3` → `retries += 1`; `fresh = getById`. nil → gone (as above). Throw → `pending = nil`, show confirmed, `fail(.other)`, break, no haptic. Else `confirmed = fresh`, continue. If `fresh.quantity == pending` the loop ends with no write.
  - Parity quirk: `retries` is reset to 0 only on a successful write and on the generic failure path. The two `gone` breaks and the re-read-failure break leave it as is, so the next tap's loop starts with fewer than 3 conflict retries until a write succeeds (lines 158-193).
  - Any other throw, or a conflict after 3 retries → `pending = nil`, `retries = 0`, show confirmed, `kind = describeError(cause,'quantity','item').kind`, `fail(offline | gone | other)`; if gone → invalidate; `haptics.error`; break.
  - After the loop: if `pending == confirmed.quantity` → `pending = nil`.
- Error copy: offline → `strings.quantity.notSavedOffline`, gone → `strings.quantity.gone`, other → `strings.quantity.notSaved` (lines 16-20).

**Native:** a `@MainActor @Observable final class SavedQuantityModel` per item row, with the same fields and a single `Task` loop. Swift 6: the repository calls are `async` and the model is MainActor-isolated, so the loop state needs no locks. **Actual coalescing (not what the hook's doc comment says):** the first tap starts a write at once, with no debounce. Taps that land while it is in flight only overwrite `pending`, and when the write returns the loop issues **one** more write with the newest value. So five fast taps from q give exactly two `update` calls, `q+1` and then `q+5`, both carrying the lock returned by the previous call. They never give five, and never one (`useSavedQuantity.ts:147-173`). Keep this exact behaviour. Adding a debounce would change what other devices see.

### 4.9 QuantityChip (`src/ui/components/QuantityChip.tsx`)

Used by list rows (rows area): a pill showing `strings.rows.times(q)` ("×N"), or `strings.rows.noneLeft` in signal at 0. Tapping toggles a large stepper under the row. A11y label `strings.quantity.chipA11y(name, q == 0 ? strings.quantity.noneLeftValue : "\(q)")`, hint `strings.quantity.chipHint`, expanded state. **Native:** `Button` with `.buttonBorderShape(.capsule)` and `.accessibilityAddTraits`. The expanded state lives in the row's disclosure.

### 4.10 TextField and CodeInput

- `TextField` (`src/ui/components/TextField.tsx:55-176`) has a label above the field. `optional` appends `strings.forms.optional`; `required` is announced (`strings.forms.required`), not drawn. `error` replaces the hint with a warning icon and red text, and is announced on iOS (queued). An optional counter sits at the end of the label row, and an optional trailing accessory inside the field. With `nextRef`, return moves to the next field (return key "next"). Multiline without `grow` gives a 120 pt box; with `grow` it starts one line tall. The spoken label is `[accessibilityLabel ?? label, required ? strings.forms.required : nil, error ? strings.forms.errorA11y(error) : nil]` joined with `", "`. The `hint` is also the field's accessibility hint. **Native:** `LabeledContent`/`VStack` with `Text(label)` + `TextField` in a `Form` row. The error goes in a footer `Text` (`.foregroundStyle(.red)`). Announce with `AccessibilityNotification.Announcement`. Use `@FocusState` chaining.
- `CodeInput` (`src/ui/components/CodeInput.tsx:32-72`), for household and recovery codes (default length 26):
  - The displayed value is `formatCode(value)`. Every change is normalised with `normaliseCode`.
  - The counter `strings.forms.codeCounter(count, total)` ("N of 26 characters") shows only when non-empty. It is announced on **every** blur, including "0 of 26 characters" when empty (`CodeInput.tsx:49-54`).
  - `length` only feeds the counter. Input is never truncated to it, and validity is the screen's job on submit.
  - Code text style, grows multiline with no scroll, return blurs and submits. Lock icon trailing.
  - `.characters` capitalisation, no autocorrect, no spellcheck, no autofill.

  It is used by the household and backup areas. **Native:** `TextField` with a custom `Binding` (get: format, set: normalise), `.textInputAutocapitalization(.characters)`, `.autocorrectionDisabled()`, `.textContentType(.none)`, a monospaced font.

### 4.11 Tape and Mark

- `Tape(code, size: s | m | l | badge, spoken)` (`src/ui/components/Tape.tsx:39-62`): yellow label tape (`tape` #FFD23F light / #F4CA3C dark, ink #1D1A0E). The code is shown exactly as stored, on one line, never truncated or wrapped; it moves to the next line whole. When `spoken`, it is its own a11y element: `strings.a11y.labelCode(spellCode(code))`. Otherwise it is hidden from accessibility. Embossing is cosmetic. **Native:** `Text(code).font(.system(.body, design: .monospaced))` in a `RoundedRectangle` filled with the tape yellow, with `.fixedSize()`. Whether the yellow tape survives the "fully native" direction is Q8.
- `Mark` (`src/ui/components/Mark.tsx:14-46`) is the decorative household mark: an ink box (52×46 radius 10 or 72×64 radius 14) with a tape strip at top 36 %, insets 20 %, height 30 %. It is used by onboarding, the boot screen and the connection banner, none of which are in this area. **Native:** use the app icon or an SF Symbol; hidden from accessibility.

### 4.12 Pickers (`src/ui/components/pickers/*`)

| Component | Behaviour | Stock SwiftUI |
|---|---|---|
| `Chip` (`Chip.tsx:22-73`) | No `onPress` → display tag (item tags). With `onPress` → a selectable pill with a 48 pt hit target and a `selected` state | `Text` in a `Capsule` / `Button` with `.bordered` + `.capsule` |
| `ChoiceList<T>` (`ChoiceList.tsx:31-76`) | A radio group of rows in a sheet: leading view, title, optional subtitle, check on selected. Tapping the selected row does nothing; otherwise `haptics.choice` + `onChange` | `Picker(selection:) { … }.pickerStyle(.inline)` in a `Form` `Section`, with labels holding the space tile |
| `EmojiPicker` (`EmojiPicker.tsx:27-72`) | Grid of 48 pt space tiles tinted in the **current colour**. Offered = `SPACE_ICONS` + preset icons not among them (👕, 🚪), 12 total. A stored icon not offered and non-blank goes **first** and is selected. Selection is exact string equality (`icon === value`), so a stored `🛋` without U+FE0F shows as an extra "current icon" tile, not as Sofa. A blank value (Edit space before seeding) selects nothing. A11y name `entities.iconNames[icon] ?? entities.currentIcon`. Selected → outline ring. Re-tap is a no-op; else `haptics.choice` | `LazyVGrid(columns: [.adaptive(minimum: 48)])` of `Button`s, `.accessibilityAddTraits(.isSelected)`, an a11y radio-group label |
| `SwatchPicker` (`SwatchPicker.tsx:31-82`) | 44 pt circles from `SPACE_COLORS`. `listed = palette.contains { safeColor($0) == safeColor(value) }`. If not listed, `value` goes first and is selected, named `entities.currentColour`. Otherwise names come from `entities.colourNames[safeColor(swatch)]`. Selected → ring + checkmark tinted `onColor(fill)`. `onChange(swatch)` stores the palette string as written (`#5B8DEF`, uppercase). Because "listed" compares through `safeColor`, a stored `#5b8def` shows the Blue swatch selected and is **kept lowercase** until another swatch is tapped (re-tap is a no-op). The "current colour" tile, when present, is index 0 and selected, so tapping it never writes | `LazyVGrid` of `Button { Circle().fill(Color(hex:)) }`. Not `ColorPicker`, because the palette is fixed |
| `SegmentedControl` (`SegmentedControl.tsx:28-96`) | 2–4 options, optional icon, `camera` tone. Used by capture (other area) | `Picker(...).pickerStyle(.segmented)` |
| `TypeGrid` (`TypeGrid.tsx:26-85`) | The 8 types in `CONTAINER_VISUAL_TYPES` order as 72 pt tiles, 4 per row (3 if window width < 360). Only the selected tile shows its name underneath (hidden text keeps the space). Every tile announces its name (`entities.typeNames[type]`). Re-tap no-op; `haptics.choice`. A stored `visual_type` outside the 8 (from another writer) selects **no** tile, and Edit container writes it back unchanged unless a tile is tapped. The native model must keep `visualType` as a raw `String` (or an enum with an `unknown(String)` case), never coerce it | `LazyVGrid` of 4 columns with `Button { Image(systemName:) }`, or `Picker` with `.pickerStyle(.palette)`. Icon mapping: Q11 |

Spread-gap logic (`src/hooks/useSpreadGap.ts`, tests in `src/hooks/__tests__/useSpreadGap.test.ts`) only distributes tiles to the full width in RN. **Native:** `LazyVGrid` with `.flexible()` columns does this; drop it.

### 4.13 Space colour and icon storage

`spaces.icon TEXT` holds the emoji string exactly as chosen (no validation). `spaces.color TEXT` holds the palette hex string (other values from older builds or the desk are rendered through `safeColor` and preserved unless changed). Rendering: a tile filled with a 24 % mix of the colour on the surface, with the emoji at 17/24/28/34 pt for 32/48/56/64 pt tiles. A blank icon → a house glyph (`src/ui/components/SpaceTile.tsx`). The pip is a circle filled with `safeColor(color)` and a 1 pt ring.

### 4.14 FormLayout, SaveNotice, DropZoneLocked (`src/ui/spaces/FormLayout.tsx`)

- `FormLayout(notice, content, bottomBar)`: a modal frame, the notice above the scroll view, the content scrolling, and the bottom bar kept above the keyboard (lines 27-50). **Native:** a `Form`/`ScrollView`, the notice as the first `Section` or pinned via `safeAreaInset(edge: .top)`, and the primary action in `.safeAreaInset(edge: .bottom)` (iOS 26: `.safeAreaBar(edge: .bottom)`, to verify) or `.toolbar(placement: .bottomBar)`. Keyboard avoidance is automatic.
- `SaveNotice(cause, subject, action?)`: a warning banner. Title = the described title, except for `local` errors, which have no title. Message = the described body. Optional action; assertive (lines 64-78).
- `DropZoneLocked`: see §0.1.

### 4.15 Action, confirm and navigation helpers

See §0.8 to §0.10. `goToTab(href)` pops to the existing tab shell instead of pushing a new one (`src/ui/navigation.ts:18-21`). That is an RN workaround. **Native:** set the selected tab and reset that tab's `NavigationPath`, dismissing any presented sheets.

### 4.16 useDirtyGuard (`src/hooks/useDirtyGuard.ts:27-67`)

- `guarded = dirty && !saving && !revoked`. When guarded, any attempt to close (Cancel, back) is intercepted with `confirm(title ?? strings.forms.discardTitle, strings.forms.discardBody, confirm: strings.forms.discard, cancel: strings.forms.keepEditing)`. Discard → `onDiscard?()`, then close.
- On iOS, the sheet's interactive (swipe-down) dismissal is disabled while `dirty || saving` (line 56).
- While saving, hardware back is swallowed and the guard does not ask (so a successful save can close the sheet).

Used by Edit item, New and Edit space, New and Edit container (not by Add item, which keeps a draft instead).

**Native:** `.interactiveDismissDisabled(dirty || saving)`. The Cancel toolbar button checks `dirty && !saving && !revoked` → present the discard alert, else `dismiss()`. Optional improvement: implement `UIAdaptivePresentationControllerDelegate.presentationControllerDidAttemptToDismiss` to show the same alert on a blocked swipe (RN never asks on a swipe; the sheet just resists).

### 4.17 SpaceFields (`src/ui/spaces/SpaceFields.tsx:45-108`)

- Name: required, label `strings.spaceForm.nameLabel`, placeholder `strings.spaceForm.namePlaceholder`, error, return → `onSubmit`.
- `EmojiPicker` (label `strings.spaceForm.iconLabel`, tinted in `values.color`).
- `SwatchPicker` (label `strings.spaceForm.colourLabel`).
- Preview (only when `previewMeta != nil`; hidden from accessibility): label `strings.spaceForm.previewLabel`, then a static Spaces-tab row with a 56 pt tile, `trim(name)` or `previewFallbackName` (default `strings.spaceForm.previewName`), and the meta line.

**Native:** a `Form` with sections; the preview is a non-interactive row with `.accessibilityHidden(true)`.

### 4.18 Keyboard hooks (RN workarounds, not ported)

- `useKeyboardInset` (`src/hooks/useKeyboardInset.ts:19-43`) tracks keyboard visibility so bottom bars drop the home-indicator inset. It animates on the keyboard curve on iOS.
- `useSheetKeyboardOffset` / `sheetKeyboardOffset({headerHeight, windowHeight, formHeight, floating})` returns `floating || formHeight <= 0 ? headerHeight : max(headerHeight, windowHeight − formHeight)`, used for the `KeyboardAvoidingView` offset in page sheets (`src/hooks/useSheetKeyboardOffset.ts:26-39`).
- Tests `src/hooks/__tests__/useSheetKeyboardOffset.test.tsx`: the header height until laid out (56); the iPhone page-sheet gap (formHeight 844−69−56 → 125); a connection banner (800−88−52 → 140); never below the header (780 → 88); floating iPad keeps 56.
- **Native:** SwiftUI's automatic keyboard safe-area handling plus `.safeAreaInset(edge: .bottom)` replaces all of this. Do not port these hooks or their tests.

---

## 5. QR labels: payload, rendering, sharing, printing

### 5.1 What is encoded

- Payload = `"inventory://c/" + token`, where the token is 32 lowercase hex characters (`src/repositories/qr.ts:29-33`; `newQrToken` = 16 bytes from the CSPRNG, hex). The payload is 46 ASCII bytes. **The short code is not in the QR.** The token is opaque, unrelated to any id, and cannot be enumerated.
- `parseQrPayload(raw)`: trim; strip the prefix if present; accept only `^[0-9a-f]{32}$` (case-insensitive); return lowercase (`qr.ts:41-46`). Bare tokens from other tooling are accepted.
- The deep link `inventory://c/<token>` opens the app from the system camera (handled by `app/c/[token].tsx`, scan/deep-link area). **The native app must keep the `inventory` URL scheme registered**, or printed labels stop opening the app.
- QR generation: `react-native-qrcode-svg@6.3.21` → `qrcode`, error correction **M** (library default; `node_modules/react-native-qrcode-svg/src/index.js:101`). 46 bytes in byte mode at level M gives **version 4 (33×33 modules)**. The `qrcode` library optimises segments, so a token with long digit runs can occasionally fit version 3 (29×29). Scanners do not care, so module-count parity is not required.

### 5.2 On-screen card (`src/ui/container/QrCard.tsx`)

- Constants: `MODULES = 220` (pt of code area), `QUIET = 16` (pt of white drawn inside the picture on each side), `PADDING = 24` (card padding) (lines 14-21).
- Sizing: `room = windowWidth − 2·16 − 2·24 − 2`; `modules = max(120, min(220, room − 32))`; `size = modules + 32` (lines 43-48). At window widths ≥ 334 pt, `modules = 220` and `size = 252 pt`; that covers every iOS 26 iPhone at standard zoom (≥ 375 pt). Display Zoom on a 375 pt-class phone gives a 320 pt window, which yields `modules = 206`, `size = 238`. Compute it; don't hard-code it.
- How the 16 pt quiet zone is drawn: the library's `quietZone` (in SVG units) is set to `size²/modules/2 − size/2` (≈ 18.33 at size 252) so that after the `size + 2·quietZone` viewBox is scaled into `size` points, the white border is exactly `QUIET` points (lines 285-287; library viewBox at `node_modules/react-native-qrcode-svg/src/index.js:132-136`). The white margin ratio of the picture is therefore `QUIET/size` (16/252 at standard width).
- The card is always **black (#000000) on white (#FFFFFF)**, in dark mode too. In dark mode it gets a 1 pt border in the rule colour (#2F3632) so it sits with the other sheets. Radius 12 (lines 51-64).
- Contents, top to bottom: the QR (`size × size`, including the 16 pt quiet zone); the container's name in heading type, centred, black, **only if non-blank**; then the large tape with the short code (lines 65-81).
- A11y: one image element labelled `strings.qr.cardA11y(labelOf(container), spellCode(shortCode))`.

### 5.3 Share (`app/container/[id]/qr.tsx:205-239`, `src/ui/container/labelImage.ts`)

1. `begin('share')`; `payload = formatQrPayload(token)`; `text = shareText(container, payload, withPayload: true)`.
2. **iOS only**, and only when the card's SVG ref is set: render the QR SVG to a PNG of **1024×1024 px** (only the QR with its quiet zone, **not** the name or tape). The PNG is a scaled snapshot of the on-screen drawing, so its margin ratio follows the screen-dependent `QUIET/size`. It goes to the cache directory as `label-<shortCode with [^A-Za-z0-9-] removed, or 'label'>.png`, replacing any existing file. The render times out after 4000 ms. Any failure → no picture (lines 12-51).
3. `end()`. The busy state covers only the preparation.
4. Share: with a picture → `{url: fileURL, message: shareText(withPayload: false)}`, which is `"<label> (<code>)"`. Without → `{message: text}`, which is the label, then a newline and the `inventory://c/…` link.
5. If sharing with the picture throws → retry with text only. If text fails too → error toast `strings.qr.shareFailed`.
6. The iOS share sheet provides **Save Image** and **Print** for the PNG. There is no separate Print button.

Picture geometry at the default size: the white margin is `16/252 × 1024 ≈ 65 px` on each side, the code area `220/252 × 1024 ≈ 894 px` (at version 4, 33 modules ≈ 27.1 px each). The quiet zone is about 2.4 modules, less than the 4 the QR specification asks for. It is kept for parity (Q6).

### 5.4 Native replacement

- **Generator:** `CIFilter.qrCodeGenerator()` with `message = Data(payload.utf8)` and `correctionLevel = "M"`. Scale with `CGAffineTransform(scaleX:y:)` using nearest-neighbour (`.interpolation(.none)` when shown via `Image(uiImage:)`). Render with a shared `CIContext` to a `CGImage`. CoreImage output may include its own margin. Measure it and crop or pad so the white border equals `QUIET/size` of the side, matching the RN picture (16/252) (Q6). The ECL must match (level M). CoreImage encodes in byte mode, which gives version 4 for this payload length. Verify by decoding a generated image in a unit test.
- **On-screen card:** a SwiftUI view (`Image(qr).interpolation(.none).resizable().frame(width: 220, height: 220)` padded 16 pt in white, then an optional name `Text`, then the tape) on a white `RoundedRectangle(cornerRadius: 12)`. Force `.environment(\.colorScheme, .light)` inside the card.
- **Share picture:** `ImageRenderer(content: QRPictureView())` with `scale` chosen so the output is 1024×1024 px. Write `pngData()` to `FileManager.default.temporaryDirectory/label-<CODE>.png`, or share a `Transferable` image directly. Then `ShareLink(item: Image/URL, message: Text(shareMessage), preview: SharePreview(...))`, or `UIActivityViewController(activityItems: [shareMessage, fileURL])`. The text-only fallback (`message + "\n" + payload`) existed only for Android and for picture failures. Keep it as the failure fallback. Print stays reachable via the share sheet. A dedicated `UIPrintInteractionController` button would be an addition (Q7).
- Time budget: CoreImage rendering is synchronous and fast. The RN 4 s timeout and data-URL stripping are not needed.

### 5.5 Binding rules (`src/repositories/qr.ts`), as the UI relies on them

- `getByContainer(containerId)`: `SELECT * FROM qr_bindings WHERE container_id = ? ORDER BY created_at DESC LIMIT 1` (lines 92-98).
- `getByToken(token)`: `SELECT * FROM qr_bindings WHERE token = ?` (HTTP: always nil).
- `resolveScan(raw)`: `parseQrPayload`; nil → `invalid(raw)`. Then `SELECT c.* FROM containers c JOIN qr_bindings q ON q.container_id = c.id WHERE q.token = ?`. No row → `unknown(token)`, else `bound(container, token)` (lines 56-90). HTTP: `POST /v1/qr/scan {raw}`.
- `bind(token, containerId)`: the drop zone → throws `system_record`. In one transaction: `DELETE FROM qr_bindings WHERE token = ?`; `DELETE FROM qr_bindings WHERE container_id = ?`; `INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at) VALUES (newId, token, containerId, now, now)` (lines 117-140). A container has at most one label and a token opens at most one container. Schema: `token TEXT NOT NULL UNIQUE`, but `container_id` is only indexed (`idx_qr_bindings_container`), not unique (`src/db/migrations.ts:89-96`). "One label per container" is enforced by this delete-then-insert, which is why reads use `ORDER BY created_at DESC LIMIT 1`. Native writes must keep both DELETEs. HTTP: `POST /v1/qr/bind {token, containerId}`.
- `resolveScan`'s join has no `kind` filter. Its `bound` container is the full `Container` (`id, spaceId, name, visualType, shortCode, createdAt, updatedAt`).
- `createAndBind(containerId) = bind(newQrToken(), containerId)`. HTTP: `POST /v1/containers/:id/qr` → 201 with the binding JSON.
- `unbind(containerId)`: `DELETE FROM qr_bindings WHERE container_id = ?` → `changes > 0`. HTTP: `DELETE /v1/containers/:id/qr` → 204, or 404 mapped to false.

Repository tests (`src/db/__tests__/persistence.test.ts` › "qr bindings"; owned by the data-layer spec, listed here because the UI depends on them): resolves a bound token from the `inventory://c/` form; a well-formed unknown token → unknown; `'https://example.com'` and `''` → invalid; rebinding a token moves it, leaving exactly 1 binding; a second `createAndBind` retires the first token (resolve → unknown); unbinding keeps the container and items.

---

## 6. Data contract used by these screens

### 6.1 Local SQL (GRDB must issue equivalent statements; the schema is preserved)

| Call | SQL / behaviour | Source |
|---|---|---|
| `items.getById(id)` | `ITEM_CONTEXT_SELECT WHERE i.id = ?`. First photo by `created_at ASC` (`photo_id`, `photo_uri`, `photo_thumb_uri`); tags via `GROUP_CONCAT(t.name, char(31))`; joins container and space | `src/repositories/items.ts:72-91,212-217` |
| `items.listByContainer(id)` | the same projection `WHERE i.container_id = ? ORDER BY i.created_at DESC` | `items.ts:176-182` |
| `items.listUnsorted()` | the same, with the drop zone id | `items.ts:185-191` |
| `items.create(draft)` | in one transaction: INSERT the item (`search_text = lower(trim("name category"))`), an optional photo row, tags upserted by `normalized_name = lower(trim)` and linked. Quantity must be an integer ≥ 0 (default 1). A name given explicitly as blank → `Error('Item name is required.')` | `items.ts:225-287` |
| `items.update(id, input)` | reads the row (nil if missing); merges fields; an explicit blank name throws; in a transaction `UPDATE items SET container_id, name, category, quantity, notes, updated_at = now, search_text WHERE id = ? [AND updated_at = ?expected]`. 0 changes and a row exists with `expected` set → `ConflictError(current.updated_at)`; 0 changes otherwise → nil. Tags are replaced when given. **Returns `Item` (has `updatedAt`, `quantity`)** | `items.ts:289-376` |
| `items.delete(id)` | in a transaction: collect `uri` and `thumb_uri` (non-null) of its photos, then `DELETE FROM items WHERE id = ?` → `{deleted: changes > 0, orphanedPhotoUris}`. Photo tombstones come from a trigger | `items.ts:403-424` |
| `containers.getById` / `getWithCounts` | `SELECT * FROM containers WHERE id = ?`; with counts: `item_count` subquery and the latest `qr_token` | `containers.ts:85-104` |
| `containers.listBySpace(spaceId)` | `... WHERE c.space_id = ? AND c.kind = 'normal' ORDER BY c.created_at DESC`, with `item_count`, `qr_token` | `containers.ts:66-83` |
| `containers.listAllWithSpace()` | `JOIN spaces ... WHERE c.kind = 'normal' ORDER BY s.name COLLATE NOCASE ASC, c.created_at DESC`, with `space_name`, `item_count` | `containers.ts:225-240` |
| `containers.create({spaceId, name?, visualType})` | `name = trim or NULL`; up to 10 attempts with a fresh short code. A UNIQUE or constraint error → retry; other errors are rethrown; exhaustion → `Error('Could not allocate a unique container code. Please try again.')` | `containers.ts:112-151` |
| `containers.update(id, {name?, visualType?, spaceId?})` | drop zone guard; nil if missing; `name = trim or NULL` when given; `UPDATE containers SET name, visual_type, space_id, updated_at` | `containers.ts:153-175` |
| `containers.deletionImpact(id)` | item, photo and QR counts → `{itemCount, photoCount, hasQrBinding}` | `containers.ts:177-196` |
| `containers.delete(id)` | drop zone guard; collect photo uris; `DELETE FROM containers WHERE id = ?` (cascades) | `containers.ts:198-222` |
| `spaces.listWithCounts()` | `WHERE s.kind = 'normal' ORDER BY s.name COLLATE NOCASE ASC`, with `container_count`, `item_count` | `spaces.ts:63-82` |
| `spaces.getById`, `create`, `update`, `deletionImpact`, `delete` | create trims the name; update trims the name when given; impact = container, item, photo and QR counts; delete collects photo uris and cascades | `spaces.ts:84-195` |

Short-code generation uses `Math.random` (not a CSPRNG). Uniqueness is enforced by `containers.short_code UNIQUE`. The code is never changed after creation. `containers.create` retries only when the error message matches `/UNIQUE|constraint/i` (`containers.ts:143-146`). Note that a foreign-key failure (unknown `spaceId`) also matches "constraint", so it burns all 10 attempts and then throws the "Could not allocate…" error (the persistence test "refuses to attach a container to a space that does not exist" only asserts that it throws). GRDB: retrying on `SQLITE_CONSTRAINT_UNIQUE` only is fine, since no screen shows the message.

**Persisted formats these screens write (in-place upgrade: the native app must write byte-identical shapes):**
- Ids (`items.id`, `containers.id`, `spaces.id`, `qr_bindings.id`, `tags.id`, `item_photos.id`) are **lowercase** RFC 4122 v4 UUID strings from `newId()` (`src/core/id.ts:41-54`, lowercase hex from `src/core/bytes.ts:11-17`). Swift's `UUID().uuidString` is **uppercase**, so use `.lowercased()`. QR tokens are 32 lowercase hex characters from 16 CSPRNG bytes (`SecRandomCopyBytes`), never a UUID.
- Every `created_at` / `updated_at` is INTEGER **milliseconds** since the Unix epoch (`Date.now()`). `updated_at` is the item lock: the native write must store the same ms value it returns, so `Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))`.
- `items.name` is `''` (empty string, NOT NULL) for an unnamed item. `category` and `notes` are NULL when blank after trim, never `''`. `containers.name` is NULL when blank after trim.
- `items.search_text = "\(name) \(category ?? "")".trimmed.lowercased()`, computed in JS with Unicode `toLowerCase()`, not SQLite `lower()` (ASCII-only) (`items.ts:130-132`). (Migration 2 backfilled old rows with SQL `TRIM(LOWER(...))`, `src/db/migrations.ts:110`, so pre-existing non-ASCII rows may differ; never rewrite them on read.) Swift `lowercased()` matches JS for this purpose.
- Tags: each name is trimmed and keyed by `normalized_name = trim(name).toLowerCase()` (`tags.normalized_name UNIQUE`). If a tag with that key exists, its row (and its **original casing**) is reused, so typing "Dewalt" when "dewalt" exists shows "dewalt" on the item afterwards. Duplicates within one save are dropped, first wins (`items.ts:126-174`). `item_tags` is fully replaced on every save that passes `tags`. The read order of tags is `GROUP_CONCAT` order (unspecified; in practice insertion order), and `detailsDirty`/`rebaseDetails` compare the joined order.
- `spaces.icon` and `spaces.color` are stored verbatim as chosen (the palette literal, uppercase). Neither is validated by the repository. `spaces.update` sends `input.name?.trim() ?? existing.name`, so an explicitly blank name would store `''`; only the UI prevents it.

### 6.2 Household HTTP (paired mode)

The client and transport (origin, bearer token, 20 s default timeout, 409 → `ConflictError`, 404 handling, 204) are owned by the household spec. Endpoints these screens reach (`httpRepositories.ts`):
- `GET /v1/items/:id` (photo hydrated)
- `GET /v1/items?containerId=`, `?unsorted=1`
- `POST /v1/items` (photo uploaded first via `PUT /v1/photos/:id`, 60 s timeout)
- `PATCH /v1/items/:id {containerId?, name?, category?, quantity?, notes?, tags?, updatedAt?}`, where **`updatedAt` is the expected lock**
- `DELETE /v1/items/:id`
- `GET /v1/containers`, `?spaceId=`
- `GET /v1/containers/:id` (includes `itemCount`, `qrToken`)
- `POST /v1/containers {spaceId, visualType, name}`
- `PATCH /v1/containers/:id {name, visualType, spaceId}`
- `DELETE /v1/containers/:id`
- `GET /v1/spaces`, `GET/PATCH/DELETE /v1/spaces/:id`, `POST /v1/spaces {name, icon, color}`
- `POST /v1/qr/scan`, `POST /v1/qr/bind`, `POST /v1/containers/:id/qr`, `DELETE /v1/containers/:id/qr`

DELETE responses carry `{orphanedPhotoUris}`.

### 6.3 Device storage this area reads and writes (must survive the RN → native upgrade)

| Key / store | Format | Owner |
|---|---|---|
| AsyncStorage `places.recent.v1` | JSON array of container id strings, max 6, most recent first | `src/services/places/recentPlaces.ts:5` |
| AsyncStorage `categories.recent.v1` | JSON array of category strings, max 20, most recent first | `src/ui/categoryMemory.ts:3` |
| Photo files (item photos and thumbnails) | file URIs stored in `item_photos.uri` / `thumb_uri` | capture area (`deleteStoredPhotos`) |
| Cache `label-<CODE>.png` | throwaway | `src/ui/container/labelImage.ts` |
| Add draft | memory only, not persisted | `src/ui/add/addDraft.ts` |

**Native:** on first launch the shared importer owned by `02-device-storage-migration.md` §5.4 copies these two keys (with the other five) into `UserDefaults` verbatim as raw strings; this area parses them on read with the rules below. Verified against the installed `@react-native-async-storage/async-storage@3.1.1`: the package's **default export** (which both modules import) is `getLegacyStorage()` (`node_modules/@react-native-async-storage/async-storage/src/index.tsx`), that is, the legacy v2 file store, not v3's new SQLite `SharedStorage`. On iOS that store is `Application Support/<bundleId>/RCTAsyncLocalStorage_V1/manifest.json`, a JSON object `{key: value}`. Any value longer than **1024** UTF-16 units (`value.length > RCTInlineValueThreshold`) is stored as `null` in the manifest and written to a sibling file named `MD5(UTF-8 key)` in lowercase hex (`apple/legacy_storage/RNCAsyncStorage.mm:17-21,138-147,507-510,633`; `RCTMD5Hash` in `node_modules/react-native/React/Base/RCTUtils.mm:256-270`). `places.recent.v1` (≤ 6 UUIDs, about 235 chars) is always inline. `categories.recent.v1` (up to 20 free-text categories) **can exceed 1024 characters and live in the MD5 file**, so the migrator must handle both cases. Treat unparsable values as `[]`, as the JS does. The storage/migration area owns the reader; this area only needs the two keys and their formats.

---

## 7. RN/Expo workarounds that are not needed natively

| RN code | Why it exists | Native |
|---|---|---|
| `routeResult` request ids (`src/ui/routeResult.ts`) | expo-router screens cannot pass callbacks | closures and bindings into sheets; `onDismiss` → abandon |
| `ToDropZone` effect instead of `<Redirect>` (`container/[id]/index.tsx:51-56`, `space/[id]/index.tsx:34-39`) | avoids stacking a second tab shell | switch tab and reset the path |
| `goToTab` with dismissTo/navigate (`navigation.ts:18-21`) | the same | tab selection state |
| `useSheetKeyboardOffset`, `KeyboardAvoidingView`, `useKeyboardInset`, `automaticallyAdjustKeyboardInsets`, `keyboardShouldPersistTaps` | RN keyboard layout | SwiftUI keyboard avoidance, `.scrollDismissesKeyboard` |
| `InputAccessoryView` "Done" bar on the number pad (`QuantityStepper.tsx:392-403`) | the number pad has no return key | `ToolbarItemGroup(placement: .keyboard)` |
| `transitionEnd` + 700 ms fallback before focusing (`item/new.tsx:290-310`, `item/[id]/index.tsx:134-145`) | focusing mid-transition fights the keyboard | `@FocusState` set in `.task`/`.onAppear`, or `.defaultFocus` |
| `usePreventRemove` / `BackHandler` / `gestureEnabled` toggles | navigation interception, Android back | `.interactiveDismissDisabled`, `.navigationBarBackButtonHidden` + custom back where needed |
| `numberFieldWidth` (`QuantityStepper.tsx:60-69`) | web input width | intrinsic `TextField` sizing |
| `useSpreadGap` (`src/hooks/useSpreadGap.ts`) | justify a wrapping RN row | `LazyVGrid` flexible columns |
| `usePullToRefresh` pulled-flag (`src/ui/spaces/usePullToRefresh.tsx`) | RefreshControl shows on every reload | `.refreshable` |
| `useCollapsingTitle` | in-content title vs header | large titles / `onScrollGeometryChange` |
| SVG `toDataURL`, the 4 s timeout, `data:` prefix stripping, expo-file-system writes (`labelImage.ts`) | no native picture API in RN | CoreImage + `ImageRenderer` |
| Text-only share on Android (`shareLabel`, `shareText` withPayload) | RN `Share` cannot attach files on Android | keep only as the iOS failure fallback |
| `showActionSheet` Android alert fallback, `Alert` `onDismiss` | Android | `.confirmationDialog` / `.alert` |
| TalkBack `announceForAccessibility` branches, `android_ripple`, `Platform.OS` branches | Android | drop (keep the VoiceOver equivalents) |
| `AccessibilityInfo.announceForAccessibility` on iOS for live regions | VoiceOver ignores RN live regions | `AccessibilityNotification.Announcement(…).post()` |
| `Platform.isPad` floating sheet offset | iPad page sheet | automatic |
| Memoised `ItemRow` comparator | FlatList performance | `List` with `Identifiable` |

---

## 8. Test inventory to port to Swift Testing

Port (pure logic):
1. `src/core/__tests__/quantity.test.ts`: clamp, parse, step (§2.1).
2. `src/ui/components/__tests__/ItemForm.test.tsx`: validateItemForm ×6 cases, applySuggestion ×6 (§2.2).
3. `src/ui/item/__tests__/itemDetails.test.ts`: detailsSeed, detailsDirty ×3, rebaseDetails ×3, keepsUnnamed ×2, itemStamp ×2, attemptName ×6, attemptDetails ×7 (§2.3). Use a fake `ItemsRepository` actor, plus the "store with a real lock" fake from the test.
4. `src/ui/item/__tests__/moveFlow.test.ts`: attemptMove ×7, attemptUndo ×4, messages ×5, nextInRun ×7, afterFiling ×3 (§2.4).
5. `src/ui/container/__tests__/containerRules.test.ts`: labelOf/titleOf/typeNameOf ×3, sortContents ×3, isFreshArrival, planSticker ×6, settleWrittenLabel ×3, labelFailureMessage ×3, shareText (§2.5).
6. `src/ui/spaces/__tests__/spaceSetup.test.ts`: containerLabel/byContainerLabel ×2, taken names, labelsInSpace ×2, delete bodies ×3, spaceValuesChanged ×2, containerValuesChanged ×2 (§2.6).
7. `src/ui/__tests__/placeMatch.test.ts`: compact ×2, placeTerms, matchesPlace ×4, beyond ASCII ×2, joinPlaceOptions, toPlaceOption (§2.7).
8. `src/services/places/__tests__/recentPlaces.test.ts`: mergeRecent ×4, rememberPlace persistence (§2.7). Inject a `UserDefaults(suiteName:)`.
9. `src/hooks/__tests__/useRecentPlaces.test.tsx`: the held list does not reorder during a screen's life (§2.7). Port as a model test.
10. `src/ui/components/__tests__/textHelpers.test.tsx`: **only** `suggestCategories` ×2. Drop `splitHighlight` (search area) and `numberFieldWidth` (RN-only).
    - `src/ui/components/__tests__/SuggestionBanner.test.tsx` › `staleSuggestionName` ×5 (missed by the first draft): with `applied(forName:'Cordless drill')`, `'Cordless drill'` and `'  Cordless drill  '` → nil; `'Angle grinder'` → `'Angle grinder'`; after `refreshed(forName:'Angle grinder')`, `'Angle grinder'` → nil and `'Bench grinder'` → `'Bench grinder'`; `''` and `'   '` → nil; `idle`, `running`, `refreshing` and `failed(offline)` → nil for any name.
    - `src/core/__tests__/tokenize.test.ts` › "short codes" ×2: generated codes match `/^BOX-[2-9A-HJ-NP-Z]{4}$/` with no `O I 0 1` over 200 runs; `normalizeShortCode('box-7k2m') == 'BOX7K2M'` (§2.7).
11. `src/ui/add/__tests__/addSheet.test.ts`: params ×4, content ×2, initialAddState ×6, whereEntries ×5, resolvePlace ×3, labels ×3 (§2.8).
12. `src/ui/add/__tests__/addDraft.test.ts`: ×4 (§2.8). Inject a photo-deleter spy.
13. `src/ui/__tests__/a11y.test.ts`: spellCode ×2 (whereSpoken and quantitySpoken belong to the rows spec).
14. `src/ui/__tests__/code.test.ts`: normaliseCode ×2, invalidCodeChars, formatCode (§2.9).
15. `src/ui/__tests__/routeResult.test.ts`: only if a continuation-based equivalent is kept (§0.9).
16. New native tests (no RN equivalent): QR generation round-trip (generate → decode with `CIDetector`/Vision → equals the payload; ECL M); share PNG is 1024×1024 px with a white margin ratio of 16/252; `useSavedQuantity` coalescing (five rapid sets while the first write is pending → exactly two `update` calls, the first value and then the final one, with the second carrying the first's returned `updatedAt`; conflict retry ≤ 3, and the 4th conflict fails with `haptics.error`; `nil` → gone without a haptic; a re-read throw → `other`).

Do not port: `src/hooks/__tests__/useSheetKeyboardOffset.test.tsx`, `useSpreadGap.test.ts` (RN layout workarounds). The repository tests in `src/db/__tests__/persistence.test.ts` belong to the data-layer spec; the relevant "qr bindings", "containers" and "drop zone" cases are summarised in §5.5 and §6.1.

---

## 9. Open questions

- **Q1. Quantity parsing.** Same question as `01-data.md` Q4 (owner): JS `Number()` accepts forms like `1.0`, `1e3` and `0x10`, which Swift `Int()` rejects. The number pad cannot produce them, but paste can. Decide once, in 01.
- **Q2. Hold-repeat timing.** `.buttonRepeatBehavior(.enabled)` uses system timing, not exactly 400 ms then 80 ms. Is exact parity required, or is the system behaviour acceptable under the "fully native" direction?
- **Q3. Primary action placement.** RN puts Save/Create in a bottom bar on every form. Native iOS convention is a toolbar confirmation action (top right). Keep the bottom bar (parity) or move to `.confirmationAction`?
- **Q4. Add sheet place step.** Push inside the sheet (recommended; system back) or keep the in-place cross-fade swap?
- **Q5. Dirty swipe.** Today a dirty sheet resists the swipe silently. Show the discard alert on a swipe attempt via `presentationControllerDidAttemptToDismiss`?
- **Q6. QR quiet zone.** The picture keeps about 2.4 modules of white, under the 4-module QR recommendation. Keep pixel parity (16/252) or move to a spec-compliant 4-module margin? (This changes printed output; existing stickers are unaffected because only the token matters.)
- **Q7. Share picture content.** Today only the QR is shared/printed. The name and code tape show on screen but are **not** in the PNG, although `QrCard` describes itself as "the label as it will be printed". Should the native picture render the whole card (QR + name + tape) via `ImageRenderer`? Add a direct "Print" button (`UIPrintInteractionController`)?
- **Q8. Tape styling.** Does the yellow label tape (and its exact yellow) survive "system fonts and stock controls, only the brand accent colour"? It carries information (the code), so some distinct badge is needed. Which colour is the brand accent: ink or tape yellow?
- **Q9. Collapsing titles.** Use system large titles (the crumb or tile then sits under the title) or the inline title toggled on scroll, which matches the current layout?
- **Q10. Two container-label helpers.** `containerRules.labelOf` treats a whitespace-only name as unnamed; `spaceSetup.containerLabel` / `moveFlow.containerLabel` / `addSheet.containerTitle` use `name ?? shortCode`. The repositories store blank as NULL, so they only differ for data from other writers. Unify on `labelOf` semantics natively?
- **Q11. Container type icons.** The RN app uses custom line glyphs (`src/ui/icons/glyphs.tsx`). Choose SF Symbols, for example box → `shippingbox`, drawer → `archivebox`, shelf → `books.vertical`, cabinet → `cabinet`, bin → `trash`, bag → `bag`, crate → `square.stack.3d.up`, other → `tag`. The theme or icon spec should own the final mapping.
- **Q12. Sort stability.** Native sorts need explicit tie-breaks (original index) wherever JS relied on stable `Array.sort` with no tie-break (`byContainerLabel`, picker `byLabel`). Confirm that the intended order is "keep repository order on ties".
- **Q13. Recognition hint on retry.** Retry passes the typed name as a hint without overwriting. This is behaviour, not a question, but confirm the native AI client supports `nameHint` (AI area).

---

## 10. Dependencies on other areas

- **Data layer / GRDB** (`src/db/*`, `src/repositories/*`): schema, `kind` columns, cascades, the photo tombstone trigger, `ConflictError` semantics, repository SQL (§6.1), `persistence.test.ts`.
- **Household client** (`src/services/household/*`): the HTTP repository implementation, 404/409/204 handling, timeouts, photo hydration and upload (§6.2), the paired/local switch (`useHousehold().session` for delete copy), and the revoked state (`useConnection().state == 'revoked'` used by dirty guards and Add).
- **Capture and photos** (`app/capture/*`, `src/services/capture/imageStore.ts`): single and fast capture flows returning `PhotoResult`, `deleteStoredPhotos`, photo file locations to migrate, the photo viewer `/item/[id]/photo`.
- **AI recognition** (`src/services/ai/*`): `recognizeItem({imageUri, nameHint}) → success(suggestion {name?, category?, tags, confidence}) | failed(reason)`; `strings.suggestions.failedBody` keys follow the failure reasons.
- **Scan and deep link** (`app/(tabs)/scan.tsx`, `app/c/[token].tsx`, `src/ui/components/QrScanner.tsx`, `src/ui/scan/scanRules.ts`): the scanner view used by Link sticker, PlacePicker `bind` and `open` modes, `inventory://` URL handling.
- **Lists and rows** (`src/ui/components/ItemRow.tsx`, search, home, drop zone): `ItemRow` with the stepper tool, `QuantityChip` rows, `PlaceRow` in search, `whereSpoken`.
- **App shell and navigation**: tabs, Search header button (`focusSearch`), Toast provider (durations, single-fire actions), connection banner, revoked layer.
- **Theme and design**: brand accent, tape colours, signal red, space tile tint, SF Symbol mapping (Q8, Q11).
- **Storage migration**: AsyncStorage → UserDefaults for `places.recent.v1` and `categories.recent.v1`; keep the bundle id `com.wystudio.inventory` and the URL scheme `inventory`.
- **i18n**: `strings.ts` keys and `src/i18n/format.ts` (`plural`, `sentenceList` without serial comma, `ago`, `longDate` en-GB).

---

## 11. Reviewer notes

An adversarial review checked every claim against the source files (`app/item/**`, `app/container/**`, `app/space/**`, `src/ui/{item,container,spaces,add}/**`, the listed components, pickers and hooks, `src/repositories/{qr,items,containers,spaces}.ts`, `src/services/household/{httpRepositories,client}.ts`, `src/services/places/recentPlaces.ts`, `src/ui/categoryMemory.ts`, `src/core/{quantity,shortCode,id,bytes,tokenize}.ts`, `src/db/migrations.ts`, and the AsyncStorage and QR libraries in `node_modules`). Most of the first draft was accurate. These are the changes:

**Corrections**
- §0.1: fixed the `assertNotDropZone` citation in `containers.ts` (57-59, not 54-56). Added that `containers.create` itself does not refuse the drop-zone space.
- §0.2: "a household 404 is never an error" was too broad. Only `callIgnoring404` calls turn 404 into `null`/`{deleted:false}`/`false`. Creates, lists, `qr.scan`, `qr.bind` and `qr.createAndBind` throw `HouseholdHttpError(404)`, which `describeError` maps to `gone`. Added the HTTP derivations of `containers.deletionImpact` and `spaces.deletionImpact`, the 204 → `{}` rule, and `ConflictError(null)` when the 409 body has no `updatedAt`.
- §0.2 and §6.1: stated that containers and spaces have **no optimistic lock** in either implementation (last writer wins).
- §0.5: not every write path checks `isFocused`. Container delete and space delete navigate unconditionally; Link sticker uses `openRef`.
- §1: fixed citations for the container types (`types.ts:56-65`), short-code prefixes (`shortCode.ts:10-19`) and suffix (`21-37`). Added the `CTR` fallback for an unknown type.
- §2.7: the Swift `compact` recipe used `CharacterSet.letters`, which also contains combining marks, so it would diverge from JS `\p{Letter}`. Replaced it with an exact general-category filter.
- §2.7: the `rememberPlace` call sites were wrong. They are Add save, move/file, and the deep-link bind. There is no separate "new-container pick" call, and Link sticker does not remember.
- §2.10: wrote out the exact `safeColor` regex and its expansion rules (the first draft used an ambiguous shorthand).
- §5.2: the sizing claim "every iOS 26 iPhone gets 220" ignored Display Zoom. The real threshold is a window width ≥ 334 pt; at 320 pt, modules = 206.

**Additions**
- §1: the 9999 cap exists only in the UI; the repository allows any integer ≥ 0. Parity edge: minus on a value above 9999 writes 9999. The home server checks presence only; `POST /v1/spaces` requires `name`, `icon` and `color`.
- §2.1/Q1: JS also accepts `'1.0'` and `'0x10'`.
- §2.3: `longDate` uses the device time zone; gave a Swift `DateFormatter` recipe.
- §2.7: `categoryMemory` load and merge rules (in-session saves stay in front of stored ones; first casing wins).
- §2.7/§8: added two missed test files, `src/ui/components/__tests__/SuggestionBanner.test.tsx` (`staleSuggestionName` ×5) and `src/core/__tests__/tokenize.test.ts` › "short codes" ×2.
- §3.1: the `stale` suggestion state is derived at render, never stored. "Save and add another" with a photo reopens capture with no `mode` and no `request`. The Where list holds only the drop zone while places load. The place step allows inline container creation.
- §3.2: the collapsed nav title falls back to `strings.entities.unnamedItem`; the progress count includes this item.
- §3.5: `useMove`'s busy guard is never released after a successful move.
- §3.6: a failed space read still shows the form, without the context line. Named the name field's label key.
- §3.8 and §3.13: Save is not gated on dirty, so an unchanged save still bumps `updated_at`. Container delete pushes the **stored** `spaceId`.
- §3.11: custom space names are not checked for duplicates.
- §4.1: the inline "New container" path calls `onPick` directly, with no choice haptic. "Here now" can also appear in Recent.
- §4.2: Where list rows have a leading type tile.
- §4.8 (correction): the first draft said five quick taps make one PATCH. The code makes **two**: the first tap writes at once, and the in-flight loop then writes the newest value once. Fixed in §4.8 and in test item 16 of §8.
- §4.8: `retries` is not reset on the `gone` or re-read-failure paths.
- §4.10: `CodeInput` announces the counter on every blur, including when empty, and never truncates. Gave `TextField`'s exact spoken-label composition.
- §4.12: an unknown stored `visual_type` selects no TypeGrid tile and must be preserved as a raw string. EmojiPicker matching is exact, so a missing FE0F gives an extra tile. SwatchPicker keeps a lowercase stored hex until another swatch is tapped.
- §5.5: `qr_bindings.container_id` is not UNIQUE in the schema, so both DELETEs in `bind` must stay.
- §6.1: new "Persisted formats" block for the in-place upgrade: lowercase UUIDs (Swift `uuidString` is uppercase), integer-millisecond timestamps, `''` versus NULL rules, `search_text` built with JS lowercasing, tag reuse keeping the existing tag's casing, and verbatim icon and colour.
- §6.3: checked the AsyncStorage store against the installed 3.1.1. The default export is the legacy v2 file store: `manifest.json`, with values over 1024 UTF-16 units moved to an `MD5(key)` file. `categories.recent.v1` can exceed that limit, so the migrator must read both places.

**Completeness / consistency pass (cross-spec critic)**
- §2.1 / Q1: the recommendation "in Swift, use `Int(trimmed)`" conflicted with `01-data.md` §6.4 (JS `Number()` grammar, `jsTrim()`, Q4). `parseQuantityInput` now has one owner (01); Q1 here points at 01 Q4.
- §6.3: the import of `places.recent.v1` / `categories.recent.v1` is done by the shared importer in `02-device-storage-migration.md` §5.4 (raw strings, parse on read), not by an area-specific migrator.
- §0.11 / Q9 large titles: kept. `09-app-shell-lifecycle-config.md` §2.5, which said "inline titles", was corrected to match this spec and 06.
- Coverage check: all files in scope, including the pickers (`Chip`, `ChoiceList`, `EmojiPicker`, `SegmentedControl`, `SwatchPicker`, `TypeGrid`), `SavedQuantityStepper`, `WhereCard`, `SpaceFields`, `QrCard`, `labelImage.ts`, `useDirtyGuard`, `useSheetKeyboardOffset` (not ported) and `app/item/[id]/move.tsx`, are specified; every exported symbol is referenced. The `Create*/Update*Input` and `*DeletionImpact` TypeScript types of `src/repositories/{spaces,containers}.ts` are not named, but their fields are given in `01-data.md` §7.1-7.2.

**Checked and left as written:** every `strings.*` key referenced exists in `src/i18n/strings.ts`. The pure-logic descriptions and test summaries for `itemDetails`, `moveFlow`, `containerRules`, `spaceSetup`, `addSheet`, `addDraft`, `placeMatch`, `recentPlaces`, `quantity`, `code` and `a11y` match the source. So do the QR payload, the ECL (M, library default at `index.js:101`), the 1024 px / 4000 ms share constants, the drop-zone seed rows, and the motion and haptic constants.
