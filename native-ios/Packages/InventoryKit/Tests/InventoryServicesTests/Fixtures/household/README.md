Household fixtures for InventoryServicesTests (`Household/`).

Produced by running the real TypeScript (`src/services/household/shadow.ts` over
`src/db/nodeDatabase.ts` and the app's migrations on `node:sqlite`). Do not edit by hand;
regenerate with the script named below (its header has the commands). The clock and the
tag ids are seeded, so a regeneration reproduces the same file.

| File | Generator | Contents |
| --- | --- | --- |
| `shadow-parity.json` | `generator/shadow-parity.test.ts` (Jest, `logic` project) | A script of household writes run through `withLocalShadow` over a remote answering each write with a scripted server reply (or failing it), on a local database seeded with rows the phone had before joining: space and container upserts (created_at never overwritten), a short code another local container holds and a space the phone never saw (both refused locally, logged as `household_shadow_failed`), item graphs with photos and tags (reuse by plain lower-cased name, `İ`, final sigma), the drop zone's look reset to `box` and its empty short code replaced by `CTR-DROP`, a photo id seen before, row-only item updates, label replacement by token and container, unbinds, and cascading deletes with a photo tombstone. Each step's outcome and whether the mirror failed, plus five dumps of every local table in rowid order. `ShadowParityTests` replays it through `ShadowingRepositories` over a stub home server with the same seeds. Mirrors that fail part-way are left out on purpose: the native mirror runs in one transaction (04 §7), RN statement by statement. |
