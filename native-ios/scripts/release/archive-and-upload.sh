#!/usr/bin/env bash
# Archives the Release app and uploads it to App Store Connect (TestFlight, app 6795274058), signed
# automatically in team 4BQ3BX3UHK with the App Store Connect API key on the Mac
# (docs/RELEASE.md, "Archive and upload").
#
#   scripts/release/archive-and-upload.sh              from this Linux checkout: checks the app keys,
#                                                      takes a Mac build slot, syncs this checkout to
#                                                      its folder on the Mac (scripts/mac.sh) and runs
#                                                      the archive and upload there
#   scripts/release/archive-and-upload.sh --preflight  only the checks (keys, API key files, version);
#                                                      archives nothing, uploads nothing
#   scripts/release/archive-and-upload.sh --archive-only  archive and check it, but do not upload
#
# On the Mac it runs xcodegen, `xcodebuild archive` (Release, generic/platform=iOS,
# -allowProvisioningUpdates with the API key), checks the archived app, then
# `xcodebuild -exportArchive` with scripts/release/ExportOptions.plist (app-store-connect, upload,
# symbols). The API key comes from ~/.appstoreconnect/beclean.env (ASC_KEY_ID, ASC_ISSUER_ID) and
# ~/.appstoreconnect/private_keys/AuthKey_<id>.p8 on the Mac.
#
# Secrets: Config/Secrets.xcconfig (written by scripts/release/write-secrets.sh) must exist with
# both keys set, or nothing runs. No key value, API key id or issuer id is ever printed, and this
# script never turns on tracing (set -x).
set -euo pipefail
set +x

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$NATIVE_DIR/Config/Secrets.xcconfig"
MODE="upload"
ON_MAC=0
for arg in "$@"; do
  case "$arg" in
    --preflight) MODE="preflight" ;;
    --archive-only) MODE="archive" ;;
    --on-mac) ON_MAC=1 ;;
    *) echo "usage: $0 [--preflight | --archive-only]" >&2; exit 2 ;;
  esac
done

fail() { echo "[release] $*" >&2; exit 1; }

# Both keys present and non-empty in Secrets.xcconfig. Prints nothing about their values.
check_secrets() {
  [ -f "$SECRETS" ] || fail "Config/Secrets.xcconfig is missing; write it with scripts/release/write-secrets.sh"
  local name value
  for name in INV_RECOGNITION_KEY INV_SYNC_KEY; do
    value="$(awk -v k="$name" '
      { line = $0; sub(/\/\/.*/, "", line) }
      line ~ "^[[:space:]]*" k "[[:space:]]*=" { sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", line); sub(/[[:space:]]+$/, "", line); v = line }
      END { printf "%s", v }' "$SECRETS")"
    [ -n "$value" ] || fail "$name is missing or empty in Config/Secrets.xcconfig; rewrite it with scripts/release/write-secrets.sh"
  done
  value=""
  echo "[release] Config/Secrets.xcconfig: INV_RECOGNITION_KEY set, INV_SYNC_KEY set"
}

if [ "$ON_MAC" -eq 0 ] && [ "$(uname -s)" != "Darwin" ]; then
  check_secrets
  git -C "$NATIVE_DIR" check-ignore -q Config/Secrets.xcconfig || fail "Config/Secrets.xcconfig is not gitignored"
  if [ "$MODE" != "preflight" ]; then
    # The same build slots as scripts/mac.sh (held on fd 9 until this script exits).
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
  fi
  flag=""
  case "$MODE" in preflight) flag="--preflight" ;; archive) flag="--archive-only" ;; esac
  # mac.sh shell syncs native-ios (Config/Secrets.xcconfig included) to this checkout's folder.
  exec "$NATIVE_DIR/scripts/mac.sh" shell "bash scripts/release/archive-and-upload.sh --on-mac $flag"
fi

# ---------------------------------------------------------------------------------------------
# On the Mac.
# ---------------------------------------------------------------------------------------------
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$NATIVE_DIR"
check_secrets

ASC_DIR="$HOME/.appstoreconnect"
[ -f "$ASC_DIR/beclean.env" ] || fail "$ASC_DIR/beclean.env is missing on the Mac"
# Read into this shell only (not exported to child processes beyond what the file itself exports);
# the values reach xcodebuild only through the flags below, and nothing is echoed.
# shellcheck disable=SC1091
. "$ASC_DIR/beclean.env" >/dev/null 2>&1
set +x
if [ -z "${ASC_KEY_ID:-}" ]; then
  # Fall back to the one key file's name (AuthKey_<id>.p8).
  keys=("$ASC_DIR"/private_keys/AuthKey_*.p8)
  [ "${#keys[@]}" -eq 1 ] && [ -f "${keys[0]}" ] || fail "ASC_KEY_ID is not set by beclean.env and there is not exactly one AuthKey_*.p8"
  ASC_KEY_ID="$(basename "${keys[0]}" .p8)"
  ASC_KEY_ID="${ASC_KEY_ID#AuthKey_}"
fi
[ -n "${ASC_ISSUER_ID:-}" ] || fail "ASC_ISSUER_ID is not set by $ASC_DIR/beclean.env"
ASC_KEY_PATH="${ASC_KEY_PATH:-$ASC_DIR/private_keys/AuthKey_$ASC_KEY_ID.p8}"
[ -f "$ASC_KEY_PATH" ] || fail "the App Store Connect API key file named by ASC_KEY_ID is missing in $ASC_DIR/private_keys"
echo "[release] App Store Connect API key: found (id and issuer not shown)"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

command -v xcodegen >/dev/null || fail "xcodegen is not installed on the Mac"
xcodegen generate --quiet
settings="$(xcodebuild -project Inventory.xcodeproj -target Inventory -configuration Release -showBuildSettings 2>/dev/null)"
MARKETING="$(printf '%s\n' "$settings" | awk -F' = ' '/^ *MARKETING_VERSION =/{print $2; exit}')"
BUILD="$(printf '%s\n' "$settings" | awk -F' = ' '/^ *CURRENT_PROJECT_VERSION =/{print $2; exit}')"
version="$MARKETING ($BUILD)"
export MARKETING BUILD
# App Store Connect refuses a build number it has seen; the last EAS upload was 0.1.0 (15).
[[ "$BUILD" =~ ^[0-9]+$ ]] && [ "$BUILD" -ge 16 ] || fail "CURRENT_PROJECT_VERSION '$BUILD' must be above the last EAS build (15)"
echo "[release] version $version, bundle com.wystudio.inventory, team 4BQ3BX3UHK"
if [ "$MODE" = "preflight" ]; then
  echo "[release] preflight passed; nothing archived or uploaded"
  exit 0
fi

WORK="$(cd .. && pwd)/release"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$WORK/Inventory-$STAMP.xcarchive"
EXPORT="$WORK/export-$STAMP"
LOGS="$NATIVE_DIR/.build-logs"
mkdir -p "$WORK" "$LOGS"

echo "[release] archiving to $ARCHIVE (log: $LOGS/release-archive.log)"
status=0
xcodebuild -project Inventory.xcodeproj -scheme Inventory -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK/DerivedData" "${AUTH[@]}" \
  archive >"$LOGS/release-archive.log" 2>&1 || status=$?
if [ "$status" -ne 0 ]; then
  grep -E "error:|\*\* ARCHIVE" "$LOGS/release-archive.log" | head -40 >&2 || true
  fail "xcodebuild archive failed with exit $status"
fi
echo "[release] ** ARCHIVE SUCCEEDED **"

# The archived app: the keys made it in (reported as set, never printed), the version, and the
# signing identity the keychain adoption depends on (application-identifier = team + bundle id,
# no other keychain group, no data-protection override; docs/RELEASE.md).
APP="$ARCHIVE/Products/Applications/Inventory.app"
/usr/bin/python3 - "$APP" <<'PY' || fail "the archived app failed its checks"
import plistlib, subprocess, sys, os
app = sys.argv[1]
info = plistlib.load(open(os.path.join(app, "Info.plist"), "rb"))
bad = 0
for key in ("INVRecognitionKey", "INVSyncKey"):
    if info.get(key):
        print(f"ok    {key} set")
    else:
        print(f"FAIL  {key} empty in the archived Info.plist"); bad += 1
version = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
want = (os.environ["MARKETING"], os.environ["BUILD"])
print(("ok   " if version == want else "FAIL ") + f" version {version[0]} ({version[1]})")
bad += version != want
out = subprocess.run(["codesign", "-d", "--entitlements", ":-", app], capture_output=True)
try:
    ents = plistlib.loads(out.stdout) if out.stdout.strip() else {}
except Exception:
    ents = {}
appid = ents.get("application-identifier")
print(("ok   " if appid == "4BQ3BX3UHK.com.wystudio.inventory" else "FAIL ") + f" application-identifier {appid}")
bad += appid != "4BQ3BX3UHK.com.wystudio.inventory"
# Xcode derives keychain-access-groups from the profile as [application-identifier] for an app with
# no Keychain Sharing, exactly as it did for the EAS build; the default group must stay that one.
groups = ents.get("keychain-access-groups")
if groups in (None, ["4BQ3BX3UHK.com.wystudio.inventory"]):
    print(f"ok    keychain-access-groups {groups if groups else 'absent'} (default group = application-identifier)")
else:
    print(f"FAIL  keychain-access-groups {groups}: the default access group would change"); bad += 1
for key in ("com.apple.developer.default-data-protection", "com.apple.security.application-groups", "aps-environment", "com.apple.developer.associated-domains"):
    if key in ents:
        print(f"FAIL  unexpected entitlement {key}"); bad += 1
    else:
        print(f"ok    no {key} entitlement")
sys.exit(1 if bad else 0)
PY

if [ "$MODE" = "archive" ]; then
  echo "[release] --archive-only: not uploading. Archive: $ARCHIVE"
  exit 0
fi

echo "[release] exporting and uploading to App Store Connect (log: $LOGS/release-export.log)"
status=0
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$NATIVE_DIR/scripts/release/ExportOptions.plist" \
  -exportPath "$EXPORT" "${AUTH[@]}" >"$LOGS/release-export.log" 2>&1 || status=$?
if [ "$status" -ne 0 ]; then
  grep -E "error:|Error|\*\* EXPORT" "$LOGS/release-export.log" | head -40 >&2 || true
  fail "xcodebuild -exportArchive failed with exit $status"
fi
grep -E "Upload succeeded|Uploaded|\*\* EXPORT SUCCEEDED \*\*" "$LOGS/release-export.log" | head -5 || true
echo "[release] uploaded $version; it appears in TestFlight once App Store Connect has processed it"
