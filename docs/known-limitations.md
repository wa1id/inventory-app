# Known limitations

State of the MVP as built. Deliberate MVP scope cuts are listed separately at
the bottom — those are not defects.

## Blocked: iOS build and physical iOS validation

**Issue #8 cannot be fully closed from the current development environment.**

The development machine is Linux, and the only attached test device is Android
(Samsung SM-G973F, Android 12). Apple's toolchain requires macOS, so from here
it is not possible to produce an iOS build or validate anything on a physical
iOS device.

What _is_ in place: the shared codebase is platform-neutral, `Info.plist`
permission strings and the iOS bundle identifier are configured in `app.json`,
and `eas.json` plus `.github/workflows/release.yml` define the iOS build path.

What is outstanding, and must happen on macOS or EAS before release:

- An iOS development build run from a clean checkout.
- A full pass of [the beta checklist](beta-checklist.md) on a physical iPhone,
  particularly camera capture, photo orientation, QR scanning, and permission
  flows, which are the areas most likely to differ from Android.
- A signed iOS release-candidate build.

Android has been built and installed on a physical device from this machine.

## Not yet verified

- **Lower-spec device pass.** Issue #8 asks for validation on one lower-spec
  device. Only the SM-G973F was available here.
- **Real schema upgrade on device.** Migration correctness — including the
  backfill — is covered by an automated test that migrates a v1 database with
  existing rows to v2. Installing build N over build N−1 on a physical device
  has not been performed, because there is no previous release to upgrade from.
- **Search at 10,000 items on device.** There is an automated guard at that
  scale, but it runs on desktop SQLite. Phone-class storage is slower; measure
  before claiming the issue #14 performance criterion is met in the field.
- **Camera decode of a QR label.** Binding and token resolution were verified
  end-to-end on device — a generated label was bound, and opening
  `inventory://c/<token>` resolved to the correct container — but pointing the
  camera at a printed sticker needs a second screen or a printout and a human.
  The scanner path itself (`resolveScan`) is the same code the deep link uses
  and is covered by tests.

## Functional gaps

- **Photo suggestions are not configured.** `EXPO_PUBLIC_RECOGNITION_URL` is
  unset, so recognition reports `not_configured` and the app goes straight to
  manual entry. This path is fully implemented and tested; it needs a deployed
  backend to switch on. The backend itself is out of scope for this repository.
- **No crash reporting or analytics provider.** The `TelemetrySink` seam exists
  and redaction is enforced and tested, but events currently go to the console
  in development and nowhere in release.
- **Photo files are cleaned up best-effort.** Database rows are always removed
  transactionally, but if deleting the underlying JPEG fails (permissions, a
  file already gone), the file is left behind. It wastes space; it can never
  produce a broken reference.
- **QR labels are one-per-container.** Binding a second token to a container
  replaces the first. Intentional, but it means a container cannot carry two
  stickers.
- **No undo.** Deletions are confirmed but permanent.

## Deliberate MVP scope cuts

Not defects — explicitly out of scope per the epic (#1), scheduled for the
Post-MVP milestone:

Multi-item and rapid capture, barcode lookup, semantic search, lending,
moving mode, zones, nested containers, collaboration and sharing, analytics,
CSV import/export, insurance reports, printable label sheets, subscriptions,
accounts and cloud sync, and the web portal.
