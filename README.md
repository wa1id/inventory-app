# Inventory

Record where you put things, and find them again later.

Photograph an item as you put it away, group items into containers and
containers into spaces, stick a QR label on a box, and search for anything you
have stored. Everything lives on the device and works offline.

Cross-platform (iOS + Android) from one codebase, built with React Native and
Expo.

## Prerequisites

| Tool               | Version                     |
| ------------------ | --------------------------- |
| Node.js            | 22 LTS or newer             |
| npm                | 10 or newer                 |
| Android Studio SDK | Platform 36, build-tools 36 |
| JDK                | 17 or 21                    |
| Xcode (iOS only)   | 16 or newer, on macOS       |

Supported OS versions: **iOS 15.1+** and **Android 7.0+ (API 24)**.

## Setup

```bash
npm ci                 # deterministic install from the lockfile
cp .env.example .env.local
```

Every variable is optional for local development. With no recognition endpoint
configured, photo suggestions are simply off and items are added manually.

## Running

The app uses Expo's prebuild workflow, so a development build must be installed
on the device or emulator once. It is not compatible with Expo Go — see
[ADR 0001](docs/adr/0001-expo-prebuild-workflow.md).

```bash
npm run android        # build, install, and start the dev server (Android)
npm run ios            # same for iOS — requires macOS
npm start              # start the dev server against an installed dev build
```

For a USB-connected Android device, forward the Metro port so the device can
reach the dev server:

```bash
adb reverse tcp:8081 tcp:8081
```

Regenerate the native projects after changing `app.json` or adding a native
dependency:

```bash
npm run prebuild
```

## Checks

```bash
npm run lint           # ESLint
npm run typecheck      # tsc --noEmit
npm test               # Jest
npm run format:check   # Prettier
npm run doctor         # Expo dependency/config health check
```

The test suite runs as two Jest projects:

- **logic** — repositories, search, migrations, and the recognition contract,
  in plain Node. Persistence tests run against real SQL via Node's built-in
  SQLite, so CRUD, foreign keys, rollback, and migrations are genuinely
  exercised rather than mocked.
- **ui** — React Native component tests via `jest-expo`.

```bash
npx jest --selectProjects logic
```

## Platform builds

Release builds go through EAS; profiles are defined in `eas.json`.

```bash
eas build --platform android --profile preview
eas build --platform ios     --profile preview
eas build --platform all     --profile production
```

`.github/workflows/release.yml` builds both targets. iOS builds require macOS
or EAS and cannot be produced on a Linux development machine.

## Architecture

```
app/                      expo-router routes (file = screen)
  (tabs)/                 Spaces, Search, Scan — the three primary destinations
  space/ container/ item/ detail, create, and edit screens
  capture.tsx             camera + gallery capture
  settings.tsx            outside the tabs, reachable from every tab header
src/
  core/                   IDs, short codes, tokenization — pure and testable
  db/                     schema, migrations, SQL adapters
  repositories/           transactional data access, one module per aggregate
  services/               AI recognition, image storage, telemetry, config
  providers/              database lifecycle and change notification
  ui/                     theme and shared components
  i18n/                   all user-facing copy
```

Two ideas carry most of the design:

**The database is the only source of truth.** There is no mirrored in-memory
store. Screens read through `useInventoryQuery`, which re-runs on focus and
whenever a write bumps a revision counter, so a change made anywhere is visible
everywhere without a cache to invalidate.

**SQL is abstracted behind one small interface.** `SqlDatabase` is implemented
by `expo-sqlite` on device and by `node:sqlite` in tests. Repositories are
written against the interface alone, which is what lets persistence be tested
for real.

## Configuration and secrets

`EXPO_PUBLIC_*` variables are inlined into the bundle at build time and are
**public**. No secret belongs in one.

AI recognition is deliberately indirect: the app posts a photo to our own
endpoint, which holds the provider credential server-side. There is no provider
key in the client, and a test asserts the request carries no `Authorization` or
`X-API-Key` header.

## Telemetry and privacy

Analytics and crash reporting are abstracted behind `TelemetrySink`; no provider
is enabled in this build. Event payloads pass through an **allowlist** — only
timings and outcome classes survive, so item names, notes, photo URIs, and QR
tokens cannot reach a log line even by mistake. The in-app privacy notice under
Settings › Privacy describes camera and photo handling.

## Documentation

- [ADR 0001 — Expo prebuild workflow](docs/adr/0001-expo-prebuild-workflow.md)
- [Beta test checklist](docs/beta-checklist.md)
- [Known limitations](docs/known-limitations.md)
