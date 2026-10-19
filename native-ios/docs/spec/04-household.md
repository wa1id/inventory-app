# 04 — Household sharing via the home server

Porting spec for the native iOS app (Swift 6, SwiftUI, iOS 26+, GRDB). Written so the
feature can be rebuilt behavior-identically without reading the TypeScript. Every
behavior cites `path:line` (repo-relative to `/home/walid/inventory-app`).

Scope read in full:
`src/services/household/{client,collectDump,devices,dump,httpRepositories,importHousehold,importOffer,photoCache,session,shadow}.ts`,
`src/services/household/__tests__/*`, `src/providers/HouseholdProvider.tsx`,
`src/providers/ConnectionProvider.tsx`, `src/ui/household/{JoinForm.tsx,join.ts,status.ts}` and tests,
`app/household.tsx`, `src/ui/components/ConnectionBanner.tsx`, `src/ui/home/unpairedNotice.ts`,
`home-server/src/*.ts`, `home-server/test/*.ts`, plus the parts of `src/ui/errors.ts`,
`src/ui/code.ts`, `src/ui/components/CodeInput.tsx`, `src/providers/DatabaseProvider.tsx`,
`app/_layout.tsx`, `src/repositories/*`, `src/db/*` that this area depends on.

---

## 1. Mental model in one page

- A **household** is one home server (a Node/Hono process in Docker on a box at home)
  that holds **one** shared inventory in its own SQLite file with the **same schema**
  as the phone (`home-server/Dockerfile` copies `src/core`, `src/db`, `src/repositories`
  from the app repo; `home-server/src/index.ts:42-44` migrates it with the app's
  `migrate`). There is exactly one household per server, always named `"Home"`
  (`home-server/src/contract.ts:17`, K18).
- A phone **joins** by typing a 26-character Crockford-base32 **household code** (the
  "bootstrap secret", printed once in the server log when the server first starts) and a
  name for itself. The server answers with a per-device **bearer token** (64 hex chars).
  There is **no discovery**: no Bonjour/mDNS, no LAN URL, no Tailscale, no QR pairing.
  The phone always talks to one fixed HTTPS origin baked into the build
  (`https://inventory.wystudio.be` by default, `src/services/config.ts:72-74`), which is a
  Cloudflare Tunnel hostname in front of the box (`compose.yaml` comments; port bound to
  loopback only). Copy says it plainly: "Joining needs the internet, even at home."
  (`strings.join.offline`, `src/i18n/strings.ts:942-943`).
- **When joined, the server is the source of truth.** Every read goes over HTTP
  (`src/services/household/httpRepositories.ts`); nothing is read from local SQLite.
  Every successful write made *by this phone* is additionally mirrored into local SQLite
  (the **shadow copy**, `src/services/household/shadow.ts:5-9`) so the older
  phone-backup feature still has something to back up (K5). Writes made by other phones
  are never mirrored.
- There is **no offline write queue** and **no push/live updates** in the app. Lists
  refresh on screen focus, after writes, on app foreground, and when the connection
  recovers. A calm connection state machine (`online → unsure → offline`, plus
  `revoked`) is driven passively by the requests the app makes anyway, and a 10 s health
  ping runs only while offline.
- Any joined phone can list and remove any other phone. A phone removed elsewhere gets a
  full-screen "no longer part of the household" layer on its next request (401).
- **Leaving** just forgets the session locally (best-effort revoke of its own token in
  the background). Shadow data stays in local SQLite.
- A phone that had its **own inventory before it first joined** is offered, once, to copy
  it into the household (an id-preserving upsert of all 7 tables + photo bytes).

---

## 2. Household model

### 2.1 Server identity and storage

| Thing | Value | Source |
|---|---|---|
| Contract version | `1` (reported by `/v1/health`, `/v1/pair`, `/v1/session`, `/v1/status`) | `home-server/src/contract.ts:8` |
| Default listen port | `8788` (env `PORT` overrides, integer 1–65535), host `0.0.0.0`; `compose.yaml:20` publishes it only on `127.0.0.1:8788` for cloudflared | `home-server/src/contract.ts:11`, `home-server/src/index.ts:22-30, 76` |
| Public origin returned to phones | env `INVENTORY_PUBLIC_ORIGIN`, default `https://inventory.wystudio.be` | `home-server/src/index.ts:53` |
| Household name | `"Home"` (fixed) | `home-server/src/contract.ts:17` |
| Bootstrap secret | 16 CSPRNG bytes | `home-server/src/contract.ts:20` |
| Device token | 32 CSPRNG bytes, hex on the wire (64 chars) | `home-server/src/contract.ts:23`, `home-server/src/control.ts:93-94` |
| Data files | `<INVENTORY_DATA_DIR>/inventory.db` (inventory, app schema), `control.db` (household + devices); `INVENTORY_DATA_DIR` defaults to `./data` | `home-server/src/index.ts:18-20, 41-46` |
| Photo bytes | Not on the box: R2 via the `inventory-sync` Worker, keys `household/primary/photos/<id>.webp` and `<id>-thumb.webp` | `home-server/src/photos.ts:27-30, 91-128` |

`control.db` schema (`home-server/src/control.ts:24-39`):

```sql
CREATE TABLE IF NOT EXISTS household (
  id              TEXT PRIMARY KEY NOT NULL,
  name            TEXT NOT NULL,
  bootstrap_hash  TEXT NOT NULL,
  created_at      INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  id            TEXT PRIMARY KEY NOT NULL,
  name          TEXT NOT NULL,
  token_hash    TEXT NOT NULL UNIQUE,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER
);
```

- On first open with no `household` row, the server creates one (`id = newId()`,
  name `"Home"`, `bootstrap_hash = sha256hex(secret)`), and prints the formatted secret
  once to stdout; it is never written to disk or R2 and cannot be recovered
  (`home-server/src/control.ts:163-172`, `home-server/src/index.ts:46-51`).
- Only hashes are stored: `sha256` of the raw secret bytes and of the raw token bytes
  (`home-server/src/control.ts:41-43, 101`). Comparison is timing-safe
  (`home-server/src/control.ts:45-50`).

### 2.2 The household code (bootstrap secret)

- Encoding: Crockford base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`
  (`home-server/src/base32.ts:7`), MSB-first bit packing; 16 bytes → 26 chars
  (`home-server/src/base32.ts:20-37`). Printed in groups of 5 joined by `-`
  (`home-server/src/base32.ts:60-62`), e.g. `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-X`.
- Server decode (`home-server/src/base32.ts:39-58`): remove all `-`, trim, uppercase;
  `I`→1, `L`→1, `O`→0 (`:14-16`); any other non-alphabet char (including internal spaces,
  `U`) → reject; decode; must be exactly 16 bytes (`home-server/src/control.ts:52-56`).
  Note: trailing bits beyond 128 are ignored, so a 27-char string whose first 26 chars
  are right would also decode to 16 bytes; the client never sends that (length check).
- The **same code is reusable** for any number of phones; it is not one-time and never
  expires. There is no admin UI to rotate it.
- Client-side normalisation (what the phone actually sends) is in §12.4.

### 2.3 Pairing (joining)

`POST /v1/pair` (unauthenticated) — `home-server/src/app.ts:51-78`,
`home-server/src/control.ts:80-105`:

1. Body must be a JSON object with string `bootstrapSecret` and string `deviceName`,
   else `400 {"error":"invalid_json"}` (unparsable / not an object) or
   `400 {"error":"invalid_body"}` (wrong types).
2. Secret normalised/decoded (§2.2); hash compared with `household.bootstrap_hash`.
3. `name = deviceName.trim()`; empty → treated as failure.
4. Any failure in 2–3 → `401 {"error":"unauthorized"}`.
5. Success: new device row `(id = newId() UUIDv4, name, sha256(token bytes), now, now)`
   — `last_seen_at` starts at the pairing time (`home-server/src/control.ts:98-102`), so with
   this server a device's `lastSeenAt` is never `null` and the app's "Never used" label
   (§13.2) only appears for rows written some other way. Response `200`:

```json
{ "deviceId": "<uuid>", "token": "<64 lowercase hex>", "origin": "https://inventory.wystudio.be",
  "householdName": "Home", "contractVersion": 1 }
```

Client side (`src/services/household/client.ts:77-101`):

- Origin = `request.origin ?? appConfig.householdOrigin`, trailing `/`s stripped (`:78`).
  The app never passes an origin; the build constant is used (`src/providers/HouseholdProvider.tsx:51`).
- Sends `{bootstrapSecret, deviceName}` JSON with no token (`:79-86`).
- Requires `token`, `deviceId`, `origin` to be strings, else throws
  `HouseholdHttpError(500, "invalid_response")` (`:87-93`).
- Builds the session: `origin` = **server's** `origin` with trailing slashes stripped
  (so the session may point somewhere other than the build constant),
  `deviceName = request.deviceName.trim()`, `householdName` = server value if string else
  `"Home"` (`:94-100`). **`contractVersion` is ignored** (see Open questions).

### 2.4 Device authentication on every other request

`requireDevice` middleware (`home-server/src/app.ts:80-99`):

- If the web lookup page is enabled and a valid `household_web` cookie is present → allowed
  without a device (browser only; irrelevant to the app).
- Else header `Authorization` must match `/^Bearer\s+(\S+)$/i`; token must be exactly 64
  hex chars (case-insensitive) (`home-server/src/control.ts:175-181`); looked up by
  `sha256(bytes)`. Missing/invalid/unknown → `401 {"error":"unauthorized"}`.
- On success the server **updates `devices.last_seen_at = now` on every authenticated
  request** (`home-server/src/app.ts:96`, `home-server/src/control.ts:141-143`).
- Tokens never expire and are never rotated. Revocation = deleting the device row.

### 2.5 Phones in the household

- `GET /v1/devices` → `{"devices":[{id,name,createdAt,lastSeenAt}]}` ordered by
  `created_at ASC` (`home-server/src/app.ts:112-115`, `home-server/src/control.ts:107-115`).
  `lastSeenAt` is a number or `null`.
- `DELETE /v1/devices/:id` → `204` if a row was deleted, `404 {"error":"not_found"}`
  otherwise (`home-server/src/app.ts:117-122`). **Any** paired device may delete
  **any** device, including itself (K19, #47; `home-server/test/pair.test.ts:118`).
  The removed device's next request gets 401.

### 2.6 Roles, multiple households, invites

None. All devices are equal; one household per server; no invites, no owner concept.
The only authority is knowing the household code.

---

## 3. HTTP wire contract

### 3.1 Common request rules (client)

All requests go through `householdFetch` (`src/services/household/client.ts:143-191`):

| Aspect | Behavior | Source |
|---|---|---|
| URL | `${session.origin}${path}` (plain concatenation; path already contains query) | `client.ts:160` |
| Method | default `GET` | `client.ts:161` |
| `Accept` | always `application/json` (even for photo GETs) | `client.ts:163` |
| `Content-Type` | `application/json` when a JSON body is sent; `application/octet-stream` when raw bytes are sent | `client.ts:164-167` |
| `Authorization` | `Bearer <token>` when a token is given (every call except pair and health) | `client.ts:168` |
| Body | `JSON.stringify(json)` or raw bytes | `client.ts:170-173` |
| Timeout | default **20 000 ms**; overridden per call (see table below). Implemented as an `AbortController` abort; the timer is cleared in `finally` once the `fetch` promise resolves. **On the shipped RN app that is after the entire response body has arrived**: RN's `fetch` is the `whatwg-fetch` polyfill over XHR (`node_modules/react-native/Libraries/Network/fetch.js:15`), which resolves only in `xhr.onload` with the fully buffered body (`node_modules/whatwg-fetch/dist/fetch.umd.js:546-562`). So the deadline covers upload, server time **and** the body download (same as the sync client, `03-sync-account.md` §4.1; total wall-clock, `09-app-shell-lifecycle-config.md` §8.4). Under Node/Jest fetch the body would not be covered; that is test-only | `client.ts:155-156, 188-190` |
| Timeout error | `HouseholdHttpError(status: 0, code: "timeout")` | `client.ts:181-183` |
| Network error | `HouseholdHttpError(status: 0, code: "offline")`, plus telemetry `logError('household_fetch_failed', {errorClass})` | `client.ts:184-187` |
| Retries / backoff | **none** anywhere in the client | — |
| Path ids | Inventory ids are interpolated **without** URL-encoding (`/v1/spaces/${id}`); devices and photos use `encodeURIComponent`; query values are encoded | `httpRepositories.ts:132,166,234,360`; `devices.ts:69`; `photoCache.ts:29` |

Per-call timeouts:

| Call | Timeout | Source |
|---|---|---|
| Everything not listed | 20 000 ms | `client.ts:156` |
| `PUT /v1/photos/:id` during item create | 60 000 ms | `httpRepositories.ts:72` |
| `POST /v1/import` and each import `PUT /v1/photos/:id` | 60 000 ms | `importHousehold.ts:38, 65` |
| `GET /v1/health` (offline ping) | 5 000 ms | `ConnectionProvider.tsx:41, 139` |
| Leave: `DELETE /v1/devices/<self>` | 5 000 ms | `app/household.tsx:40, 223` |

### 3.2 Response parsing (client)

`householdRequest` (`src/services/household/client.ts:103-141`), used by everything except
photo GET/PUT-during-import and health:

1. `204` → returns `{}` without reading the body (`:115`).
2. Read text; if non-empty, `JSON.parse`; parse failure → `HouseholdHttpError(status, "invalid_json")`
   **before** looking at the status (`:116-124`). So a Cloudflare HTML 52x page becomes
   `HouseholdHttpError(530, "invalid_json")`, and a Hono default 500 page
   (`Internal Server Error`, text/plain) becomes `HouseholdHttpError(500, "invalid_json")`.
3. `409` → throw `ConflictError(updatedAt)` where `updatedAt = Number(body.updatedAt)` if
   the key is present and the result is finite, else `null` (`:125-131`; `src/core/conflict.ts:8-16`, which carries
   `status = 409`, `code = "conflict"`). JS `Number()` coercion details to reproduce:
   `"updatedAt": null` → `0` (not `null`), a numeric string such as `"11"` → `11`, any other
   string/object → `NaN` → `null`; an empty body → `null`. `ConflictError` is **not** a
   `HouseholdHttpError`.
4. Any other non-2xx → `HouseholdHttpError(status, String(body.error))` if the body has an
   `error` key, else `HouseholdHttpError(status, "http_<status>")` (`:132-138`).
5. 2xx with a non-object JSON (array, number, `null`) → `{}` (`:139`).

### 3.3 Reachability side channel

Every `householdFetch` reports one `Reachability` value to all registered listeners
(`src/services/household/client.ts:21-59, 176, 180`):

| Outcome | Reported |
|---|---|
| Any HTTP response with status `502` or `520…530` (Cloudflare "origin down") | `offline` |
| HTTP `401` **and** the request carried a token | `unauthorized` |
| Any other HTTP response (incl. 401 on pairing, 404, 409, 500) | `ok` |
| Thrown network error or timeout | `offline` |

Listeners are a global `Set`; a throwing listener is ignored and never fails the request
(`client.ts:39-47`). Unsubscribe is a returned closure (`client.ts:30-37`). This channel
feeds the connection state machine (§9). Photo fetches (`photoCache.ts:26`) and imports
also report through it.

### 3.4 Server error codes

All server errors are JSON `{"error": "<code>"}` unless noted.

| HTTP | `error` | When | Source |
|---|---|---|---|
| 400 | `invalid_json` | Body not JSON / not an object | `inventory.ts:388-398`, `app.ts:52-60` |
| 400 | `invalid_body` | Required field missing / wrong type | `app.ts:64-66`, `inventory.ts:86,132,207,330,343` |
| 400 | `containerId_required` | `GET /v1/items` with no selector | `inventory.ts:182` |
| 400 | `invalid_photo` | `photo` present but not `{id: <uuid>…}` | `inventory.ts:209-212` |
| 400 | `photo_missing` | `photo.id` not found in the photo store | `inventory.ts:221-224` |
| 400 | `invalid_id` | `PUT /v1/photos/:id` id is not a UUID (`/^[0-9a-f]{8}-…-[0-9a-f]{12}$/i`) | `inventory.ts:374-376, 404-408` |
| 400 | `empty_upload` | `PUT /v1/photos/:id` with 0 bytes | `inventory.ts:378` |
| 400 | *free text* | Repository `Error.message` (e.g. `system_record`, `Item name is required.`, `Quantity must be a whole number of 0 or more.`, SQLite constraint text, sharp decode errors) | `inventory.ts:459-461` and every `catch` |
| 401 | `unauthorized` | Bad pairing code or missing/unknown token | `app.ts:69, 91, 94` |
| 404 | `not_found` | Missing record / device / photo | many |
| 409 | `conflict` (+ `"updatedAt": <number>`) | Item PATCH with stale `updatedAt` | `inventory.ts:298-300` |
| 500 | *(text/plain "Internal Server Error")* | Unhandled throw (Hono default handler). Happens for `PATCH`/`DELETE` on the drop-zone space/container (`system_record` thrown outside try/catch) and on any throw in a route without try/catch: `PATCH`/`DELETE` spaces & containers, `DELETE /v1/items/:id`, `DELETE /v1/containers/:id/qr`, `POST /v1/qr/scan`, every `GET`, and `GET /v1/photos/:id` when the Worker photo store answers anything but 2xx/404 | `inventory.ts:76-184, 259-276, 305-314, 339-351`; `src/repositories/spaces.ts:44-46`, `src/repositories/containers.ts:57-59`; `home-server/src/photos.ts:121-122` |
| 404 | *(text/plain "404 Not Found")* | Unknown route (Hono default) — e.g. any inventory route on a server started without repos. Client sees `HouseholdHttpError(404, "invalid_json")` (§3.2 step 2), which `callIgnoring404` and `describeError` still treat as 404 | `home-server/test/health.test.ts:25` |
| 503 | `photos_not_configured` | Server has no `HOUSEHOLD_PHOTO_SECRET` | `inventory.ts:214-216, 260, 372` |

Other free-text codes worth knowing: `system_record` also comes back as `400` from
`POST /v1/qr/bind` / `POST /v1/containers/drop-zone/qr` (thrown inside try/catch,
`src/repositories/qr.ts:119`); a non-`Error` throw inside a try/catch becomes
`"invalid_body"` (`inventory.ts:459-461`).

### 3.5 Endpoint catalogue

`Auth` = `Authorization: Bearer <token>` required. Client column names the Swift-side
caller (see §6 for the repository method mapping).

| Method & path | Auth | Request | Success | Client usage |
|---|---|---|---|---|
| `GET /v1/health` | no | — | `200 {"ok":true,"contractVersion":1}` — exactly these two keys (`app.ts:44-49`; `test/health.test.ts:10`) | offline ping (§9.4) |
| `POST /v1/pair` | no | `{bootstrapSecret, deviceName}` | `200` pair body (§2.3) | join |
| `GET /v1/session` | yes | — | `{deviceId, deviceName, householdName:"Home", origin, contractVersion}` (`app.ts:101-110`) | **unused by app** |
| `GET /v1/devices` | yes | — | `{"devices":[Device]}` | Household screen list |
| `DELETE /v1/devices/:id` | yes | — | `204` | remove phone, leave |
| `GET /v1/status` | yes | — | `{householdName, contractVersion, schemaVersion: 7, revision, deviceCount}` (`inventory.ts:42-51`) | **unused by app** |
| `GET /v1/events` | yes | — | SSE stream (§3.8) | **unused by app** (web desk only) |
| `GET /v1/spaces` | yes | — | `{"spaces":[SpaceWithCounts]}` (only `kind='normal'`, sorted `name COLLATE NOCASE ASC`) | spaces list, `countAll` |
| `POST /v1/spaces` | yes | `{name, icon, color}` all non-empty strings | `201 Space` | create space |
| `GET /v1/spaces/:id` | yes | — | `Space` / 404 | space detail |
| `PATCH /v1/spaces/:id` | yes | any of `name`,`icon`,`color` (non-string → ignored) | `Space` / 404 | edit space |
| `DELETE /v1/spaces/:id` | yes | — | `{"deleted":true,"orphanedPhotoUris":["r2:…"]}` / 404 | delete space |
| `GET /v1/containers?spaceId=` | yes | — | `{"containers":[ContainerWithCounts]}` (`kind='normal'`, `created_at DESC`) | containers in space |
| `GET /v1/containers` | yes | — | `{"containers":[ContainerWithSpace]}` (`kind='normal'`, `space name NOCASE ASC, created_at DESC`) | container picker |
| `POST /v1/containers` | yes | `{spaceId, visualType, name?}` | `201 Container` | create container |
| `GET /v1/containers/:id` | yes | — | `ContainerWithCounts` / 404 | container detail, QR lookup |
| `PATCH /v1/containers/:id` | yes | `{name?, visualType?, spaceId?}` | `Container` / 404 | edit/move container |
| `DELETE /v1/containers/:id` | yes | — | `{"deleted":true,"orphanedPhotoUris":[…]}` / 404 | delete container |
| `GET /v1/items?containerId=` | yes | `containerId=drop-zone` is treated as unsorted | `{"items":[ItemWithContext]}` | container items |
| `GET /v1/items?unsorted=1` | yes | — | `{"items":[ItemWithContext]}` | drop zone |
| `GET /v1/items?recent=1&limit=N` | yes | `limit` number (numeric string), default 40; server clamps to `max(1, min(floor(limit), 100))` (`src/repositories/items.ts:195`) | `{"items":[ItemWithContext]}` | recently added |
| `POST /v1/items` | yes | JSON item draft (below), or multipart (not used by app) | `201 ItemWithContext` | create item |
| `GET /v1/items/:id` | yes | — | `ItemWithContext` / 404 | item detail |
| `PATCH /v1/items/:id` | yes | item patch (below) | `Item` (no context!) / 404 / 409 | edit/move/quantity |
| `DELETE /v1/items/:id` | yes | — | `{"deleted":true,"orphanedPhotoUris":[…]}` / 404 | delete item |
| `GET /v1/search?q=` | yes | `q` (default `""`) | `SearchResults` | search |
| `POST /v1/containers/:id/qr` | yes | no body | `201 QrBinding` | create & bind label |
| `POST /v1/qr/bind` | yes | `{token, containerId}` | `200 QrBinding` | bind scanned label |
| `POST /v1/qr/scan` | yes | `{raw}` (server also accepts `{token}`) | `200 ScanOutcome` | resolve a scan |
| `DELETE /v1/containers/:id/qr` | yes | — | `204` / 404 | unbind label |
| `POST /v1/import` | yes | `HouseholdDump` JSON | `200 {"ok":true,"spaces":n,"containers":n,"items":n,"photos":n}` — counts of the **arrays sent**, not rows applied | copy-in |
| `PUT /v1/photos/:id` | yes | raw image bytes (any content type) | `201 PreparedPhoto` | photo upload |
| `GET /v1/photos/:id[?thumb=1]` | yes | — | `200` bytes, `content-type` from store (`image/webp`), `cache-control: private, max-age=31536000, immutable` / 404 / 503 | photo cache |

Server notes per endpoint:

- `GET /v1/items` selector precedence (`inventory.ts:173-184`): `containerId === "drop-zone"`
  **or** `unsorted === "1"` → unsorted; else `recent === "1"` → recent(`asNumber(limit) ?? 40`);
  else `containerId` required. All three lists are ordered `created_at DESC` (newest first,
  `src/repositories/items.ts:178, 187, 197`). In every `ItemWithContext`, `photoId` /
  `photoUri` / `photoThumbUri` come from the item's **earliest** photo row
  (`ORDER BY p.created_at ASC LIMIT 1`, `src/repositories/items.ts:72-91`), and
  `ContainerWithCounts.qrToken` is the token of the container's newest binding
  (`src/repositories/containers.ts:70-71, 96-97`).
- `POST /v1/items` JSON fields (`inventory.ts:186-257`): `containerId` (required string);
  `name` (string, absent → repo default empty name); `category` (string or null);
  `quantity` (number or numeric string; absent → 1); `notes`; `tags` (array of strings;
  non-strings dropped; in multipart a comma-separated string); `photo` optional object
  `{id (UUID, required), uri?, thumbUri?, width?, height?, byteSize?}`. With a `photo`, the
  server fetches the full image from the store to prove it exists; missing → 400
  `photo_missing`; defaults `uri = "r2:household/primary/photos/<id>.webp"`,
  `thumbUri = "r2:…/<id>-thumb.webp"`, `width/height = 0`, `byteSize = stored length`
  (`inventory.ts:434-448`). Response is the freshly read `ItemWithContext`.
  Repository validation that surfaces as `400 {"error":"<message>"}`
  (`src/repositories/items.ts:30-35, 136-165, 225-243`): `name` key absent → `""` (allowed),
  but a present name that is blank after trimming → `"Item name is required."`; `name`,
  `category`, `notes` are trimmed and blank `category`/`notes` become `null`; `quantity`
  must be an integer ≥ 0 (`"Quantity must be a whole number of 0 or more."`); tags are
  trimmed, blank ones dropped and de-duplicated case-insensitively; an unknown `containerId`
  fails with the SQLite FK message. `photo: null` is the same as no photo (`inventory.ts:209`).
- `PATCH /v1/items/:id` (`inventory.ts:278-303`): `containerId` string (else no change);
  `name`: key present and string → set; `null`/non-string → **no change**;
  `category` / `notes`: key present → `string` sets (trimmed; blank → `NULL`), `null` or any
  other non-string value **clears**; `quantity` number or
  numeric string (else no change); `tags`: array → replace set; anything else → no change;
  `updatedAt` number (or numeric string) → optimistic lock (`expectedUpdatedAt`). Mismatch → `409
  {"error":"conflict","updatedAt":<current>}`. Item deleted meanwhile → `404`. The same
  repository validation as create applies (`src/repositories/items.ts:289-303`): a present
  name that is blank → `400 "Item name is required."`; bad quantity → `400`.
- `PATCH /v1/spaces/:id`: only keys present are considered; non-string values are ignored
  (`inventory.ts:104-107`). `name` is trimmed; a blank name is **accepted** (no validation,
  `src/repositories/spaces.ts:110-129`). The drop-zone space → `500` (see §3.4).
- `PATCH /v1/containers/:id` (`inventory.ts:153-165`): `name` key present → string sets
  (trimmed; blank → `NULL`), any non-string value including `null` clears
  (`src/repositories/containers.ts:160-161`); `visualType` string (not validated against the
  enum server-side, and no CHECK constraint in the schema) else no change; `spaceId` string
  else no change. `POST /v1/containers` likewise does not validate `visualType`; the server
  generates the id and `shortCode` (`src/repositories/containers.ts:112-151`).
- Every successful write bumps the in-process revision counter (`inventory.ts:36-40`,
  `home-server/src/hub.ts:12-31`). The counter starts at 0 on each server start.

### 3.6 JSON shapes

All timestamps are integer **milliseconds since epoch** (JS `Date.now()`); store as `Int64`.
Ids are lowercase UUID v4 strings (`src/core/id.ts:41-54`) except the system ids
`drop-zone` and `drop-zone-space` (`src/db/constants.ts`).

```text
Space            { id, name, icon, color, createdAt, updatedAt }
SpaceWithCounts  Space + { containerCount: Int, itemCount: Int }
Container        { id, spaceId, name: String?, visualType, shortCode, createdAt, updatedAt }
  visualType ∈ box | drawer | shelf | cabinet | bin | bag | crate | other   (src/db/types.ts:56-65)
ContainerWithCounts  Container + { itemCount: Int, qrToken: String? }
ContainerWithSpace   Container + { spaceName: String, itemCount: Int }
Item             { id, containerId, name, category: String?, quantity: Int, notes: String?, createdAt, updatedAt }
ItemWithContext  Item + { photoId: String?, photoUri: String?, photoThumbUri: String?, tags: [String],
                          spaceId, spaceName, spaceIcon, spaceColor, containerName: String?, containerShortCode }
ItemSearchResult ItemWithContext + { matchKind: "direct" | "location" }
LocationSearchResult { kind: "space" | "container", id, title, subtitle, spaceId, itemCount }
SearchResults    { terms: [String], locations: [LocationSearchResult], items: [ItemSearchResult] }
QrBinding        { id, token, containerId, createdAt, updatedAt }
ScanOutcome      { kind: "bound", container: Container, token } | { kind: "unknown", token } | { kind: "invalid", raw }
PreparedPhoto    { id, uri: "r2:…", thumbUri: "r2:…", width: Int, height: Int, byteSize: Int }
Device           { id, name, createdAt, lastSeenAt: Int? }
DeleteResult     { deleted: Bool, orphanedPhotoUris: [String] }
```

(Sources: `src/db/types.ts:35-143`, `src/repositories/search.ts:11-30`,
`src/repositories/qr.ts:48-51`, `home-server/src/photos.ts:18-25`,
`home-server/src/control.ts:11-16`, `src/repositories/containers.ts:225-241`.)
`photoUri`/`photoThumbUri` from the server are `r2:` strings; the client rewrites them to
local cache file URLs when hydrating (§8).

### 3.7 Field omission vs `null` — important for Codable

The JS client builds bodies with `undefined` for "not given" and `JSON.stringify` drops
those keys, while `null` is sent as JSON `null` (e.g. `category: null` clears)
(`httpRepositories.ts:252-263, 271-284, 188-195`). The server distinguishes key-absent
from key-null for `category`, `notes` (items) and `name` (containers) (§3.5). Swift's
synthesized `Encodable` omits `nil` optionals, so **model patches as tri-state**
(`unchanged` / `set(value)` / `clear`) with a custom `encode(to:)`.

### 3.8 Server-Sent Events (not used by the app today)

`GET /v1/events` (`home-server/src/inventory.ts:53-74`): immediately sends
`event: change` / `data: {"revision":N}`; on each write sends the same with the new
revision; every 15 000 ms sends `event: ping` / `data: ` (empty). The hub comment says
focus-refetch is the real guarantee and SSE only lets a client skip a round trip
(`home-server/src/hub.ts:1-5`). The native app may adopt it later (Open question Q6);
for parity, do not.

### 3.9 Server-only surfaces (for awareness, not to port)

- **Web lookup page** (`home-server/src/web.ts`): enabled when `HOUSEHOLD_WEB_PASSWORD` is set;
  `POST /v1/web/login {password}` sets cookie `household_web` (httpOnly, SameSite=Lax,
  Secure on https, 30 days, in-memory sessions lost on restart), `GET /v1/web/me`,
  `POST /v1/web/logout`, static `/`, `/item/:id`, `/space/:id`, `/container/:id`,
  `/app.css`, `/app.js`, `/fonts/:name`. The cookie also passes `requireDevice`.
- **Nightly DB backup** (`home-server/src/backup.ts`): every 60 s a tick checks whether it is
  hour 3 in `Europe/Brussels` and not yet run that local date; uploads `VACUUM INTO`
  snapshots of `inventory.db` and `control.db` to the Worker at
  `PUT /v1/household/db/<snapshotId>/<file>` (`content-type: application/vnd.sqlite3`,
  `Bearer HOUSEHOLD_PHOTO_SECRET`); snapshot id = ISO-8601 without millis and with `:`→`-`
  (`2026-08-21T01-00-00Z`); keeps the newest 7 complete snapshots
  (`home-server/src/contract.ts:26-30`, `backup.ts:23-28, 50-60, 168-234`).
  Restore CLI writes both files and deletes `-wal`/`-shm` (`home-server/src/restore.ts:24-54`).
  Consequence for the app: the household `inventory.db` uses the app schema
  (`LATEST_SCHEMA_VERSION = 7`, `home-server/test/migrate.test.ts:10`), so the native app
  must not fork the schema or the dump format.
- **Photo store** (`home-server/src/photos.ts`): `PUT/GET <worker>/v1/household/photos/<id>?kind=full|thumb`
  with `Bearer HOUSEHOLD_PHOTO_SECRET`. Server re-encodes every upload with sharp:
  EXIF-rotate; full = fit inside 1400×1400, no enlargement, WebP q80; thumb = 320×320
  cover, WebP q70 (`photos.ts:7-9, 37-71`).

---

## 4. Client transport — Swift design notes

Port `client.ts` as a `HouseholdClient` (a `Sendable` struct or actor over `URLSession`):

- `func send(path:method:token:json:bytes:timeout:) async throws -> (HTTPURLResponse, Data)` ≙
  `householdFetch`; `func request(...) async throws -> JSONObject` ≙ `householdRequest`.
- Error type mirroring the JS classes, because UI copy depends on `status` and `code`
  (`src/ui/errors.ts:16-24, 56-75`; `src/ui/household/join.ts:73-81`):
  ```swift
  enum HouseholdError: Error, Sendable {
      case http(status: Int, code: String)   // status 0 + "offline" / "timeout" for transport failures
      case conflict(updatedAt: Int64?)       // 409
  }
  ```
- Timeout: on device the JS deadline covers the whole exchange including the response body
  (§3.1). `URLRequest.timeoutInterval` is an *idle* timeout, not a deadline. Implement a
  structured-concurrency deadline around `URLSession.data(for:)` / `upload(for:from:)`
  (both return only once the full body is in memory), racing `Task.sleep`, and map the
  deadline firing to `.http(status: 0, code: "timeout")`. This is exact parity, not a
  stricter difference. Share the helper with the sync and recognition clients
  (`09-app-shell-lifecycle-config.md` §13.4 `withTotalTimeout`).
- Map `URLError` (`.notConnectedToInternet`, `.networkConnectionLost`, `.cannotFindHost`,
  `.cannotConnectToHost`, `.timedOut`, `.dnsLookupFailed`, `.secureConnectionFailed`…) to
  `"offline"` (or `"timeout"` for `.timedOut` if you use URLSession's timeout).
- Reachability bus: a single `@MainActor` (or actor) publisher that the client calls after
  every request with the classification in §3.3. An `AsyncStream` per subscriber or an
  `@Observable` `ConnectionMonitor` with a `report(_:)` entry point both work. Listener
  failures must not propagate.
- The RN-specific byte copy (`client.ts:158-159`) is unnecessary; send `Data` directly with
  `URLSession.upload(for:from:)`.
- **Decoding strictness.** The JS never validates response shapes: bodies are cast
  (`as never`) and missing list keys fall back to `[]` (`httpRepositories.ts:129, 167, 216,
  224, 313`; `search` falls back when `items` is not an array, `:361`). Only `pair`
  (`client.ts:87-93`), the photo upload (`httpRepositories.ts:74-76`) and `listDevices`
  (`devices.ts:50`) check fields and throw `HouseholdHttpError(500, "invalid_response")`.
  Synthesized `Codable` would throw on any missing key — behaviour the JS does not have.
  Decode list wrappers with `decodeIfPresent(...) ?? []`, and map any decoding failure of a
  2xx body to `.http(status: <response status>, code: "invalid_response")` so it reads as a
  `server` error in `describeError` (§10) rather than crashing or reading as "local".
- No ATS exception is needed for the production HTTPS origin. The prebuilt RN
  `ios/Inventory/Info.plist:43-49` has `NSAllowsLocalNetworking = true` (Expo dev default);
  keep it only in Debug if developers point `householdOrigin` at a LAN IP
  (`src/ui/household/__tests__/join.test.ts:86` shows `http://192.168.1.5:8788/`).
- Build configuration: `householdOrigin` comes from `EXPO_PUBLIC_HOUSEHOLD_ORIGIN` with
  trailing slashes stripped, default `https://inventory.wystudio.be`
  (`src/services/config.ts:72-74`). Native: an Info.plist key fed from an `.xcconfig`
  per configuration.

---

## 5. Session persistence (and reading the Expo build's session)

`src/services/household/session.ts`:

- Key `household.session.v1` (`:5`), value = JSON string of
  `{"origin","token","deviceId","deviceName","householdName"}` (written as the session
  object, `:31-33`; property order origin, token, deviceId, deviceName, householdName
  from `client.ts:94-100`).
- Load (`:7-29`): missing → `nil`; JSON parse error or any keychain error → `nil`;
  `origin`, `token`, `deviceId` must be strings else `nil`; `deviceName` defaults to
  `"This phone"`, `householdName` to `"Home"`. A corrupt item is treated as "not joined"
  but is not deleted.
- Clear (`:35-41`): delete; errors ignored.

**Keychain layout written by expo-secure-store 57.0.1 on iOS** — the native app must read
this on first launch (`node_modules/expo-secure-store/ios/SecureStoreModule.swift:88-123,
172-191`, `SecureStoreOptions.swift:8`):

| Attribute | Value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `"app:no-auth"` (written with `requireAuthentication = false`); reads also fall back to `"app:auth"` and legacy `"app"` |
| `kSecAttrAccount` | **`Data("household.session.v1".utf8)`** (a `Data`, not a `String`) |
| `kSecAttrGeneric` | same `Data` |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlocked` (default) |
| `kSecAttrAccessGroup` | not set (default app group; same Team ID + bundle id required) |
| `kSecValueData` | UTF-8 JSON as above |

Recommendation: use the single canonical `ExpoCompatibleKeychain` from
`02-device-storage-migration.md` §4.3 (do not write a second keychain wrapper). It queries
exactly these attributes with the account as `Data`, reading service `app:no-auth` and then
legacy `app`; `app:auth` items cannot exist (no call site ever passed
`requireAuthentication`), so 02 skips that probe to rule out any biometric prompt. Both the
household session and the backup recovery code (owned by the Backup spec) then survive the
update. Keep writing the same JSON shape under the same attributes, so a TestFlight
rollback to the RN build still works. Exact write semantics of expo-secure-store to mirror
(`SecureStoreModule.swift:89-144`): `SecItemAdd` with service `app:no-auth`, `kSecAttrAccessible`
and `kSecValueData`; on success also `SecItemDelete` the legacy `app` and the `app:auth`
variants; on `errSecDuplicateItem` fall back to `SecItemUpdate` of `kSecValueData` only.
Delete removes all three variants (`:43-51`). Reads use `kSecMatchLimitOne` +
`kSecReturnData` and decode UTF-8; any status other than success/not-found is an error
(`:146-170`), which `loadHouseholdSession` turns into "not joined".

Keychain items survive app deletion on iOS while AsyncStorage and SQLite do not, so a
reinstalled app (RN or native) starts **joined** with an empty local database; on that
start `markJoinedBefore()` runs (§9.2), so no import offer is ever made. Parity; keep.

`HouseholdProvider` (`src/providers/HouseholdProvider.tsx`):

- On launch loads the session, then sets `ready = true` (`:34-46`). The root layout shows
  the boot screen until the DB is ready, onboarding is known **and** `household.ready`
  (`app/_layout.tsx:154-156`), so a paired phone never flashes its local inventory.
- `pair(code, name)`: `pairWithHousehold` → save → publish session (`:50-54`). Save errors
  propagate (join fails) — but the server has already created the device row, so a failed
  keychain write leaves an orphan device in the household list (shown with its
  `last_seen_at` = pairing time, §2.3). Publishing the session immediately swaps the
  Household screen to the Paired view (§12.1) **before** `JoinForm.join()` has finished
  (`markJoinedBefore`, read-back, toast and navigation still run afterwards, §12.3); the
  native join task must therefore not be owned by the join form's view lifetime.
- `disconnect()`: clear keychain → publish `nil` (`:56-59`). No network call here.
- `repos` = HTTP repositories when a session exists (`:48`).

Native: an `@Observable @MainActor final class HouseholdStore { var session: HouseholdSession?; var ready: Bool }`.

---

## 6. Choosing local vs HTTP repositories

`useRepositories()` (`src/providers/DatabaseProvider.tsx:108-120`): if a session exists,
screens get `withLocalShadow(createHttpRepositories(session), localRepos)`; otherwise the
local SQLite repositories. The object is rebuilt only when the session or the DB changes.
`useDatabase().state.repos` is **always** the raw local repositories — used deliberately by
the join snapshot and the import (§11).

Native: a protocol `InventoryRepositories` with three implementations:
`LocalRepositories` (GRDB), `HTTPRepositories(session:)`, and a decorator
`ShadowingRepositories(remote:local:)`. An environment value switches on session changes.

### 6.1 `HTTPRepositories` method by method

`src/services/household/httpRepositories.ts`. `call(path, {method, json})` =
`householdRequest` with the session token (`:30-40`); `callIgnoring404` returns `nil` on a
404 `HouseholdHttpError` (`:42-52`).

| Repository method | HTTP | Result mapping | Source |
|---|---|---|---|
| `db` | — | a stub whose every method throws `"Local SQLite is not used while paired with the household server."` | `:11-23, 124` |
| `spaces.listWithCounts()` | `GET /v1/spaces` | `body.spaces ?? []` | `:127-130` |
| `spaces.getById(id)` | `GET /v1/spaces/{id}` | 404 → `nil` | `:131-134` |
| `spaces.create(input)` | `POST /v1/spaces` json `input` verbatim = `{name, icon, color}` (server trims `name`) | body | `:135-137` |
| `spaces.update(id, input)` | `PATCH /v1/spaces/{id}` json `input` | 404 → `nil` | `:138-141` |
| `spaces.deletionImpact(id)` | `getById`, then `listWithCounts` if found | row with that id → `{containerCount, itemCount, photoCount: 0, qrBindingCount: 0}` (zeros if missing) | `:142-153` |
| `spaces.delete(id)` | `DELETE /v1/spaces/{id}` | 404 → `{deleted:false, orphanedPhotoUris:[]}`; else `{deleted:true, orphanedPhotoUris: body.orphanedPhotoUris ?? []}` | `:154-161` |
| `containers.listBySpace(spaceId)` | `GET /v1/containers?spaceId=<enc>` | `body.containers ?? []` | `:165-168` |
| `containers.getById(id)` / `getWithCounts(id)` | `GET /v1/containers/{id}` | 404 → `nil` (both return the with-counts body) | `:169-176` |
| `containers.create(input)` | `POST /v1/containers` `{spaceId, visualType, name}` | body | `:177-186` |
| `containers.update(id, input)` | `PATCH /v1/containers/{id}` `{name, visualType, spaceId}` (undefined keys omitted) | 404 → `nil` | `:187-197` |
| `containers.deletionImpact(id)` | `getWithCounts` | `{itemCount ?? 0, photoCount: 0, hasQrBinding: qrToken != nil}` | `:198-205` |
| `containers.delete(id)` | `DELETE /v1/containers/{id}` | as spaces | `:206-213` |
| `containers.listAllWithSpace()` | `GET /v1/containers` | `body.containers ?? []` | `:214-217` |
| `items.listByContainer(id)` | `GET /v1/items?containerId=<enc>` | thumbs hydrated | `:221-226` |
| `items.listUnsorted()` | `GET /v1/items?unsorted=1` | thumbs hydrated | `:227-232` |
| `items.listRecent(limit = 40)` | `GET /v1/items?recent=1&limit=<limit>` | thumbs hydrated | `:233-238` |
| `items.countUnsorted()` | via `listUnsorted()` | `.count` (also downloads thumbs — needless; native may skip hydration) | `:239-242` |
| `items.getById(id)` | `GET /v1/items/{id}` | 404 → `nil`; full + thumb hydrated | `:243-247` |
| `items.create(draft)` | optional `PUT /v1/photos/{newUUID}` (60 s) then `POST /v1/items` json `{containerId, name, category, quantity, notes, tags}` from the draft (undefined keys omitted, `null` kept) + `photo` when uploaded. The draft's own `photo.id/width/height/byteSize` are **never** sent | body (raw, **not hydrated** — `photoUri`/`photoThumbUri` are `r2:` strings); then caches the local photo files under the photo id | `:248-269` |
| `items.update(id, input)` | `PATCH /v1/items/{id}` `{containerId, name, category, quantity, notes, tags}` + `updatedAt: expectedUpdatedAt` when given. **`input.photo` is never sent** | 404 → `nil`; 409 → `ConflictError` | `:270-286` |
| `items.getPhotos(itemId)` | via `getById` (so it downloads full + thumb) | `[]` unless `photoId` and `photoUri`; else one `ItemPhoto {id: photoId, itemId, uri: photoUri, thumbUri: photoThumbUri, width/height/byteSize: nil, createdAt: item.createdAt}` where `uri`/`thumbUri` are the **hydrated** values (cache `file:` URLs, or the server's `r2:` string when a download failed) | `:287-302` |
| `items.delete(id)` | `DELETE /v1/items/{id}` | as spaces | `:303-310` |
| `items.countAll()` | `GET /v1/spaces` | sum of `itemCount` (**excludes drop-zone items**, unlike the local count) | `:311-315` |
| `qr.resolveScan(raw)` | `POST /v1/qr/scan` `{raw}` | body | `:319-321` |
| `qr.getByContainer(id)` | `GET /v1/containers/{id}` | `nil` if 404 or no `qrToken`; else `{id: container.id (!), token: qrToken, containerId, createdAt/updatedAt: container's}` | `:322-337` |
| `qr.getByToken()` | — | always `nil` (unsupported) | `:338-340` |
| `qr.bind(token, containerId)` | `POST /v1/qr/bind` | body | `:341-346` |
| `qr.createAndBind(containerId)` | `POST /v1/containers/{id}/qr` | body | `:347-349` |
| `qr.unbind(containerId)` | `DELETE /v1/containers/{id}/qr` | `true` on 204, `false` on 404 | `:350-355` |
| `search.search(q)` | `GET /v1/search?q=<enc>` | body with `items` thumb-hydrated (`[]` if not an array) | `:359-363` |
| `search.searchSpaces()` / `searchContainers()` | — | `[]` (locations come inside `search()`) | `:364-369` |

Item-create photo upload (`:59-85, 248-268`):

1. Read the local file bytes for `draft.photo.uri` (default reader:
   `services/capture/imageStore.readStoredPhoto`, `:374-377`); `nil` → throw
   `HouseholdHttpError(0, "photo_missing")`.
2. `PUT /v1/photos/<encoded newId()>` raw bytes, 60 s, via `householdRequest` (so non-2xx
   throws per §3.2, e.g. `503 photos_not_configured`). Response must have string `id` and
   `uri`, else `HouseholdHttpError(500, "invalid_response")`. `thumbUri` is kept only if it
   is a string, `width`/`height`/`byteSize` only if they are numbers; otherwise the key is
   omitted from the `photo` object (`:77-84`).
3. `POST /v1/items` with `photo: {id, uri, thumbUri?, width?, height?, byteSize?}`.
4. `photoId = created.photoId` (string) else the uploaded id; if present and the draft had a
   local uri → `rememberHouseholdPhoto(photoId, draft.photo.uri, draft.photo.thumbUri)` (§8).

Test `client.test.ts:70` pins the order: exactly `PUT …/v1/photos/<uuid>` then
`POST …/v1/items`, PUT body is raw bytes, POST body is a JSON string with a UUID
`photo.id`.

Returned `orphanedPhotoUris` from the server are `r2:` strings; callers pass them to the
local file deleter, which silently ignores non-files (`src/services/capture/imageStore.ts:188-198`).
Native: filter to `file:` URLs before deleting.

### 6.2 Photo hydration

- `hydrateItem` (detail; `:87-99`): no `photoId` → unchanged; `photoUri` already `file:` →
  unchanged; else resolve **full and thumb in parallel**; replace each with the cache URL,
  or keep the server value if resolution returned `nil`.
- `hydrateThumb` (lists and search; `:101-117`): no `photoId` → unchanged;
  `photoThumbUri` already `file:` → unchanged (`:109`); else only the thumb is resolved;
  `photoUri` left as the server sent it (`r2:` string). Rationale (`4fa33a6`): downloading every 1400 px photo
  made first loads slow.
- Lists hydrate all rows concurrently (`Promise.all`, `:119-121`). Native: a
  `withTaskGroup` with a modest concurrency cap is fine; better still, hydrate lazily per
  visible row (an `AsyncImage`-like view backed by the cache in §8).

---

## 7. Shadow copy (`withLocalShadow`)

`src/services/household/shadow.ts`. A decorator over the remote repositories. Reads, `db`
(`remote.db`, i.e. the throwing stub), `search`, `deletionImpact`, `getPhotos` etc. pass
straight through (object spread of each remote sub-repository, `:15, 17, 36, 56, 77, 98`). Each write calls the remote first; only on success it runs a
mirror step inside `shadow(work)`, which **swallows** any error and logs
`logEvent('household_shadow_failed', {errorClass})` (`:102-110`). The mirror is not wrapped
in a transaction; a multi-statement mirror can be partially applied.

| Write | Mirror | Source |
|---|---|---|
| `spaces.create` | `upsertSpace(result)` | `:18-22` |
| `spaces.update` | if result non-nil → `upsertSpace` | `:23-27` |
| `spaces.delete` | if `deleted` → `DELETE FROM spaces WHERE id = ?` (FK cascade locally) | `:28-33` |
| `containers.create` / `update` | `upsertContainer` (update only if non-nil) | `:37-46` |
| `containers.delete` | if `deleted` → `DELETE FROM containers WHERE id = ?` | `:47-53` |
| `items.create` | if result has a string `spaceId` (ItemWithContext — always true for the server) → `upsertItemGraph`; else `upsertItemRow` | `:57-64, 112-114` |
| `items.update` | if non-nil → `upsertItemRow` (server returns a bare `Item`; **tags are not mirrored on update**) | `:65-69` |
| `items.delete` | if `deleted` → `DELETE FROM items WHERE id = ?` | `:70-74` |
| `qr.bind` / `qr.createAndBind` | `upsertQr` | `:78-87` |
| `qr.unbind` | if `true` → `DELETE FROM qr_bindings WHERE container_id = ?` | `:88-96` |

Exact SQL (keep verbatim; GRDB `execute(sql:arguments:)`):

```sql
-- upsertSpace  (shadow.ts:116-127)  args: id, name, icon, color, createdAt, updatedAt
INSERT INTO spaces (id, name, icon, color, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name, icon = excluded.icon, color = excluded.color, updated_at = excluded.updated_at

-- upsertContainer  (shadow.ts:129-150)  args: id, spaceId, name, visualType, shortCode, createdAt, updatedAt
INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  space_id = excluded.space_id, name = excluded.name, visual_type = excluded.visual_type,
  short_code = excluded.short_code, updated_at = excluded.updated_at

-- upsertItemRow  (shadow.ts:152-178)
--   args: id, containerId, name, category, quantity, notes, createdAt, updatedAt, search_text
--   search_text = "\(name) \(category ?? "")".trimmed().lowercased()
INSERT INTO items (id, container_id, name, category, quantity, notes, created_at, updated_at, search_text)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  container_id = excluded.container_id, name = excluded.name, category = excluded.category,
  quantity = excluded.quantity, notes = excluded.notes, updated_at = excluded.updated_at,
  search_text = excluded.search_text

-- upsertQr  (shadow.ts:246-259)  args: (token, containerId) then (id, token, containerId, createdAt, updatedAt)
DELETE FROM qr_bindings WHERE token = ? OR container_id = ?;
INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
```

`upsertItemGraph(item)` (`shadow.ts:180-244`), in order:

1. `upsertSpace({id: spaceId, name: spaceName, icon: spaceIcon, color: spaceColor,
   createdAt: item.createdAt, updatedAt: item.updatedAt})` — note it stamps the space's
   `updated_at` with the item's timestamp.
2. `upsertContainer({id: containerId, spaceId, name: containerName, visualType: "box"
   (hard-coded), shortCode: containerShortCode || "CTR-" + first 4 chars of containerId uppercased,
   createdAt/updatedAt: item's})`.
3. `upsertItemRow(item)`.
4. If `photoId` and `photoUri`:
   ```sql
   INSERT INTO item_photos (id, item_id, uri, thumb_uri, width, height, byte_size, created_at, remote_synced_at)
   VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, ?)    -- photoId, item.id, photoUri, photoThumbUri, item.createdAt, now
   ON CONFLICT(id) DO UPDATE SET uri = excluded.uri, thumb_uri = excluded.thumb_uri,
                                 remote_synced_at = excluded.remote_synced_at
   ```
   `photoUri` here is the server's raw `r2:` string (create is not hydrated). Setting
   `remote_synced_at` keeps the phone-backup uploader from trying to upload it, and makes a
   later local delete write a `sync_deletions` tombstone via the trigger
   (`src/db/migrations.ts:167-180`).
5. Tags: `DELETE FROM item_tags WHERE item_id = ?`; for each tag: `name = trim`,
   `normalized = name.lowercased()`, skip empty; `SELECT id FROM tags WHERE normalized_name = ?`;
   if none, `INSERT INTO tags (id, name, normalized_name, created_at) VALUES (newId(), name, normalized, now)`;
   `INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)`.

Side effects of `upsertItemGraph` on rows that already exist locally (the `ON CONFLICT`
branches): the local space's `name/icon/color` are replaced by the server's and its
`updated_at` by the **item's** timestamp; the local container's `space_id`, `name`,
`short_code` are replaced, its `visual_type` is reset to **`box`** (even for the local
drop-zone container, seeded as `'other'` in `src/db/migrations.ts:135-141`) and its
`updated_at` set to the item's. `kind` is never written, so system rows stay `system` and new
rows get the column default `normal`. Reproduce exactly (parity) — do not "fix" by reading
the container first.

Failures to expect (all swallowed): FK failures when the parent container/space is not in
local SQLite (e.g. `items.update` moving into a container created on another phone; both DBs
run with `PRAGMA foreign_keys = ON`, `src/db/expoDatabase.ts:75`),
`UNIQUE` failures on `containers.short_code` when a different local container already has
that code.

Native: implement as a `ShadowingRepositories` decorator; run each mirror in one GRDB
`write {}` transaction (a harmless improvement — atomic instead of partial), and log the
same telemetry event on failure.

Semantics summary: while joined, local SQLite = what the phone had before joining +
this phone's own successful household writes. It is never read while joined. After
leaving, the phone shows this (possibly incomplete) copy. Note the copy mismatch:
`strings.household.leaveBody` says "What it saw while joined stays on this phone", but
reads are never mirrored — only this phone's own writes are (Open question Q15). Photos
mirrored this way have `r2:` URIs and will show the placeholder in local mode (Open
question Q3).

---

## 8. Photo cache

`src/services/household/photoCache.ts`:

- Directory: `<Caches>/household-photos/` (expo-file-system `Paths.cache` = iOS
  `Library/Caches`), created with intermediates on demand (`:18-20, 50-52`).
- File names: full `<photoId>.webp`, thumb `<photoId>-thumb.webp` regardless of the actual
  content type (`:21-22`).
- `resolveHouseholdPhoto({session, photoId, kind})` (`:11-41`):
  1. If the file exists → return its URL (no network, no validation, no TTL).
  2. `GET /v1/photos/<enc photoId>` + `?thumb=1` for thumbs, with the token and the default
     20 s timeout, via `householdFetch` (so it reports reachability).
  3. Non-2xx → `nil`. Else write bytes (delete-then-create) and return the URL.
  4. Any thrown error (offline, timeout, file I/O) → `nil`.
- `rememberHouseholdPhoto(photoId, sourceUri, thumbUri?)` (`:44-69`): after a local capture
  was uploaded, copy the local full (and thumb, if given) file into the cache under the
  server photo id, replacing any existing file; source missing → skip; errors ignored.
- No eviction. Correct because a photo id always names the same bytes (server sends
  `immutable`); the OS may purge Caches.

Native:
- Keep the same directory and names (free reuse of the RN cache, though not required).
- Write atomically (`Data.write(to:options: .atomic)`) — the JS version can leave a
  zero-byte file if a write fails mid-way, and would then serve it forever.
- Coalesce concurrent requests for the same `(photoId, kind)` (an actor with a
  `[Key: Task<URL?, Never>]` map); the JS code can download the same file twice.
- `URLCache` is not a substitute: responses are `private`, behind a bearer token, and we
  need file URLs for the full-screen viewer.

---

## 9. Connection state machine

### 9.1 States

`src/providers/ConnectionProvider.tsx:20-27`:

| State | Meaning |
|---|---|
| `local` | No session; nothing to reach. |
| `online` | The last request got an answer from the home server. |
| `unsure` | A request failed less than 2.5 s ago (probably a blip). |
| `offline` | Requests have been failing for ≥ 2.5 s. |
| `revoked` | A token-carrying request got 401 (this phone was removed elsewhere). Sticky until the session changes. |

Constants: `delay.reconnect = 2500` ms (`src/ui/motion.ts:30`), `HEALTH_PING_MS = 10000`,
`HEALTH_TIMEOUT_MS = 5000`, `RESUME_REFRESH_MS = 5000` (`ConnectionProvider.tsx:40-43`).

### 9.2 Transitions

State is tracked per session key `"\(origin)|\(token)"` (`:60`). A new key (join, rejoin,
leave) resets to `online` (`:63-72`). With no session the exposed state is `local` (`:74`).

On each reachability report (`:102-128`), with `current` = the state as last set by this
subscription (not the rendered one — two reports can arrive before a re-render, `:85-87`):

```
set(next): if current == revoked or current == next → ignore; else current = next, publish.

unauthorized → cancel offline timer; set(revoked)
ok           → cancel offline timer
               recovering = (current != online)
               set(online)
               if recovering && current == online && now - lastRecovery >= 5000 ms:
                   lastRecovery = now; invalidate()      // re-read every list on screen
offline      → if current != online OR a timer is pending → ignore
               else set(unsure); start timer 2500 ms → (timer = nil; set(offline))
```

Notes:
- In `unsure` or `offline`, further `offline` reports change nothing.
- `unsure → online` also triggers the recovery `invalidate()` (subject to the 5 s guard).
- Once `revoked`, nothing changes it except a new session (`set` ignores everything).
- Every time a session starts, `markJoinedBefore()` runs (`:83`; §11.1).
- `current` is seeded from the rendered state when the subscription is (re)created, and
  `lastRecovery` starts at `0`, so the first recovery of a session always invalidates
  (`:87-89`).
- The reachability bus is global and untagged: a report from a request made with an
  **old** token (e.g. a slow request still in flight across leave → rejoin) is applied to
  the new session's state machine, and a late 401 from it would mark the new session
  `revoked`. Native improvement (harmless): tag each report with the token that made the
  request and ignore reports whose token differs from the current session's.

### 9.3 Refresh triggers (no live updates)

| Trigger | Action | Source |
|---|---|---|
| Recovery (`ok` after any failure) | `invalidate()` at most every 5 s | `ConnectionProvider.tsx:108-121` |
| App becomes active (`AppState` → `active`) with a session | `invalidate()` if ≥ 5 s since the last time; the very first time the guard passes (app start, or the first join of an app that started unpaired) does not invalidate. On iOS RN reports `inactive` for Control Center / notification shade / system alerts, so `inactive → active` counts too — same as `scenePhase` `.inactive → .active`. The effect also re-runs when the session key changes (join/rejoin), invalidating if ≥ 5 s since the last run | `:144-158` |
| `retry()` (banner "Try again") | health ping + `invalidate()` | `:175-178` |
| Screen focus / revision bump | each query re-reads (`useInventoryQuery`; only the focused screen re-reads on revision) | `src/hooks/useInventoryQuery.ts:28-51, 108-115` |
| After any write | the screen calls `invalidate()` | throughout |

`invalidate()` bumps the global revision (`src/providers/DatabaseProvider.tsx:68`). Native:
an `@Observable` `revision: Int` that list view models observe, plus re-loading in
`.task(id:)` / `onAppear`. `AppState` → `@Environment(\.scenePhase)`.

### 9.4 Health ping

While `offline` **and** the app is active, every 10 s: `GET /v1/health` without a token,
5 s timeout; the result is ignored — the request reports reachability itself
(`:136-142, 169-173`). It is a repeating interval (first ping 10 s after going offline,
not immediately). No other polling exists. Native: a `Task` loop with
`try await Task.sleep(for: .seconds(10))`, cancelled when leaving `offline` or going to
background.

### 9.5 Accessibility announcement

When the state becomes `offline`, announce `strings.connection.reconnecting` once
(`:165-167`). The banners themselves are silent (each screen draws its own).
Native: `AccessibilityNotification.Announcement(...).post()`.

### 9.6 Where the state is shown

- **Connection banner** (`src/ui/components/ConnectionBanner.tsx:25-41`): only when
  `offline`; warning tone, cloud-off icon, message `strings.connection.reconnecting`,
  action `strings.connection.retry` → `retry()`; not a live region; test id
  `banner-connection`. Rendered at the top of every screen frame except camera screens,
  outside the scroll view (`src/ui/components/ScreenFrame.tsx:49, 60`). Native: a
  `safeAreaInset(edge: .top)` or a toolbar-area view on every non-camera screen.
- **Removed-phone layer** (`ConnectionBanner.tsx:49-120`), shown when `revoked`, above
  every screen and sheet (`src/ui/components/Toast.tsx:233-252`, iOS uses a
  `FullWindowOverlay`, accessibility-modal only while revoked):
  - On appear: dismiss every presented sheet (`router.dismissAll()`), on iOS announce
    `strings.revoked.title`, block Android back (`:61-68`).
  - Content: app mark, `strings.revoked.title`, `strings.revoked.body`, primary button
    `strings.revoked.join` (test id `revoked-join`), quiet button `strings.revoked.local`
    (test id `revoked-local`) (`:83-119`).
  - "Join again": `disconnect()`, `invalidate()`, push `/household` (`:72-76`).
  - "Use this phone on its own": `disconnect()`, `invalidate()` (`:78-81`).
  - The layer disappears by itself once the session is gone (state becomes `local`).
  - It does **not** call `DELETE /v1/devices` (the token is already dead).
  - Native: render it in the shared pass-through overlay `UIWindow` that also hosts toasts
    (`09-app-shell-lifecycle-config.md` §7.6-7.7, `06-screens-shell-home.md` §2.2), so it
    covers sheets immediately; capture all touches and set `accessibilityViewIsModal` while
    revoked, and also dismiss presented sheets / pop to the tab root as RN does. (A
    root-level `.fullScreenCover` cannot appear above an already-presented sheet, which is
    why the shell spec chose the window.)
- While `revoked`, other screens relax their guards so the layer can close sheets without
  prompts: dirty-form discard guard off (`src/hooks/useDirtyGuard.ts:32-34`), Add sheet's
  back-to-form interception off (`app/item/new.tsx:330-331`), Scan tab knows it is covered
  (`app/(tabs)/scan.tsx:162`).
- **Household screen status card**: "Connected" only when `online`; any other state
  (including `unsure`) shows `strings.connection.reconnectingShort` in the signal tone
  (`app/household.tsx:305-335`).
- **Home header caption**: `strings.connection.sharedReconnecting` when paired and
  `offline`, `strings.connection.shared` when paired, `strings.connection.local` when not
  (`app/(tabs)/index.tsx:407-446`). Home also swaps its list for
  `strings.home.waitingForServer` when the failure is "explained elsewhere" — revoked, or
  offline while the state is not `online` (`app/(tabs)/index.tsx:75-78, 470-480`). (Home is
  owned by the Home spec.)

---

## 10. Offline behavior summary

- Reads while offline throw `HouseholdHttpError(0, "offline"|"timeout")` (or 502/52x).
  `useInventoryQuery` keeps the last data for the same key and flags `refreshFailed`
  (`src/hooks/useInventoryQuery.ts:45-50, 91-99`). There is **no persistent cache of
  household lists**: a cold start while offline shows empty/error states (plus the
  banner after 2.5 s).
- Writes while offline fail; screens show the "not saved" wording
  (`strings.errors.offline.save`) and keep the form. No outbox, no retry queue.
- Photos already in the cache keep displaying; others show placeholders.
- `describeError` mapping for household errors (`src/ui/errors.ts:16-24, 41-82`):
  unreachable (`code` `offline`/`timeout`/`http_502`, or status/`http_NNN` of 502 or
  520–530) → `offline`; 401 or `code == "unauthorized"` outside join → `revoked`;
  404 / `not_found` → `gone`; `photo_missing` → `photo`; any other `HouseholdHttpError` →
  `server`; `ConflictError` → `conflict`; `null` result → `gone`; anything else → `local`.
  `needsRefreshBanner` suppresses the refresh banner for `offline` and `revoked`
  (`src/ui/errors.ts:90-94`). (Owned by the error-handling spec; listed because this area
  produces the inputs.)

---

## 11. Copying a phone's own inventory into the household

### 11.1 The offer (`src/services/household/importOffer.ts`)

AsyncStorage keys: `household.importOffer.v1` (JSON `{"spaces":Int,"items":Int}`) and
`household.joinedBefore.v1` (`"true"`) (`:5-6`).

- `snapshotBeforeJoin(localRepos)` (`:24-42`), called just **before** pairing:
  - If `joinedBefore == "true"` → return (no new offer, existing value untouched).
  - `spaces = local.spaces.listWithCounts().count` (excludes the system drop-zone space),
    `items = local.items.countAll()` (all items, drop zone included).
  - Both zero → remove the offer key; else store `{"spaces":spaces,"items":items}`.
  - Any error swallowed ("no offer is the safe failure").
  - Rationale: once joined, every household write is mirrored into the same local DB, so
    counting afterwards would offer to copy shadow copies back (`:14-23`).
- `markJoinedBefore()` (`:45-51`): set `"true"`; called after a successful pair
  (`src/ui/household/JoinForm.tsx:119`) **and** on every start with a session
  (`ConnectionProvider.tsx:83`) so phones paired before this feature count too. Errors
  swallowed.
- `readImportOffer()` (`:53-72`): parse; valid only if both fields are numbers; else `nil`.
- `clearImportOffer()` (`:75-81`): remove; errors swallowed. Called after a successful
  copy, on "Not needed", and on Leave.
- Net effect: the offer is **created** at most once per install (only before the first
  successful join; leaving and rejoining never re-create it). Once created it is **shown**
  every time the Paired Household view mounts (it is read once per mount, §12.5), across
  launches, until a copy succeeds, the person taps "Not needed", or the phone leaves.
  If the local DB is not ready at join time the snapshot is skipped (§12.3 step 4) and,
  because `joinedBefore` is then set, no offer is ever made.
- Edge: the offer is written before pairing; if pairing then fails, the key stays (harmless —
  it is only read in the Paired view) and the next join attempt recomputes it.

### 11.2 Collecting the dump (`src/services/household/collectDump.ts`)

Reads **all rows** of seven local tables, no filters, no ordering (`:15-139`), mapping
snake_case to camelCase. The dump includes the system drop-zone rows
(`src/services/household/__tests__/import.test.ts:7`) and any shadow rows.

```sql
SELECT id, name, icon, color, kind, created_at, updated_at FROM spaces
SELECT id, space_id, name, visual_type, short_code, kind, created_at, updated_at FROM containers
SELECT id, container_id, name, category, quantity, notes, search_text, created_at, updated_at FROM items
SELECT id, name, normalized_name, created_at FROM tags
SELECT item_id, tag_id FROM item_tags
SELECT id, token, container_id, created_at, updated_at FROM qr_bindings
SELECT id, item_id, uri, width, height, byte_size, created_at FROM item_photos   -- uri NOT included in the dump
```

`localPhotoUris(db)`: `SELECT id, uri FROM item_photos` → `[id: uri]` (`:141-144`).

Dump JSON (`src/services/household/dump.ts:7-77`):

```text
HouseholdDump { spaces: [DumpSpace], containers: [DumpContainer], items: [DumpItem], tags: [DumpTag],
                itemTags: [DumpItemTag], qrBindings: [DumpQrBinding], photos: [DumpPhoto] }
DumpSpace      { id, name, icon, color, kind, createdAt, updatedAt }
DumpContainer  { id, spaceId, name: String?, visualType, shortCode, kind, createdAt, updatedAt }
DumpItem       { id, containerId, name, category: String?, quantity, notes: String?, searchText, createdAt, updatedAt }
DumpTag        { id, name, normalizedName, createdAt }
DumpItemTag    { itemId, tagId }
DumpQrBinding  { id, token, containerId, createdAt, updatedAt }
DumpPhoto      { id, itemId, width: Int?, height: Int?, byteSize: Int?, createdAt }
```

Here nullable fields are sent as explicit JSON `null` (not omitted).

### 11.3 Running the import (`src/services/household/importHousehold.ts:20-82`)

1. `dump = collectHouseholdDump(localDB)`; `uris = localPhotoUris(localDB)`.
2. `POST /v1/import` with the dump, 60 s timeout (`:31-39`). Errors propagate (whole import fails).
3. Optional fallback source for missing photo files, built **after** the POST succeeded:
   if a phone-backup account exists in the keychain, `createSyncClient({recoveryCode}).downloadPhoto(photoId)`
   from the inventory-sync Worker (the backup photo store, not the household one); any
   failure building it → no fallback (`:84-94`). Neither source throws in practice:
   `readStoredPhoto` returns `nil` on any error (`src/services/capture/imageStore.ts:137-145`)
   and `downloadPhoto` returns a `{status:"failed"}` result instead of throwing
   (`src/services/sync/client.ts:97-107`), so only household transport errors abort.
4. For each `dump.photos` entry, **sequentially** (`:46-72`):
   - `bytes = readPhoto(uris[id])` if a uri exists; if `nil` and the sync client exists and
     `downloadPhoto` succeeds, use those bytes.
   - Still `nil` → `photosMissing += 1`, continue.
   - `PUT /v1/photos/<enc id>` raw bytes, 60 s, via `householdFetch` (raw response):
     non-2xx → `photosMissing += 1`; else `photosUploaded += 1`.
   - A thrown transport error (offline/timeout) **aborts the whole import** (propagates).
5. `logEvent('household_imported', {itemCount: dump.items.count})`.
6. Return `{items: body.items as number ?? dump.items.count, photos: dump.photos.count,
   photosUploaded, photosMissing}` (`:76-81`).

Re-running is safe: the server upserts by id, and photo PUTs overwrite the same keys.

### 11.4 Server side (`home-server/src/importer.ts:15-183`)

One transaction (`:16`), in this order: spaces, containers, items, tags, item_tags,
qr_bindings, item_photos. Rows whose id (or parent id) fails `/^[\w.-]{1,80}$/` are
skipped (`:5-9`). **Never `REPLACE`** — it would cascade-delete children (K16). Defaults
applied: space `name ''`, `icon 'cube'`, `color '#5B8DEF'`, `kind 'normal'`; container
`visualType 'box'`, `shortCode = id`, `kind 'normal'`; item `name ''`, quantity must be an
integer ≥ 0 else `1`, `searchText` falls back to `"name category".trim().lower()`; tag
`normalizedName` falls back to `name.lower()`; timestamps `Number(x) || 0`. Each table uses
`INSERT … ON CONFLICT(id) DO UPDATE` on all non-id columns except `created_at`;
`item_tags` uses `INSERT OR IGNORE`; photo rows get
`uri = "r2:household/primary/photos/<id>.webp"`, `thumb_uri = "r2:…/<id>-thumb.webp"`,
`remote_synced_at = now` (`:151-181`).

Known server-side failure mode: `ON CONFLICT(id)` does not cover the other UNIQUE
constraints (`containers.short_code`, `tags.normalized_name`, `qr_bindings.token`,
`src/db/migrations.ts:43, 78, 91`). If the household already has, say, a tag named
"power" under a different id, the whole import fails with `400 {"error":"UNIQUE constraint failed: …"}`
(surfaced in the app as the generic server error). The household DB also runs with
`PRAGMA foreign_keys = ON` (`src/db/nodeDatabase.ts:24`), so a dump row whose parent was
skipped by the id filter (or a `qr_bindings` row skipped because `token` is not a string,
`importer.ts:133`) makes its children fail the FK check and the whole import fails the same
way. The phone's own `drop-zone-space` / `drop-zone` rows (always in the dump) overwrite the
household's seeded ones by id, including `kind` (both `'system'`). See Open question Q2.

`PUT /v1/photos/:id` keeps the phone's photo id (`home-server/src/photos.ts:36-41`), so the
imported `item_photos` rows line up with the uploaded bytes
(`home-server/test/import.test.ts:50`).

---

## 12. UI

Navigation: `household` is a stack screen titled `strings.household.screenTitle`
(`app/_layout.tsx:168`), reachable from Settings' Household row
(`app/settings.tsx:54-62`), Home's unpaired notice and unpaired empty state
(`app/(tabs)/index.tsx:529, 590`), Spaces' empty state when not joined
(`app/(tabs)/spaces.tsx:143-147`), and the removed-phone layer. Onboarding embeds the same
join form (`app/onboarding.tsx:87-118`; owned by the Onboarding spec).

### 12.1 Household screen — dispatch

`app/household.tsx:48-51`: no session → **Unpaired** view; session → **Paired** view. The
view swaps live when the session changes — on join this happens inside `household.pair()`,
before `onJoined` runs (the join form unmounts mid-`join()`; its remaining steps and the
Unpaired view's `joined` callback still run from their closures). On leave the swap to the
Unpaired join form happens at `disconnect()`, just before `leaveScreen` pops it.

`leaveScreen` (`app/household.tsx:58-65`): only if this screen is still focused (a slow
join/leave finishing after the person navigated away must not pop another screen): go
back if possible, else switch to the Home tab.

### 12.2 Unpaired view — join

`app/household.tsx:67-97` renders the join form with a header:
`strings.household.joinHeading` (heading) and `strings.household.joinBody` (secondary).

On joined (`:74-80`): toast `strings.household.joined(householdName)`; if there is **no**
import offer → `leaveScreen`; if there **is** one, stay (the view becomes Paired and shows
the offer).

### 12.3 Join form (`src/ui/household/JoinForm.tsx`)

Fields, top to bottom (`:145-215`):

1. Optional failure banner (warning, assertive live region): `strings.join.offline` or
   `strings.join.other` (`:159-165`).
2. Code field (`CodeInput`, test id `join-code`): label `strings.join.codeLabel`, hint
   `strings.join.codeHint`, length 26; error under the field.
3. Name field (test id `join-name`): label `strings.join.nameLabel`, placeholder
   `strings.join.namePlaceholder`, hint `strings.join.nameHint`, required, words
   capitalization, no autocorrect, return key "go" submits.
4. Caption `strings.household.server(serverHost(appConfig.householdOrigin))` (`:198-202`).
5. Bottom bar button (test id `join-submit`): `strings.join.submit`, or `strings.join.busy`
   with a spinner while joining (`:204-212`).

Initial state: code from `initialDraft` or empty; name from `initialDraft` or
`suggestedPhoneName(Constants.deviceName)` (`:91-94`). `onDraftChange` is called on every
edit (used by onboarding to survive Back).

Editing the code clears the code error **and** the failure banner; editing the name clears
only the name error (`:171-176, 185-189`).

Submit (`join()`, `:102-143`):

1. Re-entrancy guard (a ref, because the button and the return key can fire in one frame;
   pairing twice would register the phone twice).
2. `validateJoin(code, name)` (§13); show errors; clear the failure banner; if any error →
   error haptic, stop.
3. Busy on.
4. If the local DB is ready → `snapshotBeforeJoin(localRepos)` (the **raw local**
   repositories, never the shadowed ones).
5. `household.pair(code, name.trim())` (code is already normalised).
6. `markJoinedBefore()`.
7. Read back the saved session and the import offer in parallel.
8. `invalidate()`, success haptic, `onJoined({householdName: session?.householdName ?? "Home",
   hasImportOffer: offer != nil})` (fallback constant `FALLBACK_HOUSEHOLD_NAME = "Home"`, `:36`).
9. On error: `kind = joinFailure(error)`; telemetry
   `logError('household_join_failed', {outcome: kind, statusCode: status or null, errorClass})`;
   `refused` → code-field error `strings.join.refused`; otherwise failure banner
   (`offline`/`other`); error haptic. Fields keep what was typed.
10. Busy off.

Native notes: `KeyboardAvoidingView`/`keyboardVerticalOffset` (`:146-151`) is unnecessary —
SwiftUI handles the keyboard; put the button in a `safeAreaInset(edge: .bottom)`.
`Constants.deviceName` ≙ `UIDevice.current.name`, which returns the generic "iPhone" on
iOS 16+ without the `com.apple.developer.device-information.user-assigned-device-name`
entitlement — `suggestedPhoneName` already turns that into an empty field.

### 12.4 Code input normalisation (`src/ui/code.ts`, `src/ui/components/CodeInput.tsx`)

- Every change is normalised (`code.ts:14-20`): remove all whitespace and hyphens
  (`/[\s-]+/g`), uppercase, `I`/`L` → `1`, `O` → `0`. The stored value is the normalised
  string; it is **displayed** formatted in groups of 5 joined by `-` (`code.ts:28-30`,
  `CodeInput.tsx:50-51`).
- `invalidCodeChars` = distinct chars not matching `/^[0-9A-HJKMNP-TV-Z]$/`, in first-seen
  order (`code.ts:11, 23-25`).
- Counter `strings.forms.codeCounter(count, 26)` on the label row only when non-empty; read
  on blur, not live (`CodeInput.tsx:42, 49, 54`).
- Code text style, multiline that wraps at hyphens, no scrolling, return = done/blur,
  autocapitalize characters, no autocorrect/spellcheck/autofill, trailing lock icon
  (`CodeInput.tsx:57-68`).
- Native: a `TextField` with `.textInputAutocapitalization(.characters)`,
  `.autocorrectionDisabled()`, `.textContentType(nil)`, monospaced/legible font, and an
  `onChange` that normalises; display via a formatted binding.

### 12.5 Paired view (`app/household.tsx:99-302`)

Layout (scrollable, pull-to-refresh reloads the phone list, `:108, 235-240`):

1. **Status card** (`:305-335`): phone icon + heading `strings.household.thisPhoneIs(deviceName)`;
   `strings.household.partOf(householdName)`; a dot + word grouped as one accessibility
   element (not a live region): `strings.connection.connected` when state is `online`,
   else `strings.connection.reconnectingShort` (signal tone).
2. **Import offer** (only if `readImportOffer()` returned a value at mount, `:110-119, 243-268`):
   info banner `strings.household.importNotice(spaces, items)`; action
   `strings.household.importAction` (test id `household-import`, spinner while importing,
   label unchanged); secondary `strings.household.notNeeded` (hidden while importing).
   Under it, on failure, a warning notice (title + body) from `describeError(cause, "read")` (read wording
   on purpose: "Nothing on this phone was lost"), not dismissible, assertive live region
   (`FailureNotice`, `app/household.tsx:338-363`). It clears when the next copy starts.
3. **Section** `strings.household.phones` containing an optional dismissible remove-failure
   notice and the phone list (`:270-287`).
4. **Leave** destructive button `strings.household.leave` (test id `household-leave`,
   spinner while leaving) (`:289-298`).

One shared re-entrancy guard covers copy-in, remove and leave (confirms are async; a second
tap must not start a second write) (`:126-127`).

**Copy in** (`copyIn`, `:129-164`): requires the local DB ready. Confirm
(`strings.household.importConfirmTitle`, `importConfirmBody`, button `importConfirm`,
**not** destructive). Then `importLocalInventory({session, db: localDB})` →
`clearImportOffer()` → hide offer → `invalidate()` → success haptic → toast
`strings.household.copied(result.items, result.photosUploaded)`. On error: telemetry
`logError('household_import_failed', {errorClass})`, show the failure notice, error haptic;
the offer stays (retry is safe).

**Not needed** (`:166-169`): `clearImportOffer()` and hide.

**Remove a phone** (`remove`, `:171-201`): confirm
(`strings.household.removeTitle(name)`, `removeBody`, button `removeConfirm`, destructive).
Row shows a spinner; `revokeDevice(session, id)` (404 counts as success, §12.7) →
`logEvent('device_removed')` → reload the list → toast `strings.household.removed(name)`.
On error: telemetry `logError('household_remove_failed', {statusCode, errorClass})`; show a
dismissible warning notice (assertive live region) at the top of the Phones section:
title/body from `describeError(cause, "delete")` (`delete` uses the *save* bodies), but the
body is `strings.household.removeOffline(name)` when the kind is `offline`
(`:272-279, 338-363`); error haptic. The notice clears when the next removal starts.
Removing does not call `invalidate()`; only the phone list reloads.

**Leave** (`leave`, `:203-231`): confirm (`strings.household.leaveTitle`, `leaveBody`,
button `leaveConfirm`, destructive). Then, in this order:
1. `disconnect()` **first** — so any in-flight request that comes back 401 after the token
   is dropped cannot flash the removed-phone layer (`:216-219`).
2. Fire-and-forget `revokeDevice(session, session.deviceId, timeout 5 s)`, errors ignored
   (`:220-225`). Leaving works instantly offline; the server list may keep a stale entry.
3. `clearImportOffer()`; `logEvent('household_left')`; `invalidate()`; `leaveScreen`; toast
   `strings.household.left`.

Local SQLite (including shadow rows) and the photo cache are **not** cleared.

### 12.6 Phone list states (`app/household.tsx:377-479`)

Query: `listDevices(session)` keyed `devices:<deviceId>`, re-read on focus, on revision bump
and on pull-to-refresh (`:107`). `now` refreshes every 60 s while focused
(`src/hooks/useNow.ts:11-28`).

| Condition | Render |
|---|---|
| No data, error, kind `offline`, connection ≠ `online` | plain secondary text `strings.household.phonesOffline` (the banner already offers Try again) |
| No data, any other error | warning banner with `describeError(cause,"read")` title/body + action `strings.common.tryAgain` → reload |
| No data, loading | 2-row skeleton, no thumbnails |
| No data, not loading, no error | nothing |
| Data | optional info banner `strings.errors.refreshFailed` + `strings.common.tryAgain` when the last refresh failed and was not `offline`; then the rows |

Rows: `sortDevices(devices, myId)` (this phone first, then server order = join order).
Each row: phone icon, name, meta line `deviceMeta(device, myId, now)`; accessibility label
`strings.household.phoneA11y(name, meta)`; for **other** phones a small destructive button
`strings.household.remove` with accessibility label `strings.household.removeA11y(name)`
and test id `device-remove-<id>`, spinner while that id is being removed. This phone has no
remove button (it leaves instead).

### 12.7 Devices client (`src/services/household/devices.ts`)

- `listDevices` (`:40-52`): `GET /v1/devices` with the default 20 s timeout (it accepts a
  `timeoutMs` option but does not forward it); `body.devices` not an array →
  `HouseholdHttpError(500, "invalid_response")`; entries that are not objects or lack
  string `id`/`name` are **skipped**; `createdAt = Number(x)` or `0` if not finite;
  `lastSeenAt = null` if JSON null, missing or non-finite, else number (`:18-30`). JS
  `Number()` also accepts numeric strings (`"5"` → 5) and booleans (`true` → 1); a Swift
  port that only accepts JSON numbers differs only for malformed servers.
- `revokeDevice` (`:61-79`): `DELETE /v1/devices/<encodeURIComponent(id)>`, optional
  timeout; a `HouseholdHttpError` with status 404 resolves (already gone); anything else
  rethrows.

### 12.8 Home's unpaired notice (`src/ui/home/unpairedNotice.ts`)

- AsyncStorage key `notice.unpaired.dismissed.v1`, value `"1"` when dismissed (`:4`).
- `dismissed` starts `nil` (unknown); storage answer sets it to `stored == "1"`, a storage
  error sets `false` — but neither overrides a value already set by a tap (`:19-32`).
- `dismiss()` sets `true` immediately and persists `"1"`; a write failure only means the
  notice returns next launch (`:34-39`).
- `visible = !paired && dismissed == false` (hidden until storage answered, so it never
  flashes) (`:41`).
- Rendered by Home as an info banner with title `strings.home.unpaired.title`, body
  `strings.home.unpaired.body`, action `strings.home.unpaired.join` (test id
  `unpaired-join`, pushes `/household`), secondary `strings.common.notNow` with
  accessibility hint `strings.home.unpaired.notNowHint`; suppressed when the unpaired empty
  state already offers joining (`app/(tabs)/index.tsx:386-387, 579-597`).

### 12.9 Other paired/unpaired copy elsewhere (owned by other specs)

Settings row value `strings.settings.joinedAs(deviceName)` / `strings.settings.thisPhoneOnly`
and "Home server address" `serverHost(session?.origin ?? appConfig.householdOrigin)`
(`app/settings.tsx:43-47`); backup row visibility `showBackupRow` (§13.2);
`strings.backup.pairedNote` on Backup when joined (`app/backup.tsx:71`); privacy copy
variants (`app/privacy.tsx:40-95`); delete-confirm bodies `*.deleteBodyPaired`
(`app/item/[id]/index.tsx:227`, `app/capture/review.tsx:150`); camera rationale
`strings.permissions.captureBodyPaired` (`src/ui/components/CameraPermission.tsx:91-92`);
Home title = `session.householdName.trim()` or `strings.home.title`
(`app/(tabs)/index.tsx:172`).

---

## 13. Pure logic to port verbatim

### 13.1 `src/ui/household/join.ts`

- `CODE_LENGTH = 26` (`:12`).
- `codeProblem(normalised, length = 26)` (`:22-27`): invalid chars first →
  `.chars(joined by " ")`; else length ≠ 26 → `.length(count)`; else `nil`.
- `validateJoin(normalisedCode, name)` (`:40-50`): code `""` → `strings.join.codeRequired`;
  chars → `strings.join.badChars(chars)`; length → `strings.join.wrongLength(count)`;
  `name.trim() == ""` → `strings.join.nameRequired`. Returns `{code?, name?}`.
- `suggestedPhoneName(deviceName?)` (`:53-63`): trim; if lowercase is in
  `{"iphone","ipad","android"}` → `""`; else the trimmed name; `nil` → `""`.
- `joinFailure(error)` (`:73-81`): `HouseholdHttpError` with status 401 **or** code
  `"unauthorized"` → `refused`; else `describeError(error, "join").kind == offline` →
  `offline`; else `other`.
- `serverHost(origin)` (`:84-90`): trim, strip a leading `scheme://`
  (`/^[a-z][a-z0-9+.-]*:\/\//i`), cut at the first `/`, `?` or `#`; empty → return
  `origin` unchanged.

### 13.2 `src/ui/household/status.ts`

- `deviceMeta(device, myId, now)` (`:78-82`): mine → `strings.household.thisPhone`;
  `lastSeenAt == nil` → `strings.household.neverUsed` (unreachable with the current server,
  which stamps `last_seen_at` at pairing, §2.3); else
  `strings.household.lastUsed(ago(lastSeenAt, now))` (`ago` from `src/i18n/format.ts:34-44`:
  `<1 min` "just now", minutes, hours, `<2 days` "yesterday", days `<30`, months
  (`floor(days/30)`) `<365`, years (`floor(days/365)`); plural "s" unless the count is 1;
  a future time (clock skew) reads "just now").
- `sortDevices(devices, myId)` (`:85-92`): stable partition, mine first.
- Also in this file but owned by the Backup spec: `backupSummary`, `showBackupRow(paired,
  status)` (joined phones see the backup row only when state ∉ {`off`,`unavailable`},
  `:45-48`), `backupReason`.

---

## 14. On-device state this area owns (Expo build → native, first launch)

| Store | Key / path | Format | Native |
|---|---|---|---|
| Keychain | account `household.session.v1` (service `app:no-auth`) | JSON session (§5) | Read and write through `ExpoCompatibleKeychain` (`02-device-storage-migration.md` §4.3) |
| AsyncStorage | `household.importOffer.v1` | `{"spaces":n,"items":n}` | Migrate to `UserDefaults` (same key) |
| AsyncStorage | `household.joinedBefore.v1` | `"true"` | Migrate to `UserDefaults` |
| AsyncStorage | `notice.unpaired.dismissed.v1` | `"1"` | Migrate to `UserDefaults` |
| Files | `Library/Caches/household-photos/<id>.webp`, `<id>-thumb.webp` | image bytes | Optional reuse (cache) |
| SQLite | shadow rows inside the app's inventory DB | app schema | Nothing special; owned by the DB spec |

Store the migrated values as the **same strings** (`"true"`, `"1"`, the JSON text), so the
read rules above (`=== "true"`, `=== "1"`, JSON with numeric `spaces`/`items`) port
unchanged. A TestFlight rollback to the RN build would not see values written only to
`UserDefaults` (the unpaired notice would reappear; `joinedBefore` is re-set on the next
start with a session), so either also keep the legacy manifest untouched or accept that.

AsyncStorage location in this build: the default export of
`@react-native-async-storage/async-storage` 3.1.1 is the **legacy v2** store
(`node_modules/@react-native-async-storage/async-storage/src/index.tsx:8-9`):
`Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json`,
a JSON object of key → string; values longer than 1024 chars live in a sibling file named
MD5(key) with a `null` manifest entry (`apple/legacy_storage/RNCAsyncStorage.mm:17, 20-21,
130-150, 509, 633`). All three keys above are tiny (inline). The importer for this file is
owned by `02-device-storage-migration.md` §5.4 (Q8 resolved); it copies these keys
verbatim and leaves the legacy directory untouched, which also covers the rollback case
above.

---

## 15. RN/Expo workarounds that disappear natively

| JS workaround | Why it existed | Native replacement |
|---|---|---|
| Photo upload as raw octets + byte copy (`httpRepositories.ts:54-58`, `client.ts:158-159`) | RN cannot build a Blob from an ArrayBuffer view; FormData `{uri,name,type}` failed under fetch | `URLSession.upload(for:from: Data)`; keep the two-step PUT+POST (it lets the client choose the photo id); the server's multipart `POST /v1/items` stays unused |
| Lazy `import('expo-file-system')` / `import('@/services/capture/imageStore')` / sync client (`photoCache.ts:8-9`, `httpRepositories.ts:374-377`, `importHousehold.ts:28-29, 84-94`) | Keep Node Jest tests free of RN | Plain dependency injection |
| `fetchImpl` / `readPhoto` parameters | Test seams | Inject `URLSession`/`URLProtocol` stub and a photo-reader closure |
| Global listener `Set` for reachability | No DI container in RN | An injected `ConnectionMonitor` |
| `busyRef` + `busy` state pairs | Same-frame double events in RN | `@MainActor` flag checked synchronously before `await` |
| `KeyboardAvoidingView` offset juggling (`JoinForm.tsx:56-61, 146-151`) | RN keyboard handling | SwiftUI default keyboard avoidance |
| `FullWindowOverlay` + `dismissAll()` for the removed-phone layer (`Toast.tsx:226-252`) | Overlays under native modal sheets | Dismiss sheets + root `.fullScreenCover`, or a dedicated overlay `UIWindow` |
| Android `BackHandler` blocking (`ConnectionBanner.tsx:65-67`) | Android | Not needed (iOS only) |
| `AppState` listener | RN lifecycle | `scenePhase` |
| `AccessibilityInfo.announceForAccessibility` | RN a11y | `AccessibilityNotification.Announcement` |
| `useNow(60_000)` timer | Aging labels | `TimelineView(.periodic(from:by: 60))` |
| `useInventoryQuery` revision plumbing | React re-render model | Observable revision + `.task(id:)` |
| Expo `Alert`-based `confirm()` (`src/ui/confirm.ts:26-47`) | RN | `.confirmationDialog` / `.alert` with `role: .destructive` (default destructive except copy-in) |
| `RefreshControl` element quirk (`app/household.tsx:237-239`) | Android child handling | `.refreshable` |

---

## 16. Tests to port

### 16.1 App-side unit tests (port to Swift Testing)

`src/services/household/__tests__/client.test.ts`
- `:5` *stores the token and origin from a successful pair* — pair 200 with
  `{token:"abc", deviceId:"dev-1", origin:"https://inventory.wystudio.be", householdName:"Home", contractVersion:1}`
  → session token/deviceId/origin as given; fetch was called.
- `:31` *maps 401 to HouseholdHttpError* — 401 `{error:"unauthorized"}` → error with
  `name HouseholdHttpError, status 401, code "unauthorized"`.
- `:43` *lists spaces from the household API* — URL contains `/v1/spaces`; first space
  name `Garage`.
- `:70` *PUTs photo bytes then POSTs the item as JSON, and maps 409 to ConflictError* —
  PUT body is bytes; POST body is a JSON string whose `photo.id` is a UUID; call log is
  exactly `[PUT https://inventory.wystudio.be/v1/photos/<uuid>, POST https://inventory.wystudio.be/v1/items]`;
  created id `item-1`, `photoId` a UUID; a PATCH answered `409 {error:"conflict", updatedAt:11}`
  rejects with `ConflictError`.

`src/services/household/__tests__/devices.test.ts`
- `:20` *reads the household’s phones with the session token* — devices parsed exactly
  (incl. `lastSeenAt: null`); URL `https://inventory.example/v1/devices`; method `GET`;
  `Authorization: Bearer secret-token`.
- `:40` *skips entries it cannot read instead of failing the list* — `[valid, {id:7}, null]` → only `a`.
- `:50` *rejects an answer without a list* — `{nope:true}` → `HouseholdHttpError`.
- `:60` *deletes the phone by id* — id `a/b` → URL `…/v1/devices/a%2Fb`, method `DELETE`.
- `:70` *treats a phone that is already gone as removed* — 404 → resolves.
- `:78` *passes other failures on* — 500 → rejects with `status 500`.

`src/services/household/__tests__/reachability.test.ts`
- `:44` *reports ok for any answer from the home server* — 200 and 404 → `[ok, ok]`; the
  404 still rejects with status 404.
- `:57` *reports unauthorized for a 401 on a request that carried a token* → `[unauthorized]`.
- `:62` *treats a refused household code while pairing as an answer, not a removed phone*
  — pair 401 rejects (status 401) and reports `[ok]`.
- `:74` *reports offline when the request never gets an answer* — thrown TypeError →
  rejects with code `offline`, reports `[offline]`.
- `:84` *reports offline when Cloudflare says the home box is down* — 530, 502, 500 →
  `[offline, offline, ok]`.
- `:91` *stops reporting to a listener that unsubscribed* → `[]`.
- `:97` *never fails a request because a listener threw* — response status 200 still returned.

`src/services/household/__tests__/shadow.test.ts`
- `:7` *mirrors a successful household create into local SQLite* — POST `/v1/spaces`
  returns `space-server`; the result id is `space-server` and the local repo's
  `getById("space-server")` has name `Garage`.

`src/services/household/__tests__/import.test.ts`
- `:7` *collects local rows including system drop-zone* — dump contains space id
  `drop-zone-space`, container id `drop-zone`, and an item named `Drill`.
- `:19` *POSTs the dump then PUTs each photo* — with an item photo id
  `aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee`, `/v1/import` answering `{ok:true, items:1, photos:1}`
  and photo PUT 201 → `result.items == 1`, `photosUploaded == 1`; a `POST …/v1/import`
  and a `PUT …/v1/photos/…` were made.

`src/ui/household/__tests__/join.test.ts` (CODE = `MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S`)
- `:15` *accepts a full code however it was typed* — normalised CODE and its lowercase,
  space-separated form → `nil`.
- `:20` *names characters no code uses before complaining about the length* —
  `MMWKU-M2H7%` → `chars "U %"`.
- `:24` *reports the length of a short or long code* — 18 and 27 chars → `length` 18 / 27.
- `:34` *passes a full code and a name* → `{}`.
- `:38` *puts each problem under its own field* — `("ABC","   ")` →
  `{code: wrongLength(3), name: nameRequired}`; `MMWKU` → `badChars("U")`.
- `:46` *asks for an empty code, saying where it comes from, rather than counting it* →
  `codeRequired`.
- `:52` *keeps a real phone name* — `Anna’s iPhone` kept; `"  Pixel 8 "` → `Pixel 8`.
- `:57` *skips generic and missing names* — `iPhone`, `IPAD`, `android`, `nil` → `""`.
- `:67` *reads a 401 from pairing as a refused code*.
- `:71` *reads no answer, a timeout and Cloudflare’s origin errors as offline* —
  `(0,offline)`, `(0,timeout)`, `(530,http_530)` → `offline`.
- `:77` *reads anything else as a plain failure* — `(500,invalid_response)`, plain error → `other`.
- `:84` *keeps only the host of the address* — `https://inventory.wystudio.be` →
  `inventory.wystudio.be`; `http://192.168.1.5:8788/` → `192.168.1.5:8788`;
  `inventory.example` unchanged.

`src/ui/household/__tests__/status.test.ts` (household-relevant parts; NOW = 2026-10-02T12:00Z)
- `:101` *describes each phone* — mine → `thisPhone`; 3 days ago → `lastUsed("3 days ago")`;
  never → `neverUsed`.
- `:107` *lists this phone first, then the rest in the order they joined* —
  `[a, b, c]` with mine `b` → `[b, a, c]`; without mine → unchanged order.
- `:24, :33, :42, :48, :53, :61, :70` — backup summary/row/reason tests (port with the
  Backup spec; `:48` *hides it on a joined phone that never set it up (#48)* is a
  household rule).

Related tests owned by other areas but exercising household inputs:
`src/ui/__tests__/code.test.ts:4, 9, 16, 24` (normalise/invalid chars/format),
`src/ui/__tests__/errors.test.ts:8-20` (offline/timeout/502/530/`(520,"origin_down")` → offline; read vs
save bodies), `:22` (401/403 `unauthorized` → revoked, except `join` → server), `:28`
(null / `(404,"http_404")` / `not_found` → gone, titled by subject), `:41` (`photo_missing`
→ photo, distinct from gone), `:52` (ConflictError → conflict), `:56` (anything else →
local), `:66` (no raw code ever reaches copy), `:105` / `:110` (`needsRefreshBanner`
suppressed for offline and revoked), `:116` (`isOffline`).
Feature tests that feed `HouseholdHttpError`/`ConflictError` into their own copy or flows
(port with those specs): `src/ui/container/__tests__/containerRules.test.ts:191-219`
(`labelFailureMessage`), `src/ui/scan/__tests__/scanRules.test.ts:59-80`
(`linkFailureMessage`), `src/ui/item/__tests__/moveFlow.test.ts:44-141, 143-197, 252-256`
(`attemptMove` lock/conflict-retry-once/gone, `attemptUndo`, offline wording),
`src/ui/home/__tests__/homeList.test.ts:52-73` (`householdCounts`: drop-zone items counted,
its container not).

No tests exist for `ConnectionProvider`, `HouseholdProvider`, `photoCache`,
`importOffer`, `unpairedNotice`, `JoinForm` or `app/household.tsx`. Recommended new Swift
tests: the connection state machine with an injected clock (blip < 2.5 s stays `unsure`
then `online` without banner; ≥ 2.5 s → `offline`; `ok` after failure invalidates at most
every 5 s; `unauthorized` is sticky; new session resets); importOffer
(joinedBefore short-circuit; zero counts clear; counts stored); photo cache hit/miss and
atomic write; session load defaults and keychain attribute compatibility. Also worth
pinning natively because the JS has no test for them: 409 body coercion (§3.2 step 3:
`null` → 0, `"11"` → 11, junk → nil); a non-JSON 5xx body maps to `(status,
"invalid_json")` and a 530 HTML page still reads as offline; missing list keys decode as
`[]` (§4); `upsertItemGraph` resets an existing local container's `visual_type` to `box`
(§7); `hydrateThumb` skips rows whose thumb is already `file:` (§6.2); `listRecent` sends
`limit` URL-encoded; `revokeDevice` percent-encodes the id (`a/b` → `a%2Fb`).

### 16.2 Server tests (stay in TypeScript; they define the wire contract)

- `home-server/test/pair.test.ts:26` bootstrap secret printed once, matches
  `/^[0-9A-HJKMNP-TV-Z-]{20,}$/`; `:42` pair returns origin, `"Home"`, contract 1, token,
  deviceId; `:66` wrong secret → 401; `:84` session/devices need a token, lowercase secret
  and `" Pixel "` work (name trimmed); `:118` any device may revoke another (204, revoked
  token → 401); `:151` health has only `ok`, `contractVersion`.
- `home-server/test/health.test.ts:10` health keys and JSON content type; `:25` unknown
  route (`/v1/status` without repos) → 404.
- `home-server/test/rest.test.ts:42` status needs token; `schemaVersion 7`, revision,
  `"Home"`; `:58` CRUD round-trip incl. PATCH `quantity: 2` and `quantity: 0`, search,
  `POST /containers/:id/qr` 201, space `itemCount 1`; `:127` stale `updatedAt` → 409 with
  current `updatedAt`, stored name unchanged.
- `home-server/test/import.test.ts:21` import twice keeps ids, `quantity 0`, tags;
  `:50` import then `PUT /v1/photos/:id` stores bytes under the phone's id.
- `home-server/test/photos.test.ts:29` store needs `HOUSEHOLD_PHOTO_SECRET`; `:38` worker
  store round-trip with Bearer secret; `:75` full + thumb WebP, `r2:household/primary/photos/` uri;
  `:84` multipart item with photo, GET returns `image/webp`, `private`, `immutable`;
  `:153` PUT then JSON POST attaches the id; unknown photo id → 400.
- `home-server/test/backup.test.ts:24, 34, 56`, `migrate.test.ts:10, 27`,
  `web.test.ts:60, 74, 117, 153, 217` — server internals.

---

## 17. Open questions

- **Q1 Contract version.** The client ignores `contractVersion` from `/v1/pair` (and never
  calls `/v1/health` except to ping). Should the native app refuse or warn when
  `contractVersion != 1`? Parity says ignore.
- **Q2 Import UNIQUE collisions.** `applyHouseholdDump` fails the whole import when a tag
  name, container short code or QR token already exists in the household under another id
  (§11.4). Fix server-side (e.g. resolve tags by `normalized_name`, as the shadow does) or
  accept? Out of scope for the native port but visible to users.
- **Q3 Shadow photo URIs.** Shadowed `item_photos.uri` are `r2:` strings; after leaving,
  those items show placeholders in local mode, and the phone backup marks them as synced.
  Keep as is?
- **Q4 Shadowed item updates drop tags** (`items.update` mirror writes only the row). Keep
  parity or also mirror tags?
- **Q5 HTTP repo quirks to keep or fix:** `qr.getByContainer` uses the container id as the
  binding id; `items.countAll` excludes drop-zone items; `items.countUnsorted` downloads
  thumbnails just to count; `items.update` silently ignores `photo`; ids not URL-encoded in
  paths (safe for UUIDs and `drop-zone*`).
- **Q6 Live updates.** Adopt `GET /v1/events` (SSE) to refresh when another phone writes,
  or keep focus/foreground refresh only (parity)?
- ~~**Q7 Timeout semantics.**~~ **Resolved (consistency pass):** on device the RN deadline
  already covers the whole exchange including the body (§3.1), so a total-request deadline
  is parity.
- ~~**Q8 AsyncStorage migration ownership.**~~ **Resolved:** `02-device-storage-migration.md`
  §5.4 owns the single importer for all seven keys (raw-string copy, Int marker
  `native.legacyImport.v1`).
- **Q9 Leaving offline** leaves a stale device entry on the server (best-effort revoke).
  Retry the revoke later, or keep parity?
- **Q10 `unsure` state UI.** Only the Household status card distinguishes it. Keep?
- **Q11 Keychain accessibility.** The session is `WhenUnlocked`. If the native app ever
  refreshes in the background (BGAppRefresh), reads would fail while locked. Migrate to
  `AfterFirstUnlock` on first native launch? Related: `loadHouseholdSession` maps **any**
  keychain error to "not joined" (`session.ts:26-28`), so a launch while protected data is
  unavailable (e.g. `errSecInteractionNotAllowed` during prewarming or a locked background
  launch) would show the phone as unpaired with local data. Recommend treating that status
  as "unknown, retry when protected data becomes available" rather than `nil`.
- **Q12 LAN / discovery.** None exists; the app requires internet and the Cloudflare
  hostname. Any plan for Bonjour/Tailscale? (Would need `NSLocalNetworkUsageDescription`.)
- **Q13 Device name** cannot be changed without rejoining (`strings.join.nameHint`); no
  rename endpoint exists. Keep?
- **Q14 Orphaned capture files.** After a paired `items.create`, the shadow `item_photos`
  row stores the server's `r2:` URI (§7), and `app/item/new.tsx` treats the draft photo as
  owned by the item (`clearDraft`, no delete). The captured file in local storage is copied
  into the cache (§8) but is then referenced by no row, so it is never deleted. Delete it
  after a successful household create, or keep parity? (Capture spec dependency.)
- **Q15 `leaveBody` promise.** The copy says what the phone *saw* while joined stays; in
  fact only its own writes were mirrored (§7). Change the copy, or mirror reads too?

---

## 18. Dependencies on other areas

- **Database & repositories spec**: schema (v7), `LocalRepositories` API that
  `HTTPRepositories` and the shadow must mirror exactly; drop-zone ids; `ConflictError`;
  `newId()` UUIDv4 lowercase; tag normalisation; `searchText` rule.
- **On-device data migration spec**: keychain attributes (§5), AsyncStorage legacy store
  (§14), caches; same bundle id and Team ID for keychain access.
- **Error handling / copy spec**: `describeError`, `needsRefreshBanner`, `isOffline`
  (§10); `strings.*` keys referenced throughout; `ago()`, `plural`, `sentenceList`.
- **Capture / image store spec**: `readStoredPhoto(uri)` for uploads and import; local
  photo files live in `Documents/item-photos/` as absolute `file://` URIs that must be
  re-based if the container path changes; `deleteStoredPhotos` must ignore `r2:` URIs.
- **Backup (inventory-sync) spec**: `loadAccount()` / recovery code in the keychain;
  `downloadPhoto(photoId)` fallback during import; backup runs over local SQLite including
  shadow rows; `showBackupRow`, `strings.backup.pairedNote`.
- **Home spec**: unpaired notice placement, "explained elsewhere" logic, header caption,
  empty states, household name as title.
- **Settings / Onboarding / Privacy specs**: Household row, server address, onboarding
  join step reusing the join form (draft persistence), paired copy variants.
- **Navigation / app shell spec**: boot gate waits for `household.ready`; connection
  banner slot in every screen frame; the removed-phone overlay above sheets; revision /
  invalidate mechanism; toast host; haptics; confirm dialogs.
- **Scan / QR, Item, Container, Space specs**: they call the repository protocol and must
  handle `nil` (404) as "gone", `ConflictError`, and the `revoked` state relaxations.
- **Server (`home-server/`)**: unchanged; this spec's §3 is the contract the native app
  must speak.

---

## 19. Suggested Swift shape (non-binding)

```swift
struct HouseholdSession: Codable, Sendable, Equatable {
    var origin: String; var token: String; var deviceId: String
    var deviceName: String; var householdName: String
}

enum Reachability: Sendable { case ok, offline, unauthorized }
enum ConnectionState: Sendable { case local, online, unsure, offline, revoked }

protocol HouseholdTransport: Sendable {
    func fetch(_ request: HouseholdRequest) async throws -> (HTTPURLResponse, Data)   // reports reachability
    func json(_ request: HouseholdRequest) async throws -> [String: JSONValue]           // §3.2 rules
}

@MainActor @Observable final class HouseholdStore { var session: HouseholdSession?; var ready = false
    func pair(code: String, name: String) async throws; func disconnect() async }

@MainActor @Observable final class ConnectionMonitor { private(set) var state: ConnectionState
    func report(_ r: Reachability); func retry() }   // §9 with an injectable clock

protocol InventoryRepositories: Sendable { /* spaces, containers, items, qr, search */ }
struct HTTPRepositories: InventoryRepositories { … }        // §6.1
struct ShadowingRepositories: InventoryRepositories { … }   // §7
actor HouseholdPhotoCache { func resolve(_ id: String, kind: PhotoKind) async -> URL?
                            func remember(_ id: String, full: URL, thumb: URL?) }  // §8
```

---

## Reviewer notes

Adversarial review against the source (every cited file re-opened; citations spot-checked,
all original `path:line` references found accurate). Changes made:

- §2.1: added `PORT` override and loopback-only publish (`compose.yaml:20`), and the
  `INVENTORY_DATA_DIR` default `./data`.
- §2.3: `last_seen_at` is stamped at pairing, so `lastSeenAt` is never `null` with this
  server ("Never used" is effectively unreachable); cross-referenced in §13.2.
- §3.2: documented JS `Number()` coercion for the 409 `updatedAt` (`null` → 0, numeric
  string accepted) and that `ConflictError` is not a `HouseholdHttpError`.
- §3.4: widened the 500 row (every route without try/catch, photo-store failures on
  `GET /v1/photos/:id`), added Hono's text/plain 404 for unknown routes and the 400
  `system_record` from QR binding on the drop zone; fixed table continuity.
- §3.5: `limit` clamp to 1…100; list ordering `created_at DESC`; earliest-photo rule for
  `photoId`; newest-binding rule for `qrToken`; server-side validation messages for item
  create/patch; blank space names accepted; container `name` clears on any non-string;
  `category`/`notes` clear on any non-string.
- §4: added the decoding-strictness rule (JS does no shape validation; decode leniently,
  map failures to `invalid_response`).
- §5: orphan device on keychain-save failure; the view swap happens inside `pair()`;
  exact expo-secure-store add/update/delete semantics; keychain survives uninstall.
- §6.1: listed the `POST /v1/items` body keys and that draft photo metadata is never sent;
  corrected "optional numeric thumbUri" (it is a string); `getPhotos` returns hydrated
  URIs; `spaces.create` body is the input verbatim.
- §6.2: `hydrateThumb` also short-circuits when the thumb is already `file:`.
- §7: fixed the pass-through citation (`:85-86` pointed at `createAndBind`); documented
  that `upsertItemGraph` overwrites an existing local container's `visual_type` with `box`
  and space metadata/timestamps; added SQL argument orders; corrected the claim that the
  shadow copy is "exactly what `leaveBody` promises" (it is not — new Q15).
- §9: first-recovery behaviour; untagged global reachability bus can leak an old token's
  401 into a new session (native fix suggested); `inactive → active` also triggers the
  resume refresh, and the effect re-runs on session change.
- §11.1: corrected "offered at most once" — created once, but shown on every Paired-view
  mount until copied / dismissed / left; DB-not-ready skips the offer forever.
- §11.3: sync fallback is built after the POST; neither photo source throws.
- §11.4: FK enforcement on the server makes skipped parents fail the whole import; the
  phone's drop-zone rows overwrite the server's.
- §12: view-swap timing on join/leave; failure notices are assertive live regions and
  clear on the next attempt; `delete` context uses save wording; remove does not
  `invalidate()`; `listDevices` ignores `timeoutMs`; `toDevice` coercion notes.
- §13.2: `ago()` month/year arithmetic, pluralisation and future-time rule.
- §14: moved the UserDefaults guidance out of the middle of the table (it had split the
  table); keep values as the same strings; rollback caveat.
- §16: added the remaining `errors.test.ts` cases and the feature tests in
  `containerRules`, `scanRules`, `moveFlow`, `homeList` that exercise household errors;
  added recommended native-only tests.
- §17: extended Q11 (keychain read errors read as "not joined"); added Q14 (orphaned
  capture files after a paired create) and Q15 (`leaveBody` copy mismatch).

**Completeness / consistency pass (cross-spec critic)**

- §3.1 timeout row and §4: the earlier text said the timer stops when headers arrive, so
  the body was not under the timeout. That holds for Node fetch, not for the shipped app:
  RN's `fetch` (`whatwg-fetch` over XHR) resolves only after the full body is buffered
  (`node_modules/whatwg-fetch/dist/fetch.umd.js:546-562`). The deadline is therefore
  total wall-clock, the same as `03-sync-account.md` §4.1 and
  `09-app-shell-lifecycle-config.md` §8.4. Q7 closed as resolved.
- §5: the keychain recommendation required the three-service probe
  (`app:no-auth` → `app:auth` → `app`). It now defers to the single canonical recipe in
  `02-device-storage-migration.md` §4.3 (`app:no-auth` → `app`).
- §9.6 removed-phone layer: the native suggestion (`.fullScreenCover` with a window
  fallback) now defers to the shell decision, a pass-through overlay `UIWindow` shared with
  toasts (`09-app-shell-lifecycle-config.md` §7.6-7.7).
- Q8 closed: 02 §5.4 owns the AsyncStorage import.
- Coverage check: every file in `src/services/household/*`, `HouseholdProvider`,
  `ConnectionProvider`, `src/ui/household/*`, `unpairedNotice.ts` and `app/household.tsx`
  is covered; `dump.ts` is types plus a trivial `emptyDump()`, fully described in §11.2.
