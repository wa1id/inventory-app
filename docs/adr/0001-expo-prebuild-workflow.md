# ADR 0001 — React Native with Expo, using the prebuild (CNG) workflow

Status: accepted
Date: 2026-07-24
Issue: #2

## Context

The MVP needs one shared codebase serving iOS and Android, and it needs five
capabilities that all touch native code:

| Requirement    | Issue | Module                                       |
| -------------- | ----- | -------------------------------------------- |
| Camera capture | #6    | `expo-camera`                                |
| QR scanning    | #10   | `expo-camera` barcode scanner                |
| Local database | #3    | `expo-sqlite`                                |
| Image handling | #6    | `expo-image-manipulator`, `expo-file-system` |
| Secure storage | #2    | `expo-secure-store`                          |

## Decision

Use **React Native with Expo on the prebuild / Continuous Native Generation
workflow**: `android/` and `ios/` are generated from `app.json` by
`expo prebuild` and are not committed.

### Why not Expo Go

Expo Go cannot run a project whose native configuration differs from its own
prebuilt binary. This project needs custom permission strings, blocked
permissions, and an app identifier, so Expo Go is limited to throwaway
experiments. In practice this was confirmed during setup: the Expo Go build
installed on the test device (2.32.19) predates this project's SDK entirely.

### Why not the bare workflow

Every native capability above is covered by a maintained Expo module with a
config plugin. Committing `android/` and `ios/` would mean hand-maintaining
Gradle files, Podfiles, and `Info.plist` entries — real ongoing cost — in
exchange for flexibility the MVP does not need. Prebuild keeps native config
declarative in `app.json` and reviewable in a diff.

The escape hatch is intact: if a future feature needs native code Expo does not
model, `expo prebuild` output can be committed and the project continues as a
bare app with no rewrite.

### Consequences

- `android/` and `ios/` are gitignored and rebuilt on demand; native changes are
  made in `app.json` or a config plugin, never by editing generated files.
- A development build must be installed on a device before `npm start` is
  useful. `npm run android` does both.
- CI regenerates the native project on every run, so a drifted local `android/`
  directory cannot mask a broken configuration.

## iOS constraint on the current development machine

The development machine for this work is Linux, and the only attached physical
device is Android (Samsung SM-G973F, Android 12). Apple's toolchain requires
macOS, so **iOS builds and physical iOS validation cannot be performed here.**

This does not change the architecture — the codebase, config plugins, and
`Info.plist` permission strings are all in place, and `eas.json` defines iOS
build profiles. It does mean:

- The iOS release path runs through EAS or a macOS machine
  (`.github/workflows/release.yml`).
- Issue #8's requirement to validate on a physical iOS device is **outstanding**
  and cannot be closed from this environment. It is recorded in
  `docs/known-limitations.md`.
