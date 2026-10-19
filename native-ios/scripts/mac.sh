#!/usr/bin/env bash
# Build, test and run the native iOS app on the Mac over SSH.
#
# The code lives on this machine; the Mac only compiles it. Each checkout
# (including git worktrees) syncs to its own folder on the Mac, keyed by its
# local path, so parallel checkouts never share build output or simulators.
#
#   scripts/mac.sh test [swift-test args]   swift test for Packages/InventoryKit (macOS host, no simulator)
#   scripts/mac.sh build                    xcodegen + xcodebuild the app for the iOS simulator
#   scripts/mac.sh apptest [xcodebuild args] run the app-hosted InventoryTests on this checkout's simulator
#   scripts/mac.sh run [out.png]            build, install and launch on the simulator, then save a screenshot
#   scripts/mac.sh screenshot [out.png]     screenshot the running simulator
#   scripts/mac.sh shell '<command>'        run a command in this checkout's folder on the Mac
#   scripts/mac.sh clean                    delete this checkout's folder and simulator on the Mac
#
# Full logs go to native-ios/.build-logs/<command>.log; stdout gets a filtered summary.
set -euo pipefail

MAC_HOST="${MAC_HOST:-macbook-pro-2}"
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="$(printf '%s' "$NATIVE_DIR" | sha1sum | cut -c1-10)"
REMOTE_ROOT="inventory-native/$KEY"
REMOTE_NATIVE="$REMOTE_ROOT/native-ios"
SIM_NAME="inventory-$KEY"
SIM_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
SIM_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-3"
BUNDLE_ID="com.wystudio.inventory"
LOG_DIR="$NATIVE_DIR/.build-logs"
mkdir -p "$LOG_DIR"

remote() {
  # Login-shell PATH so Homebrew tools (xcodegen, xcbeautify) resolve.
  ssh -o BatchMode=yes "$MAC_HOST" "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; set -o pipefail; $1"
}

sync_up() {
  remote "mkdir -p ~/$REMOTE_NATIVE"
  rsync -az --delete \
    --exclude '.build/' --exclude '.swiftpm/' --exclude 'DerivedData/' \
    --exclude '*.xcodeproj' --exclude '.build-logs/' \
    "$NATIVE_DIR/" "$MAC_HOST:$REMOTE_NATIVE/"
}

# Print errors, warnings from our own sources, and the result lines.
summarize() {
  grep -E "error:|warning: .*/(App|AppTests|Packages/InventoryKit/(Sources|Tests))/|✘|✔ Test run|Test run with|Executed [0-9]+ test|\*\* (BUILD|TEST) (SUCCEEDED|FAILED)|Testing failed|failed \(|recorded an issue|Fatal error|error: fatalError" \
    | grep -v "^ld: warning" | awk '!seen[$0]++' | head -200 || true
}

run_logged() {
  local name="$1" cmd="$2" status=0
  remote "$cmd" >"$LOG_DIR/$name.log" 2>&1 || status=$?
  summarize <"$LOG_DIR/$name.log"
  if [ "$status" -eq 0 ]; then echo "[$name] OK (log: $LOG_DIR/$name.log)"; else echo "[$name] FAILED with exit $status (log: $LOG_DIR/$name.log)"; fi
  return "$status"
}

generate='cd ~/'"$REMOTE_NATIVE"' && xcodegen generate --quiet'

ensure_sim='udid=$(xcrun simctl list devices -j | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)[\"devices\"]; print(next((x[\"udid\"] for r in d.values() for x in r if x[\"name\"]==\"'"$SIM_NAME"'\" and x[\"isAvailable\"]), \"\"))"); if [ -z "$udid" ]; then udid=$(xcrun simctl create '"$SIM_NAME $SIM_TYPE $SIM_RUNTIME"'); fi'

xcbuild_app() {
  # $1 = action (build/test), $2 = destination, $3 = extra args
  echo "$generate && xcodebuild -project Inventory.xcodeproj -scheme Inventory -configuration Debug -destination \"$2\" -derivedDataPath ~/$REMOTE_ROOT/DerivedData CODE_SIGNING_ALLOWED=NO $3 $1"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  test)
    sync_up
    run_logged test "cd ~/$REMOTE_NATIVE/Packages/InventoryKit && swift test --scratch-path ~/$REMOTE_ROOT/spm-build $*"
    ;;
  build)
    sync_up
    run_logged build "$(xcbuild_app build 'generic/platform=iOS Simulator' '')"
    ;;
  apptest)
    sync_up
    run_logged apptest "$ensure_sim && $(xcbuild_app test 'id=$udid' "$*")"
    ;;
  run)
    out="${1:-$LOG_DIR/screenshot.png}"
    sync_up
    run_logged run "$ensure_sim && $(xcbuild_app build 'id=$udid' '') && { xcrun simctl boot \$udid 2>/dev/null || true; } && xcrun simctl bootstatus \$udid -b >/dev/null && xcrun simctl install \$udid ~/$REMOTE_ROOT/DerivedData/Build/Products/Debug-iphonesimulator/Inventory.app && { xcrun simctl terminate \$udid $BUNDLE_ID 2>/dev/null || true; } && xcrun simctl launch \$udid $BUNDLE_ID && sleep \${RUN_SETTLE_SECONDS:-4} && xcrun simctl io \$udid screenshot ~/$REMOTE_ROOT/screenshot.png"
    scp -q "$MAC_HOST:$REMOTE_ROOT/screenshot.png" "$out" && echo "screenshot: $out"
    ;;
  screenshot)
    out="${1:-$LOG_DIR/screenshot.png}"
    remote "$ensure_sim && xcrun simctl io \$udid screenshot ~/$REMOTE_ROOT/screenshot.png" >/dev/null
    scp -q "$MAC_HOST:$REMOTE_ROOT/screenshot.png" "$out" && echo "screenshot: $out"
    ;;
  shell)
    sync_up
    remote "$ensure_sim; cd ~/$REMOTE_NATIVE && $*"
    ;;
  clean)
    remote "$ensure_sim; xcrun simctl shutdown \$udid 2>/dev/null; xcrun simctl delete \$udid 2>/dev/null; rm -rf ~/$REMOTE_ROOT" || true
    echo "removed ~/$REMOTE_ROOT and simulator $SIM_NAME on $MAC_HOST"
    ;;
  *)
    sed -n '2,17p' "${BASH_SOURCE[0]}"
    ;;
esac
