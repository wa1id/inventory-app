# Beta test checklist

Run this before handing a build to internal or beta testers (issue #8). Every
item is a manual pass on a real device — automated coverage is listed at the
bottom and does not replace this.

Record: build number, platform, OS version, device model, and tester.

## Core loop

- [ ] First launch shows the three-step intro; **Skip** works from step 1.
- [ ] Create a space with a name, icon, and colour. It appears on the dashboard
      with correct counts.
- [ ] Create a container. It gets a readable short code (e.g. `BOX-7K2M`).
- [ ] Add an item **without** a photo. It appears in the container immediately.
- [ ] Add an item **with** a photo. The preview is right-way-up.
- [ ] Photo suggestions: fields prefill and are editable, or a clear "add the
      details yourself" message appears. Either way the item saves.
- [ ] Edit an item's name and quantity. Container totals update without a
      restart.
- [ ] Delete an item, a container, and a space. Each asks for confirmation and
      states the impact.

## Search

- [ ] Search an item by name, by category, and by tag.
- [ ] Search a space name — its items appear, labelled as location matches.
- [ ] Search a container short code with and without the dash.
- [ ] Tapping the `Space > Container` path opens the container.
- [ ] Empty query, no results, and cleared query each show the right state.

## QR

- [ ] Generate a QR label for a container and confirm it renders.
- [ ] Scan that label from the Scan tab; the correct container opens.
- [ ] Scan an unknown QR code; the bind picker appears and binding works.
- [ ] Scan a non-app QR code (any website); "not an Inventory label" appears.
- [ ] Rebind a label to a different container; confirmation is required.
- [ ] Remove a label; the container and its items are untouched.

## Permissions

- [ ] Deny camera at the prompt: rationale and manual entry remain available.
- [ ] Deny permanently, then reopen capture: "Open settings" is offered.
- [ ] Grant after denying; the camera works without restarting the app.
- [ ] Deny photo library; adding an item without a photo still works.

## Offline and resilience

- [ ] Enable airplane mode. Create a space, container, and item; search; scan a
      QR label. All succeed.
- [ ] Add an item with a photo while offline — it saves, with suggestions
      reported as unavailable.
- [ ] Force-stop the app mid-session, reopen: no data lost.
- [ ] Restart the device, reopen: no data lost.
- [ ] Install the previous build, add data, then install this build over it:
      data survives the schema upgrade.
- [ ] Fill device storage close to full, then try to add a photo: a clear
      message appears rather than a crash.

## Accessibility

- [ ] Set the system font to its largest setting: no clipped or overlapping
      text on Spaces, container detail, item editor, and Search.
- [ ] Screen reader (TalkBack / VoiceOver): every control is announced with a
      meaningful label; tab order is logical.
- [ ] All buttons are comfortably tappable one-handed (48dp minimum).
- [ ] Both light and dark mode are legible.

## Privacy

- [ ] Settings › Privacy loads and describes camera, photo, and diagnostics
      handling.
- [ ] Photos taken in the app do **not** appear in the system camera roll.
- [ ] Console/logcat during a full session contains no item names, notes, photo
      paths, or QR tokens.

## Devices

Cover at least:

- [ ] One current-generation Android device.
- [ ] One lower-spec / older Android device.
- [ ] One physical iOS device. **Blocked** — see
      [known limitations](known-limitations.md).

## Automated coverage

`npm test` covers, without needing a device:

- Repository CRUD, referential integrity, transaction rollback, and a schema
  migration with data backfill, against real SQL.
- Search: name, category, tag, space, container, and short-code matching;
  location-match annotation; LIKE-wildcard escaping; live reflection of edits
  and deletes; a 10,000-item performance guard.
- Recognition contract: success, malformed body, unsupported version, timeout,
  offline, rate limit, low confidence, and unrecognized image — all resolving to
  a recoverable manual-entry state.
- Telemetry redaction: inventory content is stripped from event payloads.
