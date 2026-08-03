# Known limitations

State of the MVP as built. Deliberate MVP scope cuts are listed separately at
the bottom — those are not defects.

## Outstanding: physical iOS validation

Signed release-candidate builds now exist for **both** platforms, produced on
EAS:

| Platform | Artifact | Verified                                                    |
| -------- | -------- | ----------------------------------------------------------- |
| Android  | APK      | Installed and exercised on a physical SM-G973F (Android 12) |
| iOS      | `.ipa`   | Artifact inspected only — **not run on a device**           |

The iOS build is codesigned with an ad-hoc profile and installs on the devices
registered to the Apple team. Its `Info.plist` was checked directly: correct
bundle identifier, `MinimumOSVersion` 16.4, encryption exemption declared, and
exactly two permission strings (camera and photo library).

**What is still outstanding for issue #8** is validation, not building. The
development machine is Linux and the attached device is Android, so nothing has
been run on an iPhone. Someone with the device must complete
[the beta checklist](beta-checklist.md), paying particular attention to the
places iOS genuinely diverges from Android:

- **Photo orientation** after capture and after gallery import. EXIF handling
  differs between platforms, and this is the most likely place to see a
  sideways image.
- **Permission prompts.** iOS asks once and a denial is stickier than on
  Android, so the denied and permanently-denied recovery paths need exercising.
- **QR scanning** through the iOS camera stack.

Until that happens, treat iOS as built-but-unvalidated.

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

## Backup and photo storage

Shipped: an opt-in Cloudflare Worker over R2 (`worker/`) storing item photos and
whole-database snapshots, keyed by a device-generated recovery code. What is
worth knowing before relying on it:

- **The recovery code is unrecoverable by design.** The service stores nothing
  that could reconstruct one — that is what lets it hold no user records at all.
  Someone who loses the code loses the backup. The UI says so before the code is
  ever shown, but it remains the sharpest edge in the feature.
- **Android and iOS behave differently on uninstall.** iOS keeps Keychain
  entries, so reinstalling usually restores silently; Android wipes the
  keystore, so the code must be typed back in. Both paths work; only one is
  invisible. Verify the Android path on a device before calling this done.
- **Backup is not sync.** Snapshots are whole-file and last-write-wins. Running
  two devices on one recovery code will lose data.
- **Backups run on foreground, not in the background.** No background task is
  registered, so a phone that is never opened is never backed up. At most one
  automatic backup runs every 15 minutes.
- **Photo rehydration is batched, not lazy per row.** After a restore, missing
  photos are pulled back ten at a time on each sync pass rather than on demand
  when a row scrolls into view. A large library takes several passes to fill in,
  and until then those items render without a photo.
- **Snapshots are capped at 32 MB.** Well beyond a realistic personal inventory
  without photo blobs, but a hard ceiling rather than a graceful degradation —
  past it, backups fail with `too_large` and no partial strategy exists.
- **Not yet exercised end to end on a device.** The service is deployed and
  covered by tests against an in-memory R2, and the app's sync layer is covered
  against real SQLite, but no phone has completed a capture → upload →
  reinstall → restore cycle. That is the check that matters and it has not been
  run.

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

Multi-item recognition in a single photo (rapid one-shot-per-item capture
with batch review has since shipped), barcode lookup, semantic search, lending,
moving mode, zones, nested containers, collaboration and sharing, analytics,
CSV import/export, insurance reports, printable label sheets, subscriptions,
and the web portal.

Off-device backup has since shipped (see below) and is no longer a scope cut.
It is deliberately **backup, not sync**: one device is the writer, and there is
no conflict resolution. Two phones sharing a recovery code will overwrite each
other's snapshots.
