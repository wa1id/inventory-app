# Conventions for the native port

Read `docs/spec/DECISIONS.md` first; it overrides the specs. Then read the spec that owns the code you are writing (`docs/spec/00-index.md` §3 maps every RN source file to its owner spec).

## Building and testing

The code is written on Linux and compiled on the Mac over SSH. There is no Swift toolchain on Linux.

| Command | What it does |
|---|---|
| `native-ios/scripts/mac.sh test` | `swift test` for `Packages/InventoryKit` on the macOS host. Pass `--filter <regex>` to narrow. |
| `native-ios/scripts/mac.sh build` | Generates the Xcode project and builds the app for the iOS simulator. |
| `native-ios/scripts/mac.sh apptest` | Runs the app-hosted `InventoryTests` on this checkout's own simulator. |
| `native-ios/scripts/mac.sh run out.png [args…]` | Builds, installs, launches (with launch arguments) and screenshots the app on this checkout's simulator. |
| `native-ios/scripts/mac.sh launch out.png [args…]` | Relaunches the installed app with launch arguments, without building, and screenshots it. |
| `native-ios/scripts/mac.sh openurl <url> out.png` | Opens a URL (e.g. `inventory://c/<token>`) in the simulator and screenshots it. |

`run`, `launch` and `openurl` honour `APPEARANCE=dark` and `CONTENT_SIZE=accessibility-extra-extra-extra-large` (any `simctl ui content_size` value). Look at screenshots with the Read tool. In Debug builds, `-gallery <name> [-galleryPage <n>]` shows an area's gallery instead of the app (`App/Shared/DebugGallery.swift`), so views can be checked without navigating to them.

Each checkout, including each git worktree, gets its own folder and simulator on the Mac, so parallel work never collides. Full logs land in `native-ios/.build-logs/`, and stdout shows a filtered summary.

## Code

- Swift 6 language mode with complete strict concurrency. No `@unchecked Sendable` or `nonisolated(unsafe)` without a comment that justifies it.
- Logic belongs in `Packages/InventoryKit` so it runs under `swift test` on macOS. Only views and code that needs UIKit, AVFoundation capture or VisionKit go in the app target (`App/`). Guard Apple-platform-only APIs with `#if canImport(UIKit)` where a package type needs them.
- Package types the app uses are `public`. Keep everything else `internal`.
- Behaviour must match the RN app unless `DECISIONS.md` says otherwise. Where parity is subtle, leave a short comment naming the RN source (`// RN: src/repositories/items.ts:120`). Don't comment the obvious.
- Avoid force unwraps and `try!` outside tests.
- Copy comes from `InventoryStrings`; never hard-code user-facing English in other modules. The exception is the strings the RN repositories hard-code themselves, which stay literal for parity (DECISIONS U9).
- No new SwiftPM dependencies without a note in your report explaining why.

## Tests

- Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`). Use parameterised `arguments:` for RN `it.each` tables.
- Use the shared test support instead of writing your own: `InventoryTestSupport` (`ManualClock`, `TemporaryDirectory`, `TemporaryDefaults`, `RecordingTelemetry`, `StubServer`/`StubReply`), `TelemetryReporter(sink:)` for injecting telemetry into models and services, and the seam fakes in `Tests/InventoryAppModelsTests/Support/SharedSeamsFakes.swift` (toasts, confirms, haptics, invalidation).
- Test targets are shared between areas. Give every top-level type in a test target (suites and helpers) a name that starts with your area, so parallel work never clashes.
- Port every RN test the owner spec lists for your area, and name each Swift test after the RN test it ports.
- **Parity vectors:** where Swift must match JS byte for byte (tokenizer, folding, base32, ids, formatting, strings), generate expected outputs by running the real TypeScript. In a worktree, first link the dependencies: `ln -s /home/walid/inventory-app/node_modules node_modules` (it is gitignored). Then write a throwaway Jest test at `src/__vectors__/__tests__/<name>.test.ts` (the `logic` project only matches `__tests__/*.test.ts`) that writes JSON, run it with `npx jest --selectProjects logic src/__vectors__`, and delete the throwaway test afterwards. Commit the generated JSON under `Tests/<Target>/Fixtures/` and load it with `Bundle.module`.
- Database fixtures at historical schema versions can be produced the same way with `src/db/nodeDatabase.ts`, which runs the real migrations on `node:sqlite`.

## Git

- Work on the branch you are given and commit only files under `native-ios/`. Never modify the RN app, the servers or the specs, unless your task says so.
- Commit messages: short imperative subject line and a body explaining what and why. No attribution trailers.
