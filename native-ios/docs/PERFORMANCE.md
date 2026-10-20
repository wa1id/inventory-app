# Performance with 10 000 items

Milestone M9 (`spec/00-index.md` §7) asks that search over 10 000 items answers in under a
second and that typing stays smooth. This file records what was measured, what changed and how
to measure again. Read `CONVENTIONS.md` ("Time in tests") before writing a test that times
anything.

All figures: the build Mac (Apple M4 Pro, macOS 15.7, system SQLite) and its iPhone 17 Pro
simulator (iOS 26.3), **Debug builds** (the package unoptimised), measured on 2026-10-20 while
other checkouts were building on the same Mac. Read them as upper bounds for the simulator; a
Release build on a phone is a different machine (see the last section).

## At a glance

| M9 asks | Measured |
|---|---|
| Every search under a second | The search SQL takes 19–43 ms on 10 000 items for every query class. Keystroke to results drawn on Home: 272–362 ms, of which 200 ms is the pause Home waits for after typing (06 §5.6). |
| A misspelt search | Correcting it adds about 70 ms the first time at a revision (was about 160 ms) and about 30 ms after; on the simulator "scrwdriver" → "screwdriver" draws in 348–358 ms. |
| Typing stays smooth (no stall over 100 ms) | Typing "screwdriver" at 8 keys a second: longest frame 46–90 ms, no frame over 100 ms. |
| Lists Home reads on every focus | Recently added 25–29 → 4–7 ms; every other list 10 ms or less. |
| Launch | No launch step grows with the inventory (`PerfLaunchTests`). Cold launch to the first responsive frame: 1.05–1.16 s on the simulator. |
| Memory | 92 MB footprint with 10 000 items on Home; searching and scrolling 230 results adds 14 MB. Nothing loads the whole inventory. |

## The large inventory (`-demoSeed large`)

`PerfInventorySeed` (`InventoryStorage/Seeding/`, DEBUG builds only) writes a deterministic
inventory into a migrated database inside the caller's transaction, with the repositories' own
folds (`itemSearchText`, `normalizedTagName`), so the rows are what `items.create` would store:
10 000 items (28 % accented names, 22 % without a category, 30 % with notes, 58 % with one to
three of 60 tags, quantities from 0 to 500), 20 spaces, 250 containers with unique short codes
(40 with labels), 303 items waiting in the drop zone, 500 in the Workshop's **Parts bin**
`BIN-P4RT`, six recent places, and the small demo inventory's places and newest items (Tool chest
`CAB-J92R`, Cordless drill, Bike pump newest). The same shape writes the same rows, ids included
(`PerfInventorySeedTests`). Writing it: 0.3–0.45 s of CPU in one transaction; 5.6 MiB on disk.

`-demo YES -demoSeed large` (`ShellDemoLargeSeed` in `App/Shell/ShellDemo.swift`) writes it at
boot into a temporary database with 320 photos (copies of 4 drawn pictures): Home is drawn
1.1–1.4 s after launch (photos 0.7–0.8 s, rows 0.3 s). UI-KIT §5.3 lists the names demo routes use.

## How to measure

| What | Command |
|---|---|
| Package report: search classes, list reads, Home's per-redraw work, the correction, the v7 rebuild | `scripts/mac.sh shell 'cd Packages/InventoryKit && INVENTORY_PERF=1 swift test --scratch-path ~/inventory-native/<key>/spm-build --filter PerfReport 2>&1 \| grep "PERF \|"'` (`<key>`: the checkout's folder on the Mac, see `.build-logs/test.log`) |
| Package regression guards (default run) | `InventoryPerformanceTests`, `PerfReadParityTests`, `PerfLaunchTests`, `PerfCancellationTests` in `scripts/mac.sh test`: CPU time inside the read, best of five, limits several times the measured figures |
| The app on the simulator (default `apptest` too) | `scripts/mac.sh apptest -only-testing:InventoryTests/PerfHomeHostedTests`, then `grep 'PERF \|' .build-logs/apptest.log` |
| The real app through XCUITest | `scripts/mac.sh uitest -only-testing:InventoryUITests/PerformanceUITests` (includes XCUITest's own round trips: an upper bound) |
| Screenshots | `RUN_SETTLE_SECONDS=10 scripts/mac.sh run out.png -demo YES -demoSeed large`, plus `-demoArea home -demoState search` or `misspelt` |

## Results

### Search SQL on 10 000 items (package, best CPU of five; the SQL is unchanged)

| Query | Class | Items, places | CPU |
|---|---|---|---|
| `a` | 1 letter | 200, 30 | 19 ms |
| `sc` | 2 letters | 200, 1 | 33 ms |
| `screws` | common word | 200, 0 | 35 ms |
| `box` | container type | 200, 30 | 37 ms |
| `garage` | space name | 200, 1 | 34 ms |
| `crème`, `zoë` | accented (folded query, stored text keeps its accents: U12) | 0, 0 | 28–30 ms |
| `jumper cables` | rare, two words | 52, 0 | 28 ms |
| `zzqx` | no match | 0, 0 | 27 ms |
| `BOX-7K` | short code | 11, 1 | 28 ms |
| `red screws 4x40` | three words | 0, 0 | 32 ms |

### Correcting a misspelt search (package, best CPU of five)

| Step | Before | After |
|---|---|---|
| Vocabulary read, 10 000 items (505 distinct words) | 123 ms | 36 ms |
| `scrwdriver` → `screwdriver` against those words | 1.2 ms | 0.7 ms |
| `jumpr cabels` → `jumper cables` | 8.6 ms | 3.7 ms |
| `zzqxv` (nothing close, every word compared) | 3.6 ms | 1.4 ms |
| The same three against 8 000 distinct made-up words (a worst case: real inventories reuse their words) | 87, 222, 85 ms | 38, 87, 32 ms |

So a search that finds nothing at 10 000 items costs, on top of its own 30 ms: the vocabulary
(once per revision), the correction and the corrected search, about 70 ms the first time
(about 160 ms before) and about 30 ms after.

### List reads on 10 000 items (package)

| Read | Rows | Before | After |
|---|---|---|---|
| `items.listRecent(12)` (Recently added) | 12 | 25–29 ms | 4–7 ms |
| `items.listRecent(40)` (after "Show more") | 40 | 28 ms | 5–6 ms |
| `spaces.listWithCounts` | 20 | 0.4 ms | unchanged |
| `containers.listAllWithSpace` (place rows, pickers) | 250 | 1.8 ms | unchanged |
| `items.listUnsorted` (drop zone) | 303 | 5.9 ms | unchanged |
| `items.listByContainer` (Parts bin) | 500 | 10 ms | unchanged |

Home's main-thread work per redraw with 230 results: entries and sections 2 ms; rebuilding the
place index per place row cost another 2 ms and is gone.

### Simulator: the app with `-demoSeed large` (`PerfHomeHostedTests`, two runs: alone and inside the full `apptest`)

| Step | Measured |
|---|---|
| Keystroke → results drawn, every class above | 272–362 ms (the 200 ms pause included); longest frame 17–89 ms |
| Misspelt, first at this revision: `scrwdriver` → `screwdriver` | 348–358 ms, longest frame 46–72 ms |
| Misspelt again: `jumpr cabels` → `jumper cables` | 334–346 ms, longest frame 36–50 ms |
| Typing `screwdriver` at 8 keys a second | last key → results 276–290 ms; longest frame 46–90 ms; 0 of about 100 frames over 100 ms |
| Open the Parts bin (500 items) → rows drawn | 246–279 ms |
| Open the Move sheet → 250 containers drawn | 232–243 ms |
| Scroll 230 results a screenful at a time | worst 43–45 ms, mean 29 ms; longest frame 64–65 ms |
| Memory footprint (`phys_footprint`), the suite alone | 98 MB before, 92 MB with 10 000 items on Home, 106 MB after searching and scrolling (161 → 156 → 170 MB inside the full run, other suites' state still held) |
| Cold launch to the first responsive frame (`XCTApplicationLaunchMetric`, `PerformanceUITests/testColdLaunch` with `TEST_RUNNER_INVENTORY_PERF=1`) | 1.05–1.16 s over four launches; the first after installing took 3.2 s |
| The real app through XCUITest (its own waits and element snapshots included) | launch → Recently added 4.3 s, last key → results 1.2 s, tap → the Parts bin's rows 3.7 s |

## What changed

- **Recently added.** RN's `ITEM_CONTEXT_SELECT ORDER BY i.created_at DESC LIMIT ?` worked out
  the photo and tag subqueries for all 10 000 items before sorting (`created_at` has no index,
  and U12 adds none). `listRecent` now picks the ids with RN's joins and `ORDER BY`, then reads
  the context for those rows only: same rows, same order, ties and orphans included
  (`PerfReadParityTests` compares it with RN's statement).
- **Home's place rows.** `spacesById` and `containersById` were rebuilt on every access, by every
  place row; they are now built when their reads settle.
- **Correction.** The vocabulary folds each distinct space-separated piece once instead of every
  text (the same words: `SearchSpellingTests` checks it against the tokenizer), and counts them
  after the database read, so the one connection is free meanwhile. The correction computes one
  edit-distance table per word instead of four (the whole word and three starts are all on its
  last row), skips words too short to be close through a length index, and picks the same word
  as before (checked against the four-table way on 400 random typos).
- **Typing** was already right and is now pinned by tests: a new query waits for a 200 ms pause,
  each keystroke cancels the waiting and the running search, and GRDB turns the cancellation
  into `sqlite3_interrupt` (`PerfCancellationTests`, `HomePerfCoalescingTests`).
- **The seed** is DEBUG-only, so the Release binary carries none of the demo's names.
- **Flaky tests.** The six network tests that asserted a 100–200 ms deadline returned within 5 s
  of wall-clock time (and failed when a loaded Mac woke them seconds late) now run the deadline
  on a `ManualClock`: nothing decided a millisecond before it, the timeout once it passes, the
  operation cut short; the other client tests get a clock that never moves. `ScanTestLatch`
  lets a cancelled call through and gives up after 30 s with an issue instead of hanging. Every
  polling helper waits up to 60 s of real time (returning as soon as its condition holds),
  including seven that counted `Task.yield()`s, one of which failed under load. The large-seed
  determinism test no longer compares the drop zone rows the migration stamps with the clock.
  The whole package suite (2 189 tests) then passed twice in a row while the Mac also ran the
  hosted suite and other checkouts' builds.

## Checked and left as it is

- **The search SQL** stays exactly RN's text (01 §7.5, U12): the home server runs the same
  statement, and at 19–43 ms it is far inside the budget. About half the time is the item's own
  fields, half the five location `LIKE`s per item.
- **Where work runs.** Repository reads run on GRDB's queue; the correction runs in a detached
  task; only finished arrays reach the main actor.
- **Thumbnails** decode with ImageIO at the drawn size off the main thread into a 120-entry LRU
  cache emptied on a memory warning (`ThumbnailLoader`).
- **Launch.** Every launch step is O(1) in the number of items (02 §8); reopening a 10 000-item
  database at version 7 runs only pragmas (`PerfLaunchTests`). The one O(n) step is the v7
  rebuild of an older phone's `items`, once, on the first native launch: 19–22 ms for 10 000.
- With a large inventory a common word gives many totals lines under "Items" ("“Drill bits”:
  ×51 in 14 places", …) before the first row, as RN does (06 §5.7): a product question, not speed.

## Only a phone can tell

The simulator runs on the Mac's M4 Pro with no thermal or memory limits. Before relying on these
figures, on the oldest supported iPhone with a real 10 000-item database (adopt the RN build's
file or import one): keystroke to results per query class (expect 2–3 × the simulator), typing
fast with Instruments' Hangs and Animation Hitches templates, cold launch with the App Launch
template on an adopted database, memory while scrolling a 500-item container with photos, and the
v7 rebuild on a phone still at schema 6.
