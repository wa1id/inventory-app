# Sync service

Durable storage for item photos and inventory database snapshots, so the app
survives a reinstall, a lost phone, or a wiped device. Cloudflare Worker in
front of an R2 bucket.

## Why this exists

Before this service the app was purely local: SQLite in the app's document
directory and JPEGs beside it. That is private and fast and works offline, and
it also means an uninstall is unrecoverable data loss. This adds a second copy
without giving up local-first — the device stays the source of truth, and this
is the copy that outlives it.

## The account model

There are no accounts in the usual sense: no email, no password, no user table.

At first launch the app generates 16 CSPRNG bytes, keeps them in the platform
keystore, and shows them to the user as a 26-character Crockford base32
**recovery code**. Every request carries that code as a bearer token. The
service hashes it to an account id and uses the hash as an R2 key prefix:

```
photos/<accountId>/<photoId>.jpg
backups/<accountId>/<epochMillis>.db
meta/<accountId>/usage.json
```

Two consequences follow, and both are deliberate:

- **Isolation is structural.** No route accepts an account id as input. The only
  way to name a prefix is to hold the code that hashes to it, so there is no
  id to guess and no ownership check that could be forgotten on a new route.
- **The service cannot recover a lost code.** It stores nothing that could
  reconstruct one — which is also why a breach here leaks no credentials. The
  app states this plainly before it ever asks the user to save the code.

`x-inventory-key` is a second, weaker gate carrying the same shared app secret
the recognition service uses. It ships inside the app bundle and is extractable;
it exists to keep this from being an open storage endpoint that a scanner can
discover, and nothing more.

## Endpoints

Personal backup routes require `Authorization: Bearer <recovery code>`. Health
is open. Household photo routes use a separate Worker secret (below).

| Method   | Path                       | Notes                                              |
| -------- | -------------------------- | -------------------------------------------------- |
| `GET`    | `/v1/health`               | Unauthenticated liveness and contract version      |
| `PUT`    | `/v1/photos/:id`           | Body is JPEG bytes; `:id` must be the app's UUID   |
| `GET`    | `/v1/photos/:id`           | Streams the JPEG back                              |
| `DELETE` | `/v1/photos/:id`           | Idempotent; 204 whether or not it existed          |
| `PUT`    | `/v1/backups`              | Body is a SQLite snapshot; requires schema version |
| `GET`    | `/v1/backups`              | Newest-first list of snapshots                     |
| `GET`    | `/v1/backups/latest`       | Streams the newest snapshot                        |
| `GET`    | `/v1/backups/:id`          | Streams one snapshot                               |
| `GET`    | `/v1/usage`                | Bytes and object count against the account limit   |
| `PUT`    | `/v1/household/photos/:id` | Home server only; `?kind=full\|thumb`              |
| `GET`    | `/v1/household/photos/:id` | Home server only; streams WebP from R2             |
| `DELETE` | `/v1/household/photos/:id` | Home server only; idempotent 204                   |

Household photo routes are a second caller, not a second account. The home server authenticates with `Authorization: Bearer <HOUSEHOLD_PHOTO_SECRET>` (a Worker secret, not an R2 S3 token — this Worker already has the bucket via the `BUCKET` binding). Objects live at `household/primary/photos/<id>.webp` and `…/<id>-thumb.webp`. Phones never call these routes; they talk to `https://inventory.wystudio.be`. A personal recovery code cannot name that prefix.

`npx wrangler secret put HOUSEHOLD_PHOTO_SECRET` on this Worker, and the same value as `HOUSEHOLD_PHOTO_SECRET` on the home-server compose service.

Snapshot uploads accept two headers: `x-snapshot-schema-version` (required, the
database's `user_version`, so an older app refuses a newer schema rather than
misreading it) and `x-snapshot-sha256` (optional; when present R2 verifies the
bytes it received against it and the upload fails with 422 on a mismatch).

Snapshot ids are **server** time, not the client's. A phone with a wrong clock
would otherwise write a snapshot dated 1970 that retention prunes as the oldest
— the newest backup deleting itself on arrival.

## Limits

Set in `src/contract.ts`, which is kept byte-compatible with the app's
`src/services/sync/contract.ts`:

- 4 MB per photo (the app produces well under 400 KB)
- 32 MB per snapshot
- 2 GB per account
- 5 snapshots retained, newest first

Retention keeps more than one on purpose. The failure this protects against is
not only a lost phone — it is also a bad edit or a corrupt write that gets
faithfully backed up. A single snapshot would replicate that damage and call it
durability.

## Development

```bash
npm install
npm test          # node:test, no Workers runtime needed
npm run typecheck # regenerates bindings, then tsc
npm run dev       # wrangler dev against a local R2 simulation
```

`npm test` exercises the routes against an in-memory R2 (`test/fakeR2.ts`)
rather than mocks, so account isolation, quota accounting, and retention are
tested as behaviour.

For local development leave `SYNC_SHARED_SECRET` unset — the app-key gate is
skipped when it is absent, which is what makes `wrangler dev` usable without a
secret store.

## Deploying

```bash
npx wrangler secret put SYNC_SHARED_SECRET     # must match EXPO_PUBLIC_SYNC_KEY
npx wrangler secret put HOUSEHOLD_PHOTO_SECRET # same value as the home-server env
npx wrangler deploy
```
