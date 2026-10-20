# Build configuration

| File | Committed | Purpose |
|---|---|---|
| `Shared.xcconfig` | yes | Endpoints and timeouts shared by every configuration (the `eas.json` production values) |
| `Debug.xcconfig`, `Preview.xcconfig`, `Release.xcconfig` | yes | Per-configuration environment name (`development`, `preview`, `production`). `Debug.xcconfig` also turns on the Debug-only Info.plist keys (below) |
| `Secrets.xcconfig` | **no** (gitignored) | `INV_RECOGNITION_KEY` and `INV_SYNC_KEY`, the shared app keys sent as `x-inventory-key` |
| `Local.xcconfig` | **no** (gitignored) | Debug-only developer overrides, e.g. a LAN recognition server |

The values reach the app through custom Info.plist keys (`App/Resources/Info.plist`, `INV…`), which
`AppConfig` parses. Everything here ships inside the app and is public by design, including the keys.
Still, never commit, print or paste them.

## The app keys (`Secrets.xcconfig`)

Write it from the EAS production environment with the release script. It runs `eas env:get` and
never prints a value:

```sh
native-ios/scripts/release/write-secrets.sh
```

The file it writes:

```
INV_RECOGNITION_KEY = <value>
INV_SYNC_KEY = <value>
```

Without it the app still builds. Recognition and sync requests then go out without the key and the
servers answer 401, which the app shows as a failed suggestion or a failed backup.
`scripts/release/archive-and-upload.sh` refuses to archive without both keys. See
`docs/RELEASE.md`, §12-13.

## Debug-only Info.plist keys

`App/Resources/Info.plist` goes through the C preprocessor (`INFOPLIST_PREPROCESS` in
`project.yml`). `Debug.xcconfig` defines `INV_DEBUG_LOCAL_NETWORK=1` in
`INFOPLIST_PREPROCESSOR_DEFINITIONS`, which adds `NSAllowsLocalNetworking` and
`NSLocalNetworkUsageDescription` for a `Local.xcconfig` that points at a dev server on the LAN.
Preview and Release define nothing, so they only talk to https hosts.
`scripts/release/check-release.sh` checks this on the built Release app.
