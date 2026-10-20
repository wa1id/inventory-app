#!/usr/bin/env bash
# Builds the app in the Release configuration for a device, unsigned and without the app keys,
# and checks what would ship (docs/RELEASE.md, "Release build"):
#
#   - the build succeeds with no warning from our own sources (App/, Packages/InventoryKit/Sources);
#   - the Release build settings are sane (whole module, -O, dSYM, no testability, dead-code
#     stripping, no DEBUG condition, arm64 only);
#   - the built Info.plist: identity, the version (above the last EAS build, 0.1.0 (15)), every
#     INV_* setting substituted (the app keys only reported as empty or set, never printed),
#     orientations, capabilities, URL schemes, ATS without local networking, the Quick Snap
#     shortcut, the launch screen, no key an App Store update must not add;
#   - PrivacyInfo.xcprivacy is in the app, well formed and declares what the code uses;
#   - the asset catalog carries the AppIcon and the AccentColor;
#   - the binary is arm64 only, iOS 26 minimum, and holds no DEBUG-only code or strings (the demo,
#     the galleries, preview hosts, stand-in cameras, the UI-test identifier, the debug log sink).
#
#   scripts/release/check-release.sh          from this Linux checkout: takes a Mac build slot
#                                             (like scripts/mac.sh), syncs, runs the checks on the
#                                             Mac and copies the build log back to .build-logs/
#   bash scripts/release/check-release.sh     on the Mac, inside the synced native-ios folder
#
# Never set -x here: nothing secret is read, but keep the habit of scripts/release.
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
  MAC_HOST="${MAC_HOST:-macbook-pro-2}"
  KEY="$(printf '%s' "$NATIVE_DIR" | sha1sum | cut -c1-10)"
  # The same slots as scripts/mac.sh (one of MAC_SLOTS, held on fd 9 until this script exits).
  slots="${MAC_SLOTS:-4}" dir="$HOME/.cache/inventory-mac-slots" waited=0
  mkdir -p "$dir"
  while :; do
    got=0
    for i in $(seq 1 "$slots"); do
      exec 9>"$dir/slot-$i.lock"
      if flock -n 9; then got=1; break; fi
    done
    [ "$got" -eq 1 ] && break
    if [ "$waited" -eq 0 ]; then echo "[release] all $slots build slots are busy; waiting…" >&2; waited=1; fi
    sleep 5
  done
  mkdir -p "$NATIVE_DIR/.build-logs"
  status=0
  "$NATIVE_DIR/scripts/mac.sh" shell "bash scripts/release/check-release.sh" || status=$?
  scp -q "$MAC_HOST:inventory-native/$KEY/native-ios/.build-logs/release-build.log" "$NATIVE_DIR/.build-logs/release-build.log" 2>/dev/null \
    && echo "[release] build log: $NATIVE_DIR/.build-logs/release-build.log"
  exit "$status"
fi

# ---------------------------------------------------------------------------------------------
# On the Mac.
# ---------------------------------------------------------------------------------------------
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$NATIVE_DIR"
DERIVED="$(cd .. && pwd)/ReleaseDerivedData"
LOG="$NATIVE_DIR/.build-logs/release-build.log"
mkdir -p "$(dirname "$LOG")"
failures=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

echo "== xcodegen"
xcodegen generate --quiet

echo "== Release build (generic/platform=iOS, unsigned, app keys forced empty)"
# The keys are forced empty on the command line, which outranks Config/Secrets.xcconfig, so this
# checks the build an archive would make if Secrets.xcconfig were missing.
build_status=0
xcodebuild -project Inventory.xcodeproj -scheme Inventory -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO INV_RECOGNITION_KEY= INV_SYNC_KEY= \
  clean build >"$LOG" 2>&1 || build_status=$?
if [ "$build_status" -ne 0 ]; then
  grep -E "error:|\*\* BUILD" "$LOG" | head -40 || true
  bad "xcodebuild failed with exit $build_status (log: $LOG)"
  exit 1
fi
ok "BUILD SUCCEEDED (log: $LOG)"

ours="$(grep -E "warning: " "$LOG" | grep -E "/native-ios/(App|Packages/InventoryKit/Sources)/" | sort -u || true)"
if [ -n "$ours" ]; then
  printf '%s\n' "$ours" | head -40
  bad "warnings in our sources: $(printf '%s\n' "$ours" | wc -l | tr -d ' ')"
else
  ok "no warnings in App/ or Packages/InventoryKit/Sources/"
fi
others="$(grep -E "warning: " "$LOG" | grep -vE "/native-ios/(App|Packages/InventoryKit/Sources)/" | sort -u || true)"
if [ -n "$others" ]; then
  echo "note: $(printf '%s\n' "$others" | wc -l | tr -d ' ') warning(s) outside our sources:"
  printf '%s\n' "$others" | sed 's/^/      /' | head -20
fi

echo "== Release build settings (target Inventory)"
xcodebuild -project Inventory.xcodeproj -target Inventory -configuration Release -showBuildSettings \
  -sdk iphoneos 2>/dev/null >"$DERIVED/release-settings.txt"
setting() { awk -F' = ' -v k="$1" '$1 ~ "^ *"k"$" {print $2; exit}' "$DERIVED/release-settings.txt"; }
expect_setting() {
  local name="$1" want="$2" got
  got="$(setting "$name")"
  if [ "$got" = "$want" ]; then ok "$name = $got"; else bad "$name = '$got' (want '$want')"; fi
}
expect_setting SWIFT_COMPILATION_MODE wholemodule
expect_setting SWIFT_OPTIMIZATION_LEVEL -O
expect_setting DEBUG_INFORMATION_FORMAT dwarf-with-dsym
expect_setting ENABLE_TESTABILITY NO
expect_setting DEAD_CODE_STRIPPING YES
expect_setting ENABLE_NS_ASSERTIONS NO
expect_setting VALIDATE_PRODUCT YES
expect_setting ONLY_ACTIVE_ARCH NO
expect_setting ARCHS arm64
expect_setting STRIP_INSTALLED_PRODUCT YES
expect_setting SWIFT_STRICT_CONCURRENCY complete
expect_setting SWIFT_VERSION 6.0
expect_setting IPHONEOS_DEPLOYMENT_TARGET 26.0
expect_setting TARGETED_DEVICE_FAMILY 1,2
expect_setting PRODUCT_BUNDLE_IDENTIFIER com.wystudio.inventory
expect_setting DEVELOPMENT_TEAM 4BQ3BX3UHK
expect_setting CODE_SIGN_STYLE Automatic
# The version is project.yml's; it must be above the last EAS build, 0.1.0 (15) (DECISIONS U1).
MARKETING="$(setting MARKETING_VERSION)" BUILD="$(setting CURRENT_PROJECT_VERSION)"
if [ "$(printf '%s\n%s\n' 0.1.0 "$MARKETING" | sort -V | tail -1)" = "$MARKETING" ] && [ "$MARKETING" != 0.1.0 ]; then
  ok "MARKETING_VERSION = $MARKETING (above 0.1.0)"
else
  bad "MARKETING_VERSION = '$MARKETING' (must be above the last EAS version 0.1.0)"
fi
if [[ "$BUILD" =~ ^[0-9]+$ ]] && [ "$BUILD" -ge 16 ]; then ok "CURRENT_PROJECT_VERSION = $BUILD (above 15)"; else bad "CURRENT_PROJECT_VERSION = '$BUILD' (must be above the last EAS build 15)"; fi
export MARKETING BUILD
conditions="$(setting SWIFT_ACTIVE_COMPILATION_CONDITIONS)"
if printf ' %s ' "$conditions" | grep -qw DEBUG; then bad "SWIFT_ACTIVE_COMPILATION_CONDITIONS has DEBUG ('$conditions')"; else ok "SWIFT_ACTIVE_COMPILATION_CONDITIONS = '$conditions' (no DEBUG)"; fi
defines="$(setting GCC_PREPROCESSOR_DEFINITIONS)"
if printf ' %s ' "$defines" | grep -q 'DEBUG=1'; then bad "GCC_PREPROCESSOR_DEFINITIONS has DEBUG=1"; else ok "GCC_PREPROCESSOR_DEFINITIONS has no DEBUG=1"; fi
plistdefs="$(setting INFOPLIST_PREPROCESSOR_DEFINITIONS)"
if [ -z "$plistdefs" ]; then ok "INFOPLIST_PREPROCESSOR_DEFINITIONS empty (no Debug-only Info.plist keys)"; else bad "INFOPLIST_PREPROCESSOR_DEFINITIONS = '$plistdefs'"; fi

APP="$DERIVED/Build/Products/Release-iphoneos/Inventory.app"
echo "== Built app: $APP"
[ -d "$APP" ] || { bad "no Inventory.app"; exit 1; }
[ -d "$DERIVED/Build/Products/Release-iphoneos/Inventory.app.dSYM" ] && ok "Inventory.app.dSYM built" || bad "no dSYM"

echo "== Info.plist, privacy manifest and asset catalog"
/usr/bin/python3 - "$APP" <<'PY' || failures=$((failures + 1))
import plistlib, sys, os, subprocess, json
app = sys.argv[1]
failed = 0
def ok(m): print(f"ok    {m}")
def bad(m):
    global failed
    failed += 1
    print(f"FAIL  {m}")
def expect(name, got, want):
    (ok if got == want else bad)(f"{name} = {got!r}" + ("" if got == want else f" (want {want!r})"))

with open(os.path.join(app, "Info.plist"), "rb") as f:
    info = plistlib.load(f)

def walk(value, path=""):
    if isinstance(value, dict):
        for k, v in value.items(): yield from walk(v, f"{path}.{k}" if path else k)
    elif isinstance(value, list):
        for i, v in enumerate(value): yield from walk(v, f"{path}[{i}]")
    else:
        yield path, value
unsubstituted = [p for p, v in walk(info) if isinstance(v, str) and "$(" in v]
(bad if unsubstituted else ok)(f"no unsubstituted $(…) values {unsubstituted if unsubstituted else ''}".strip())

expect("CFBundleIdentifier", info.get("CFBundleIdentifier"), "com.wystudio.inventory")
expect("CFBundleDisplayName", info.get("CFBundleDisplayName"), "Inventory")
expect("CFBundleName", info.get("CFBundleName"), "Inventory")
expect("CFBundleShortVersionString", info.get("CFBundleShortVersionString"), os.environ["MARKETING"])
expect("CFBundleVersion", info.get("CFBundleVersion"), os.environ["BUILD"])
expect("CFBundleDevelopmentRegion", info.get("CFBundleDevelopmentRegion"), "en")
expect("MinimumOSVersion", info.get("MinimumOSVersion"), "26.0")
expect("UIDeviceFamily", info.get("UIDeviceFamily"), [1, 2])
expect("UIRequiredDeviceCapabilities", info.get("UIRequiredDeviceCapabilities"), ["arm64"])
expect("LSRequiresIPhoneOS", info.get("LSRequiresIPhoneOS"), True)
expect("ITSAppUsesNonExemptEncryption", info.get("ITSAppUsesNonExemptEncryption"), False)
expect("UISupportedInterfaceOrientations", info.get("UISupportedInterfaceOrientations"),
       ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"])
expect("UISupportedInterfaceOrientations~ipad", sorted(info.get("UISupportedInterfaceOrientations~ipad", [])),
       sorted(["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
               "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]))
schemes = [s for t in info.get("CFBundleURLTypes", []) for s in t.get("CFBundleURLSchemes", [])]
expect("CFBundleURLSchemes", schemes, ["inventory", "com.wystudio.inventory"])
expect("NSAppTransportSecurity", info.get("NSAppTransportSecurity"), {"NSAllowsArbitraryLoads": False})
expect("UILaunchScreen", info.get("UILaunchScreen"), {})
expect("UIApplicationSceneManifest", info.get("UIApplicationSceneManifest"), {"UIApplicationSupportsMultipleScenes": False})
expect("NSCameraUsageDescription", info.get("NSCameraUsageDescription"),
       "Inventory uses the camera so you can photograph items you are adding and scan QR labels on your containers.")
expect("NSPhotoLibraryUsageDescription", info.get("NSPhotoLibraryUsageDescription"),
       "Inventory can import a photo from your library to illustrate an item you are adding.")
expect("UIApplicationShortcutItems", info.get("UIApplicationShortcutItems"), [{
    "UIApplicationShortcutItemType": "com.wystudio.inventory.quickSnap",
    "UIApplicationShortcutItemTitle": "Quick Snap",
    "UIApplicationShortcutItemIconSymbolName": "camera",
}])
for absent in ["UIBackgroundModes", "UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace",
               "UIDesignRequiresCompatibility", "UIRequiresFullScreen", "NSMicrophoneUsageDescription",
               "NSFaceIDUsageDescription", "NSLocalNetworkUsageDescription", "NSUserActivityTypes",
               "UILaunchStoryboardName", "NSPhotoLibraryAddUsageDescription", "NSBonjourServices",
               "UIUserInterfaceStyle", "CFBundleSignature", "LSMinimumSystemVersion"]:
    (bad if absent in info else ok)(f"{absent} absent")

expect("INVAppEnvironment", info.get("INVAppEnvironment"), "production")
expect("INVRecognitionURL", info.get("INVRecognitionURL"), "https://server-wy-studio.vercel.app/api/recognize")
expect("INVRecognitionTimeoutMs", info.get("INVRecognitionTimeoutMs"), "15000")
expect("INVSyncURL", info.get("INVSyncURL"), "https://inventory-sync.wyachou95.workers.dev")
expect("INVSyncTimeoutMs", info.get("INVSyncTimeoutMs"), "60000")
expect("INVHouseholdOrigin", info.get("INVHouseholdOrigin"), "")
for key in ["INVRecognitionKey", "INVSyncKey"]:
    value = info.get(key)
    # Never print a key: only whether it is there, empty or set.
    if value is None: bad(f"{key} missing")
    elif value == "": ok(f"{key} present and empty (forced empty for this check)")
    else: bad(f"{key} is set; this check builds without the app keys")

icons = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
expect("CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName", icons.get("CFBundleIconName"), "AppIcon")
expect("NSAccentColorName", info.get("NSAccentColorName"), "AccentColor")

# The asset catalog: AppIcon (one 1024 universal source, no alpha) and AccentColor (light and dark).
car = os.path.join(app, "Assets.car")
if not os.path.exists(car):
    bad("Assets.car missing")
else:
    out = subprocess.run(["xcrun", "--sdk", "iphoneos", "assetutil", "--info", car], capture_output=True, text=True)
    try:
        assets = json.loads(out.stdout)
    except json.JSONDecodeError:
        assets = []
        bad("assetutil --info did not return JSON")
    names = {a.get("Name") for a in assets if isinstance(a, dict)}
    for name in ["AppIcon", "AccentColor", "Tape", "TapeInk", "SearchMark", "PipRing"]:
        (ok if name in names else bad)(f"Assets.car has {name}")
    accents = [a for a in assets if isinstance(a, dict) and a.get("Name") == "AccentColor"]
    appearances = sorted({a.get("Appearance", "any") for a in accents})
    (ok if len(accents) >= 2 else bad)(f"AccentColor appearances: {appearances}")
    opaque = [a for a in assets if isinstance(a, dict) and a.get("Name") == "AppIcon" and a.get("Opaque") is True]
    (ok if opaque else bad)(f"AppIcon renditions marked opaque: {len(opaque)}")

# The privacy manifest at the bundle root, plus any shipped by the packages' resource bundles.
manifest_path = os.path.join(app, "PrivacyInfo.xcprivacy")
if not os.path.exists(manifest_path):
    bad("PrivacyInfo.xcprivacy is not in the app bundle")
else:
    lint = subprocess.run(["plutil", "-lint", manifest_path], capture_output=True, text=True)
    (ok if lint.returncode == 0 else bad)(f"plutil -lint PrivacyInfo.xcprivacy: {lint.stdout.strip() or lint.stderr.strip()}")
    with open(manifest_path, "rb") as f:
        manifest = plistlib.load(f)
    expect("NSPrivacyTracking", manifest.get("NSPrivacyTracking"), False)
    expect("NSPrivacyTrackingDomains", manifest.get("NSPrivacyTrackingDomains"), [])
    apis = {e["NSPrivacyAccessedAPIType"]: e["NSPrivacyAccessedAPITypeReasons"] for e in manifest.get("NSPrivacyAccessedAPITypes", [])}
    expect("NSPrivacyAccessedAPITypes", apis, {
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
    })
    collected = sorted(e["NSPrivacyCollectedDataType"] for e in manifest.get("NSPrivacyCollectedDataTypes", []))
    expect("NSPrivacyCollectedDataTypes", collected, sorted([
        "NSPrivacyCollectedDataTypePhotosorVideos",
        "NSPrivacyCollectedDataTypeOtherUserContent",
        "NSPrivacyCollectedDataTypeUserID",
        "NSPrivacyCollectedDataTypeDeviceID",
    ]))
    for e in manifest.get("NSPrivacyCollectedDataTypes", []):
        name = e["NSPrivacyCollectedDataType"]
        (ok if e.get("NSPrivacyCollectedDataTypeTracking") is False else bad)(f"{name}: not used for tracking")
        (ok if e.get("NSPrivacyCollectedDataTypePurposes") == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"] else bad)(
            f"{name}: purpose {e.get('NSPrivacyCollectedDataTypePurposes')}")
for root, dirs, files in os.walk(app):
    for name in files:
        if name == "PrivacyInfo.xcprivacy" and root != app:
            print(f"note  dependency manifest: {os.path.relpath(os.path.join(root, name), app)}")

# Bundle contents: nothing a release must not carry.
for root, dirs, files in os.walk(app):
    for name in dirs + files:
        rel = os.path.relpath(os.path.join(root, name), app)
        if name.endswith((".xctest", ".swiftmodule", ".swiftinterface")) or name in ("embedded.mobileprovision.debug",) or "Preview" in name and name.endswith(".dylib") or name.endswith(".debug.dylib"):
            bad(f"unexpected in the bundle: {rel}")
sys.exit(1 if failed else 0)
PY

echo "== Binary"
BIN="$APP/Inventory"
archs="$(lipo -archs "$BIN")"
[ "$archs" = "arm64" ] && ok "architectures: $archs" || bad "architectures: $archs (want arm64 only)"
minos="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
[ "$minos" = "26.0" ] && ok "LC_BUILD_VERSION minos $minos" || bad "minos $minos (want 26.0)"
if otool -L "$BIN" | grep -qiE "XCTest|libXCTestSwiftSupport|Testing.framework|debug\.dylib|__preview"; then
  bad "links a test or preview library: $(otool -L "$BIN" | grep -iE 'XCTest|Testing|debug\.dylib|__preview' | tr -s ' ' | head -3)"
else
  ok "links no test or preview library"
fi
[ ! -e "$APP/Inventory.debug.dylib" ] && [ ! -e "$APP/__preview.dylib" ] && ok "no debug dylib or preview stub in the bundle" || bad "debug dylib or preview stub in the bundle"
strings -a "$BIN" >"$DERIVED/release-strings.txt"
# DEBUG-only code and its strings: the demo (ShellDemo and the area hooks), the galleries, the
# launch arguments they read, preview hosts, stand-in cameras and scanners, the UI-test identifier
# and the debug telemetry sink's prefix. Each is a type name (in Swift metadata) or a literal.
found=0
for marker in ShellDemo HomeDemo AccountDemo AddDemo CaptureDemo ItemDemo LabelsDemo PlacesDemo \
  DebugGallery ComponentsGallery MediaGallery FoundationGallery ComponentsFixtures ShellPreviewHost \
  AccountPreviewHost CaptureStandIn StandInQrScanner AppContainerPreviewData PreviewRegistry \
  demoRoute demoTab demoSeed demoArea demoState demoHousehold demoToast demoOpen demoOnboarding \
  galleryPage galleryAnchor galleryState debug-home-reselections '[telemetry]' '[telemetry:error]' \
  'Cordless drill' 'Tool chest' c0ffee00c0ffee00c0ffee00c0ffee00 0123456789abcdef0123456789abcdef; do
  if grep -qF -- "$marker" "$DERIVED/release-strings.txt"; then
    bad "binary contains '$marker'"
    found=$((found + 1))
  fi
done
[ "$found" -eq 0 ] && ok "binary holds none of the DEBUG-only markers"

echo
if [ "$failures" -eq 0 ]; then
  echo "[release] all checks passed"
else
  echo "[release] $failures check(s) failed"
  exit 1
fi
