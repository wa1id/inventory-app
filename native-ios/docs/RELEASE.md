# Release checklist: native 0.2.0 (16) to TestFlight

This is the release gate (spec 00-index M9). It walks through spec 02 §9 item by item, then covers the
Release build, the privacy manifest and label, the strings, the first-launch purge, the archive
and upload, and what is left for the App Store. Each row gives a status and the evidence behind it.
`DECISIONS.md` overrides the specs wherever they differ.

Status: **done** (checked and evidenced), **device** (can only be checked on a real phone, see §17),
**owner** (needs a decision or action outside this repo).

## How to re-run the checks

| What | Command | Where |
|---|---|---|
| Release build for a device, unsigned, without the app keys; build settings, Info.plist, privacy manifest, asset catalog and binary checks | `native-ios/scripts/release/check-release.sh` | Linux: takes a Mac build slot, syncs, runs on the Mac, copies `.build-logs/release-build.log` back |
| String Catalog strictness (catalog up to date, L10n members, no hard-coded copy) | `node native-ios/scripts/strings/check.mjs` (`--unused` also lists the keys no native code reads) | Linux (needs the repo's `node_modules`; in a worktree, `ln -s /home/walid/inventory-app/node_modules node_modules`) |
| The generator's and the check's own tests | `node --test 'native-ios/scripts/strings/*.test.mjs'` | Linux |
| The bundle the tests run in (Info.plist, privacy manifest, brand colours, Quick Snap) | `native-ios/scripts/mac.sh apptest -only-testing:InventoryTests/ReleaseBundleTests` | Mac simulator (Debug) |
| Archive and upload | `native-ios/scripts/release/archive-and-upload.sh` (§13) | Linux, then on the Mac |

The last `check-release.sh` run (wave 6 review) ended with `[release] all checks passed` and 98 `ok` lines. Its evidence is quoted below.

## 1. Identity and signing (02 §9.1)

| Item | Required | Status | Evidence |
|---|---|---|---|
| Bundle id | `com.wystudio.inventory`, the same as RN | done | `project.yml` `PRODUCT_BUNDLE_IDENTIFIER`; the built Info.plist shows `"CFBundleIdentifier" => "com.wystudio.inventory"` |
| Team | `4BQ3BX3UHK`, the team that signed the EAS builds | done | `project.yml` `DEVELOPMENT_TEAM: 4BQ3BX3UHK`, `CODE_SIGN_STYLE: Automatic`; check-release: `ok DEVELOPMENT_TEAM = 4BQ3BX3UHK`, `ok CODE_SIGN_STYLE = Automatic`. `ExportOptions.plist` `teamID` is the same |
| Product and display name | `Inventory` | done | Built Info.plist: `"CFBundleDisplayName" => "Inventory"`, `"CFBundleName" => "Inventory"` (`app.json` `name`) |
| App Store Connect record | app `6795274058` | done | The upload goes to the record that owns the bundle id in this team; nothing in the project names another app |
| Keychain access group | `<team>.com.wystudio.inventory`, derived exactly as in the RN build, so the recovery code and household session are adopted in place | done (device: §17) | Neither project asks for a keychain group: RN's `Inventory.entitlements` was `<dict/>` and ours is too. `ExpoCompatibleKeychain` never sets `kSecAttrAccessGroup` (no match in `Packages/` or `App/`). Xcode signs both the same way: `application-identifier` = App ID prefix + bundle id, and at most a derived `keychain-access-groups` of exactly that one group. So the default access group, where expo-secure-store wrote and where we read and write, is `4BQ3BX3UHK.com.wystudio.inventory` in both builds. The App ID record (created by EAS) is the same one, so the prefix is too. The simulator build's derived entitlements (`Inventory.app-Simulated.xcent`) show exactly `"application-identifier" => "4BQ3BX3UHK.com.wystudio.inventory"`. `archive-and-upload.sh` checks the archived app: `application-identifier` must be `4BQ3BX3UHK.com.wystudio.inventory`, `keychain-access-groups` must be absent or exactly that, and there must be no data-protection, app-groups, push or associated-domains entitlement. `AppTests/Adoption/ExpoKeychainInteropTests` runs expo-secure-store 57.0.1's own code against ours in both directions |

## 2. Version and build number (02 §9.2)

| Item | Required | Status | Evidence |
|---|---|---|---|
| Marketing version | above the last EAS version 0.1.0 | done | `MARKETING_VERSION: 0.2.0`; check-release: `ok MARKETING_VERSION = 0.2.0 (above 0.1.0)`, built `"CFBundleShortVersionString" => "0.2.0"` |
| Build number | above the last EAS build, 15 (from commit `13193e9b`, EAS remote version source) | done | `CURRENT_PROJECT_VERSION: 16`; built `"CFBundleVersion" => "16"`. `ExportOptions.plist` sets `manageAppVersionAndBuildNumber` to false, so a collision fails the upload instead of being renumbered silently |
| In-app version | Settings and Privacy show `CFBundleShortVersionString` | done | `AppConfig.appVersion` reads it; `ReleaseBundleTests` "every configuration key is substituted…" |

Each later TestFlight build needs a higher `CURRENT_PROJECT_VERSION` in `project.yml`. Both scripts read the version from the build settings and refuse a build number of 15 or lower.

## 3. Platform, devices, capabilities (02 §9.3)

| Item | Required | Status | Evidence |
|---|---|---|---|
| Deployment target | iOS 26.0 (decided). Devices on 16.4–25 keep the last RN build | done | check-release: `ok IPHONEOS_DEPLOYMENT_TARGET = 26.0`, `ok LC_BUILD_VERSION minos 26.0`, built `"MinimumOSVersion" => "26.0"` |
| Device family | iPhone and iPad, as RN (`supportsTablet`); dropping iPad is refused for an update | done | `ok TARGETED_DEVICE_FAMILY = 1,2`, built `"UIDeviceFamily" => [1, 2]` |
| Required capabilities | exactly `[arm64]`, as RN. An update must not add a requirement such as `still-camera` | done | built `"UIRequiredDeviceCapabilities" => ["arm64"]` |
| Architecture | arm64 only | done | `ok ARCHS = arm64`, `ok architectures: arm64` (`lipo -archs`) |
| Swift | Swift 6, complete strict concurrency | done | `ok SWIFT_VERSION = 6.0`, `ok SWIFT_STRICT_CONCURRENCY = complete` |
| Extensions | none (none existed) | done | `project.yml` has the app, its unit tests and UI tests only |

## 4. Info.plist, key by key (02 §9.4)

Source: `App/Resources/Info.plist`. It goes through the C preprocessor (`INFOPLIST_PREPROCESS`), so Debug alone can carry the local-network keys. The values below are from `plutil -p` of the built Release app.

| Key | RN | Native | Status |
|---|---|---|---|
| `CFBundleDisplayName` | `Inventory` | `Inventory` | done |
| `CFBundleDevelopmentRegion` | `$(DEVELOPMENT_LANGUAGE)` | `en` (`developmentLanguage: en`) | done |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.1.0` / `1` (EAS overrode it to 15) | `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` → `0.2.0` / `16` | done |
| `CFBundleURLTypes` | `inventory`, `com.wystudio.inventory` | the same, in that order | done (§6) |
| `ITSAppUsesNonExemptEncryption` | `false` | `false` (`=> 0`) | done |
| `LSRequiresIPhoneOS` | `true` | `true` | done |
| `LSMinimumSystemVersion`, `CFBundleSignature` | present | dropped (macOS-only and obsolete keys) | done (check-release asserts they are absent) |
| `NSAppTransportSecurity` | `NSAllowsArbitraryLoads` false, `NSAllowsLocalNetworking` true | Release: `{NSAllowsArbitraryLoads: false}` only. Debug adds `NSAllowsLocalNetworking` and `NSLocalNetworkUsageDescription`, for a `Local.xcconfig` that points at a LAN dev server (00-index §5, 09 Q21). Every production origin is https | done: check-release `ok NSAppTransportSecurity = {'NSAllowsArbitraryLoads': False}`, `ok NSLocalNetworkUsageDescription absent`, `ok INFOPLIST_PREPROCESSOR_DEFINITIONS empty`; `ReleaseBundleTests` "ATS…" checks the Debug side |
| `NSCameraUsageDescription` | "Inventory uses the camera so you can photograph items you are adding and scan QR labels on your containers." | identical | done |
| `NSPhotoLibraryUsageDescription` | "Inventory can import a photo from your library to illustrate an item you are adding." | identical. Kept for Save Image in the label share sheet (D-10) | done (device: §17) |
| `NSMicrophoneUsageDescription`, `NSFaceIDUsageDescription` | absent | absent | done |
| `NSUserActivityTypes` | expo-router handoff | dropped | done |
| `UILaunchStoryboardName` | `SplashScreen` | replaced by `UILaunchScreen` (§8) | done |
| `UIRequiredDeviceCapabilities` | `[arm64]` | `[arm64]` | done |
| `UIRequiresFullScreen` | `false` | omitted (the default, false): iPad multitasking stays on | done |
| `UISupportedInterfaceOrientations` | Portrait, PortraitUpsideDown | the same (iPhone is portrait-only) | done |
| `UISupportedInterfaceOrientations~ipad` | all four | all four | done |
| `UIUserInterfaceStyle` | `Automatic` | omitted (the default); light and dark | done |
| `UIStatusBarStyle`, `UIViewControllerBasedStatusBarAppearance` | present | dropped (SwiftUI owns the status bar) | done |
| `UIDesignRequiresCompatibility` | absent | absent: Liquid Glass stays on | done |
| `UIBackgroundModes`, `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` | absent | absent: the database and photos stay out of the Files app | done |
| `UIApplicationShortcutItems` | none | Quick Snap: type `com.wystudio.inventory.quickSnap` (`AppQuickAction.quickSnap`), title "Quick Snap" (`strings.tabs.quickSnapAction`), SF Symbol `camera` (U5) | done: `ReleaseBundleTests` "the Quick Snap Home Screen quick action…" compares it with the router's enum and the catalog |
| `UIApplicationSceneManifest` | none (AppDelegate window) | one scene (`UIApplicationSupportsMultipleScenes` false) | done |
| `INV*` configuration keys | `EXPO_PUBLIC_*` inlined in JS | Release: `INVAppEnvironment` production, `INVRecognitionURL` `https://server-wy-studio.vercel.app/api/recognize`, `INVSyncURL` `https://inventory-sync.wyachou95.workers.dev`, timeouts `15000` / `60000`, `INVHouseholdOrigin` empty (the parser's default `https://inventory.wystudio.be`), both keys from `Secrets.xcconfig` | done: check-release `ok no unsubstituted $(…) values` and one line per key |
| `Expo.plist` (expo-updates) | present | not carried over | done |

## 5. Entitlements (02 §9.5)

`App/Resources/Inventory.entitlements` is `<dict/>`, as RN's was. So there are no associated domains, app groups, keychain groups, push, iCloud or data-protection override. Every file keeps the default class `NSFileProtectionCompleteUntilFirstUserAuthentication`, and adoption waits for protected data (`AppBoot`, `BootGateTests` "nothing reads preferences, the keychain or the database before protected data is available"). Status: **done**. The archive check (§13) confirms what signing adds.

## 6. URL schemes and deep links (02 §9.6)

`inventory` is registered and can never be dropped, because printed labels encode `inventory://c/<32 hex>`. `com.wystudio.inventory` stays too: Expo added it, no code uses it, and keeping it is harmless (00-index §5). There are no universal links. Status: **done** (built Info.plist above; `ShellDeepLinkUITests`). Whether the system Camera opens printed RN labels in the native app is a device check (§17).

## 7. Background execution (02 §9.7)

There are no `UIBackgroundModes` and no `BGTaskScheduler`. Backup and photo sync run only while the app is active (U10). Status: **done** (check-release `ok UIBackgroundModes absent`).

## 8. App icon, launch screen, accent colour (02 §9.8, U2, U3)

| Item | Required | Status | Evidence |
|---|---|---|---|
| App icon | single-size 1024 universal PNG, no alpha. It is still RN's Expo placeholder art (U3: flag it) | done; **owner** for real artwork | `AppIcon.appiconset/icon.png` is byte-identical to `assets/icon.png` (1024×1024, 8-bit RGB, no alpha channel). `assetutil` on the built `Assets.car` shows `AppIcon` 1024×1024 renditions for phone and pad with `Opaque: True`; `"CFBundleIconName" => "AppIcon"` |
| Launch screen | the same background as RN's splash | done | RN's `SplashScreen.storyboard` was a plain `systemBackgroundColor` view (its image was missing). Ours is an empty `UILaunchScreen` dict, which is also system background (U3). `BootView`, the first view, draws `Color(.systemBackground)`, so nothing flashes |
| AccentColor | ink `#1C211E` light / `#E8ECE8` dark (U2) | done | `assetutil`: AccentColor components 0.110/0.129/0.118 (any) and 0.910/0.925/0.910 (dark); `"NSAccentColorName" => "AccentColor"`; `ReleaseBundleTests` "AccentColor is ink and Tape is the label yellow…" |
| Tape | `#FFD23F` / `#F4CA3C`, only where yellow means something | done | same test |

## 9. Privacy manifest (02 §9.9)

`App/Resources/PrivacyInfo.xcprivacy` is at the root of the built app. check-release reports `plutil -lint … PrivacyInfo.xcprivacy: OK`.

| Entry | Why | Evidence |
|---|---|---|
| `NSPrivacyTracking` false, no tracking domains | Nothing tracks: no ads, no analytics vendor, no cross-app identifiers | Release telemetry is `DebugLogSink`, which logs only under `#if DEBUG`. Its `[telemetry]` prefix is absent from the Release binary (check-release marker list) |
| UserDefaults `CA92.1` | The preferences: onboarding, recent places and categories, notice, backup time, household markers (U8, 02 §5.4) | `PreferenceStoring`, `LegacyImport`, `TemporaryCachePurge` |
| Disk space `E174.1` | The free-space check before a photo is written | `ImageStore.systemFreeSize` (`attributesOfFileSystem` → `.systemFreeSize`) |
| File timestamp `C617.1` | File metadata inside the container | `HouseholdPhotoCache.hasBytes` (`attributesOfItem`: size and type) |
| System boot time | not declared: no `systemUptime` or `mach_absolute_time`. Durations use `ContinuousClock`, which is not a required-reason API | grep of `App/` and `Packages/InventoryKit/Sources` |
| Collected data types | photos, other user content, user ID, device ID; each linked, not tracking, for app functionality only | see §16 |

Dependencies: GRDB 7.11.1 ships its own manifest, which declares no API and no data (`GRDB_GRDB.bundle/PrivacyInfo.xcprivacy` in the built app). libwebp-Xcode 1.6.0 ships none. Its compiled sources (`libwebp/src`, `libwebp/sharpyuv`) call none of the required-reason APIs: a grep for `stat`, `fstat`, `statfs`, `getattrlist`, `mach_absolute_time`, `NSUserDefaults`, `systemUptime` and `clock_gettime` found nothing. RN's aggregated manifest also declared 35F9.1, 0A2A.1, 3B52.1 and 85F4.1 for its own modules. Declaring less is allowed.
Both packages are compiled from source and linked statically into the app binary, so the app's
own manifest covers them. If App Store Connect's processing email still asks for a dependency
manifest (ITMS-91061), the fix is an entry in our manifest, not a package change (§17, item 12).

## 10. Build configurations and environment (02 §9.10), and the Release build

| Item | Status | Evidence |
|---|---|---|
| xcconfigs | done | `Config/Shared.xcconfig` holds the production URLs (the same as `eas.json` production) and the timeouts. `Debug/Preview/Release.xcconfig` set `INV_APP_ENV` (development/preview/production). `Secrets.xcconfig` is optional and gitignored (`native-ios/.gitignore`), with `Local.xcconfig` in Debug only. Preview uses the production endpoints (U1) |
| Release compiles for a device, unsigned, with no app keys | done | `xcodebuild -configuration Release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO INV_RECOGNITION_KEY= INV_SYNC_KEY=` → `ok BUILD SUCCEEDED`, `ok no warnings in App/ or Packages/InventoryKit/Sources/`. The only other warning is the toolchain's `appintentsmetadataprocessor … No AppIntents.framework dependency found` |
| Release build settings | done | `ok SWIFT_COMPILATION_MODE = wholemodule`, `ok SWIFT_OPTIMIZATION_LEVEL = -O`, `ok DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` (and `Inventory.app.dSYM` built), `ok ENABLE_TESTABILITY = NO`, `ok DEAD_CODE_STRIPPING = YES`, `ok ENABLE_NS_ASSERTIONS = NO`, `ok VALIDATE_PRODUCT = YES` (added to `project.yml`; XcodeGen's preset leaves it out), `ok ONLY_ACTIVE_ARCH = NO`, `ok STRIP_INSTALLED_PRODUCT = YES`, `ok SWIFT_ACTIVE_COMPILATION_CONDITIONS = '' (no DEBUG)`, `ok GCC_PREPROCESSOR_DEFINITIONS has no DEBUG=1` |
| No DEBUG-only code or strings in the binary | done | `strings` on the Release binary finds none of: the demo (`ShellDemo` and every `<Area>Demo`), the galleries, `ComponentsFixtures`, `ShellPreviewHost`, `AccountPreviewHost`, `CaptureStandIn`, `StandInQrScanner`, `AppContainerPreviewData`, `PreviewRegistry`, every `-demo…`/`-gallery…` launch argument, `debug-home-reselections`, `[telemetry]`, the seeded names (`Tool chest`, `Cordless drill`) and the demo label tokens. Previews are dropped by the compiler: no preview name is in the binary. Beyond that fixed list, check-release also fails on any type name in the binary shaped like DEBUG code (`…Demo…`, `…Gallery…`, `…StandIn…`, `…Fixture(s)…`, `…PreviewHost/Data/Record/Route/Body/Registry…`, `…Stub…`, `…Fake…`, `…Mock…`; only the camera's `CameraPreview…` layer views are allowed), so a demo or test double another track adds later is caught without editing the list: `ok binary holds no type named like a demo, gallery, preview host, stand-in or test double`. Run against the Debug simulator build's `Inventory.debug.dylib`, the same scan lists `AccountDemoServer`, `AccountPreviewHost`, `AddDemo`, `AppContainerPreviewData`, `CaptureStandInFeed`, `ComponentsFixtures`, `ComponentsGallery` and more, so it does detect them. Fixes made for this (each also listed in the track report): `HomeScreen.swift`'s previews called a DEBUG-only modifier, which broke the Release build, so they are now under `#if DEBUG`. `AppContainerPreview.swift`, `AccountDemoScenario.swift` and `AccountDemoServer.swift` in the package, plus `ShellPreviewHost`, `StandInQrScannerFeed` and the previews that use them (`DropZoneScreen`, `SpacesScreen`, `MainShell`, `RootView`, `ScreenFrame`, `SearchButton`, `RevokedOverlay`, `BottomBar`, `QrScannerView`), are now `#if DEBUG` |
| Links no test or preview library; no `*.debug.dylib` or `__preview.dylib` | done | `ok links no test or preview library`, `ok no debug dylib or preview stub in the bundle` |
| Empty keys (Secrets missing) | done | The parser reads an empty key as nil (`AppConfigTests`; `ReleaseBundleTests` "every configuration key is substituted…"). The clients then send no `x-inventory-key` (`RecognitionClientTests` "sends no x-inventory-key when the key is missing or empty", `SyncClientTests`). The servers answer 401, which reads as a failed suggestion banner (`RecognitionClientTests` "reads every non-2xx other than 429 as a server error…") or a backup error, `unauthorized` (`SyncClientTests`). Nothing crashes and no other screen is affected, exactly as RN without keys. An archive never ships like that: `archive-and-upload.sh` refuses to run without both keys and checks they reached the archived Info.plist |

## 11. RN/Expo workarounds not carried over (02 §10)

There is no lazy native-module loading, no Caches-then-move photo encoding, no `react-native-svg` label rasteriser, no `SystemUI.setBackgroundColorAsync`, no `Expo.plist` and no splash storyboard. The `wal_checkpoint(TRUNCATE)` before a snapshot is kept (02 §10). Status: **done**. These belong to earlier waves, and nothing in the project configuration brings them back.

## 12. App keys (`Config/Secrets.xcconfig`)

`native-ios/scripts/release/write-secrets.sh` writes the file on this Linux machine from the EAS production environment:

```sh
native-ios/scripts/release/write-secrets.sh            # needs `eas login`; runs from the repo root
```

- It runs `eas env:get production --variable-name EXPO_PUBLIC_RECOGNITION_KEY` (then `…_SYNC_KEY`) with `--scope project --format short --non-interactive`. It uses `eas` when that is installed, else `npx --yes eas-cli`; `EAS_BIN` overrides both. It parses the `NAME=value` line.
- It refuses a value that is missing, masked (`*****`, a sensitive or secret EAS variable), or that holds `//`, `$`, a quote, white space or a control character, any of which an xcconfig would cut or expand. It never prints a value. The mask is tested first, because eas prints `***** (This is a … env variable …)` in place of a withheld value. eas 20.5 answers an unknown variable with `Variable with name "…" not found` on stderr and exit 0 (`build/commands/env/get.js`); the script then shows that line (it never holds a value) before refusing. The variables are read with `--scope project`; an account-wide variable is not found that way, on purpose, because the account query does not filter by environment.
- It writes `INV_RECOGNITION_KEY` and `INV_SYNC_KEY` atomically with mode 600, then checks the file is gitignored. The output is `wrote …: INV_RECOGNITION_KEY set, INV_SYNC_KEY set`.
- Tried against a stand-in `eas` (`EAS_BIN`, `--out` into a scratch folder) for the good case and each refusal. It has not been run against EAS.

`scripts/mac.sh` (and so both release scripts) rsyncs `native-ios/`, `Config/Secrets.xcconfig` included, to this checkout's folder on the Mac. `mac.sh clean` deletes that folder.

## 13. Archive and upload

`native-ios/scripts/release/archive-and-upload.sh` (`--preflight` checks only; `--archive-only` stops before the upload):

1. On Linux it refuses to run unless `Config/Secrets.xcconfig` exists, is gitignored and sets both keys (values are never printed). Then it takes a Mac build slot and runs itself on the Mac through `scripts/mac.sh shell`.
2. On the Mac it checks the keys again. It sources `~/.appstoreconnect/beclean.env` silently for `ASC_KEY_ID` and `ASC_ISSUER_ID`; if `ASC_KEY_ID` is missing it falls back to the one `AuthKey_<id>.p8`. It requires `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`, runs `xcodegen` and reads the version (and refuses a build number of 15 or lower).
3. `xcodebuild archive` (Release, `generic/platform=iOS`, `-allowProvisioningUpdates -authenticationKeyPath … -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"`) into `~/inventory-native/<checkout>/release/`.
4. It checks the archived app: both keys set (reported only as set), version as built, `application-identifier` `4BQ3BX3UHK.com.wystudio.inventory`, `keychain-access-groups` absent or exactly that group, and no data-protection, app-groups, push or associated-domains entitlement. The entitlements come from `codesign -d --entitlements - --xml` (the older `:-` form prints a deprecation warning on macOS 15); if they cannot be read, the check fails instead of uploading.
5. `xcodebuild -exportArchive` with `scripts/release/ExportOptions.plist`: `method` app-store-connect, `destination` upload, `teamID` 4BQ3BX3UHK, `signingStyle` automatic, `uploadSymbols` true, `manageAppVersionAndBuildNumber` false. Logs go to `native-ios/.build-logs/release-archive.log` and `release-export.log` on the Mac.

It never uses `set -x`. Prerequisites (**owner**): the API key must have the App Manager or Admin role, so cloud signing can create the distribution certificate and profiles.

If the archive step fails on signing, these are the usual causes when `xcodebuild` runs over SSH (none can be checked without signing for real, which this track was told not to do):
- `errSecInternalComponent` or "unable to build chain": the Mac's login keychain is locked in the SSH session. Unlock it there first (`security unlock-keychain ~/Library/Keychains/login.keychain-db`, which asks for the password), then rerun.
- "Your team has no devices from which to generate a provisioning profile": with automatic signing, `xcodebuild archive` signs with an Apple Development profile first, and that needs one registered device in team 4BQ3BX3UHK. Register a tester's iPhone in the developer portal, then rerun. The export step re-signs for distribution either way.
- "No Accounts" or "Authentication failed": check that `ASC_KEY_ID` and `ASC_ISSUER_ID` in `beclean.env` belong to the team that owns app 6795274058. Both `~/.appstoreconnect` file names were checked on the Mac (`beclean.env`, `private_keys/AuthKey_<id>.p8`); their contents were not read. The script has been syntax-checked and its key check exercised on stand-in files; it has not archived or uploaded anything. Run `scripts/release/check-release.sh` first. After the upload, run `mac.sh clean` only once App Store Connect has accepted the build (it deletes the archive).

## 14. Strings: the String Catalog is strict (U9, 08 §2)

`node native-ios/scripts/strings/check.mjs` (its tests are in `check.test.mjs`, run by `node --test 'native-ios/scripts/strings/*.test.mjs'`):

1. **The catalog is current.** It runs `generate.mjs --check`: 754 keys, 742 paths, 1 native file, 4046 parity cases.
2. **Every `L10n` member used in `App/` exists.** It covers direct chains, backtick-escaped members (`` L10n.Onboarding.`continue` ``) and `typealias`/`.self` aliases, each scoped from its declaration. It resolves them against the accessor manifest `generate.mjs --manifest` writes; String API may follow a leaf.
3. **No hard-coded copy in `App/`.** It reports a string literal with letters in `Text`, `Label`, `Button`, `Toggle`, `TextField`, `Picker`, `Section`, `Menu`, `Link`, `NavigationLink`, `ContentUnavailableView`, `Tab` and the other titled controls. It also covers `.navigationTitle`, `.accessibilityLabel/Hint/Value`, `.accessibilityAction(named:)`, `.help`, `.alert`, `.confirmationDialog` and `.badge`, a `prompt:`, and our components' copy arguments (`label:`, `title:`, `message:`, `hint:`, `placeholder:`, …). It reads the whole argument, so copy on either side of `? :`, behind a `??` default or in a `+` concatenation is reported too, and a modifier counts wherever it is chained (`content.accessibilityHint("…")`); a literal inside a nested call or closure belongs to that call. `String(localized:)`, `LocalizedStringKey`, `LocalizedStringResource`, `NSLocalizedString` and `L10nRuntime` are reported anywhere outside InventoryStrings, package included. `#if DEBUG` code, `#Preview` bodies (the binary check shows Release drops them), `Text(verbatim:)`, reverse-DNS labels and a line ending in `// l10n-ok: <reason>` are exempt. The current result: **105 App files, no hard-coded copy, no unknown member, no exemption comment needed**. The earlier survey found literals only inside previews.
4. **Catalog keys no native code reads** (`--unused`; they stay in the catalog while RN still reads `strings.ts`): 7 of 754.

| Key | Why native does not read it |
|---|---|
| `common.findAnything` | RN `SearchField`'s default placeholder. Home's stock `.searchable` prompts with `home.searchPlaceholder`, the picker with `picker.filter` |
| `common.clearSearch` | RN `SearchField`'s clear button. The stock search field draws its own, labelled by the system |
| `picker.filterA11y` | RN `PlacePicker`'s filter label. The stock search field reads its prompt |
| `forms.moreDetailsA11y.expanded`, `.collapsed` | RN's "More details" button spoke its state through this label. The Add sheet's stock `DisclosureGroup` reads "More details" and VoiceOver adds the expanded or collapsed state itself |
| `permissions.libraryDeniedBody` | RN showed it when the image picker was refused. `PhotosPicker` runs out of process and needs no permission (08 §2.7) |
| `qr.shareFailed` | RN's toast when `Share.share` threw. The native share link falls back to sharing the label as text and has no failure path |

None are read only by DEBUG code.

The Info.plist copy (the usage strings, "Quick Snap") stays in Info.plist. The app is English-only, so no `InfoPlist.xcstrings` is needed yet. `ReleaseBundleTests` ties the shortcut title to `L10n.Tabs.quickSnapAction`.

## 15. First-launch purge (U11)

| Check | Status | Evidence |
|---|---|---|
| Purges only `Caches/{ImageManipulator,Camera,ImagePicker}` and `Caches/label-*.png` | done | `TemporaryCachePurge` (`directoryNames` and the `label-…png` filter); `TemporaryCachePurgeTests` "purges the three RN temporary directories and the label share pictures, nothing else". `household-photos`, `labels.png`, `label-X.jpg`, `my-label-1.png`, the URLSession cache, `Documents/item-photos` and the AsyncStorage manifest all survive |
| No `item-photos` sweep | done | The only file deletions in the sources are `ImageStore.deleteStoredPhotos` (named URIs whose rows are gone, RN parity), the partial-write cleanup in `ImageStore`, scratch folders in `DatabaseStore`, the app's own temporary files (the label share picture, a picked library photo once stored) and the purge. Only the purge lists a directory, and that directory is `Caches`; nothing enumerates `item-photos` |
| AsyncStorage directory left in place | done | `LegacyImport` only reads it; the purge test keeps `RCTAsyncLocalStorage_V1/manifest.json` |
| Once per install, after protected data and the gate inputs, in the background | done | marker `native.cachePurge.v1` (`TemporaryCachePurgeTests` "runs once per install"); `AppBoot` runs it detached at background priority after the database and session; `BootGateTests` "the legacy import runs before any preference read…" checks `household.loaded` comes before `caches.purge`, and only once |

The native label share picture goes to the temporary directory, not `Caches`, so the purge never meets one of ours.

## 16. App Store privacy label (notes for App Store Connect)

What leaves the phone, from the code (09 §8-9; `strings.privacy` describes the same to users):

| Flow | Data | Where it goes | Linked to the user | Kept |
|---|---|---|---|---|
| Photo suggestions | one item photo (WebP, real media type) and, when typed, the item name as a hint | our recognition endpoint on Vercel, which calls an AI provider with our own key | no: only the shared app key is sent, nothing per user or device | not stored by our server; the provider's own retention applies |
| Backup (opt-in, off by default) | the whole database snapshot (spaces, containers, items, notes, tags, categories) and every photo | the sync worker on Cloudflare (R2) | yes: stored under an account id derived from the recovery code, which is sent as a bearer token | the five most recent snapshots, plus photos until deleted |
| Household (opt-in, by joining with a code) | the inventory and photos this phone writes; the typed phone name; the device id and token the server issues | the household's home server behind `inventory.wystudio.be` | yes: per device token | while the household keeps them |
| Telemetry | nothing | nowhere: the Release sink discards every event, and no crash or analytics SDK is linked | – | – |

Matching manifest entries: `PhotosorVideos`, `OtherUserContent`, `UserID` and `DeviceID`. Each is linked, not used for tracking, and has the purpose App Functionality. For the label, answer **Data Used to Track You: none**, and under **Data Linked to You** list Photos or Videos, Other User Content, User ID and Device ID, purpose App Functionality only. Name and contact info, location, usage data, diagnostics, identifiers for advertising, purchases and browsing are **not collected**.

Consistency with RN (**owner**): RN only reached TestFlight, which needs no privacy label. Its aggregated manifest declared no collected data types, although RN sent the same photos and backups. If App Store Connect already holds answers made from that manifest ("Data Not Collected"), they must be corrected to the table above before an App Store submission. Two judgement calls remain, and the answers above take the conservative side:
- whether opt-in backup qualifies for Apple's optional-disclosure exception;
- whether the household server counts as collection by the developer (it runs on the developer's domain, so it is treated as such).

## 17. Device-only checks (before inviting external testers)

1. **Upgrade in place on a phone with RN 0.1.0 (15) and real data:** the inventory, photos, onboarding flag, recent places and categories, the dismissed notice and the last backup time are all there, with no onboarding again.
2. **Keychain adoption:** a phone paired by RN is still paired, and its backup still runs under the same recovery code (shown by Show recovery code). This proves the access group derivation and the expo-coordinate reads.
3. **Locked-launch safety:** after a reboot, before the first unlock, a prewarmed launch must not look unpaired or reset onboarding (02 §8 step 0).
4. **Rollback:** the RN TestFlight build installed over native still reads everything native wrote (02 §8 invariants).
5. **QR labels:** the system Camera opens a printed RN label `inventory://c/<token>` in the native app (cold and warm).
6. **Save Image** from the label share sheet writes to Photos, with the photo-library prompt and no crash (D-10).
7. **Camera:** the permission prompt shows the RN usage string; capture and Quick Snap work on a real camera (the simulator has none). Tap to focus works, and Quick Snap bursts do not exhaust memory.
8. **The Quick Snap Home Screen quick action** opens the camera, cold and warm.
9. **Recognition and backup with the production keys** (from `Secrets.xcconfig`): a suggestion arrives, and a backup and restore round-trips.
10. **iPad:** all four orientations, multitasking and Stage Manager windows, and the capture preview rotating correctly (U4).
11. **App icon and launch:** the icon renders on the Home Screen and in Settings (it is still the placeholder art), and the launch shows no white or black flash in either appearance.
12. **TestFlight processing:** the build passes App Store Connect validation (no ITMS-91053 missing-reason warning, no missing-icon or capability error) and shows as 0.2.0 (16).

## 18. What remains for the App Store after TestFlight (owner)

- **Screenshots** per required device class: iPhone 6.9" (1320×2868, e.g. iPhone 17 Pro Max; mac.sh's default simulator is the 6.3" 17 Pro) and iPad 13" (2064×2752; `DEVICE=ipad`, the iPad Pro 13-inch). `-demo YES` with `-demoRoute`/`-demoTab` gives every screen in a known state.
- **App Store metadata:** description, subtitle, keywords, category (Productivity), support URL, marketing URL and copyright. **A privacy policy URL is required**; the in-app notice is not one, and `strings.ts` still marks it "Owner to approve before release (#8)".
- **App privacy label:** review and enter §16.
- **Review notes:** everything works offline without an account. A household needs a household code, so give App Review one, or say the feature is optional. Backup creates an anonymous recovery code; recognition sends one photo to our service.
- **Account deletion (guideline 5.1.1(v)): a review risk.** Turning on backup creates a server-side backup under a recovery code, and the app has no way to delete it or turn backup off (RN parity; U10, no new features in v1). Decide before App Store review whether this counts as an account. If it does, add deletion (the worker would need a delete endpoint).
- **Export compliance:** `ITSAppUsesNonExemptEncryption` is false (HTTPS and Apple crypto only), so App Store Connect asks nothing.
- **Age rating:** answer the questionnaire. There is no objectionable content, no public user-generated content (a household shares only with its own phones), no messaging and no web browsing, so 4+ is expected.
- **Version for the store:** 0.2.0 is above everything shipped. Whether the App Store debut should be 1.0.0 is the owner's call: bump `MARKETING_VERSION`, and the build number keeps rising.
- **App icon:** real artwork, possibly an Icon Composer `.icon` for Liquid Glass (U3, 02 Q8).
- **Pricing, availability, content rights,** and the iPad requirement (it cannot be dropped later).

## 19. Exceptions and open items

- `check-release.sh` shows one warning outside our sources, the toolchain's `appintentsmetadataprocessor` "No AppIntents.framework dependency found". It is informational, and nothing in our code causes it.
- The Debug-only `NSLocalNetworkUsageDescription` copy lives in Info.plist, not in the String Catalog. It never ships.
