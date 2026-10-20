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
#   scripts/mac.sh uitest [xcodebuild args]  run the InventoryUITests UI tests on this checkout's simulator
#   scripts/mac.sh run [out.png] [args...]  build, install and launch on the simulator (with launch args), then save a screenshot
#   scripts/mac.sh launch [out.png] [args...] relaunch the installed app with launch args (no build), then save a screenshot
#   scripts/mac.sh openurl <url> [out.png]  open a URL (deep link) in the simulator, then save a screenshot
#   scripts/mac.sh screenshot [out.png]     screenshot the running simulator
#   scripts/mac.sh shell '<command>'        run a command in this checkout's folder on the Mac
#   scripts/mac.sh clean                    delete this checkout's folder and simulator on the Mac
#
# run, launch and openurl honour APPEARANCE=light|dark and CONTENT_SIZE=<simctl content size,
# e.g. large, accessibility-extra-extra-extra-large>, and wait RUN_SETTLE_SECONDS (default 4).
# run and launch hand the app each launch argument as given (quote one that holds spaces or a
# `>`, e.g. -demoRoute 'container:Tool chest>containerEdit:Tool chest').
# test, build, apptest, uitest and run wait for one of MAC_SLOTS (default 4) build slots.
# DEVICE=ipad (iPad Pro 13-inch) or DEVICE=se (iPhone SE, 375x667 pt) runs apptest, uitest, run,
# launch, openurl and screenshot on a second simulator of that kind instead of the iPhone 17 Pro.
# Full logs go to native-ios/.build-logs/<command>.log; stdout gets a filtered summary.
set -euo pipefail

MAC_HOST="${MAC_HOST:-macbook-pro-2}"
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="$(printf '%s' "$NATIVE_DIR" | sha1sum | cut -c1-10)"
REMOTE_ROOT="inventory-native/$KEY"
REMOTE_NATIVE="$REMOTE_ROOT/native-ios"
SIM_NAME="inventory-$KEY"
SIM_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
case "${DEVICE:-}" in
  "") ;;
  ipad) SIM_NAME="$SIM_NAME-ipad"; SIM_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB" ;;
  se) SIM_NAME="$SIM_NAME-se"; SIM_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation" ;;
  *) echo "DEVICE must be ipad or se" >&2; exit 2 ;;
esac
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

# Compiles and test runs take one of MAC_SLOTS slots (default 4), so parallel checkouts don't
# swamp the Mac's memory. Every checkout runs on this machine, so the locks live here. The
# slot is held on fd 9 until this script exits.
take_slot() {
  local slots="${MAC_SLOTS:-4}" dir="$HOME/.cache/inventory-mac-slots" waited=0 i
  mkdir -p "$dir"
  while :; do
    for i in $(seq 1 "$slots"); do
      exec 9>"$dir/slot-$i.lock"
      if flock -n 9; then return 0; fi
    done
    if [ "$waited" -eq 0 ]; then echo "[mac] all $slots build slots are busy; waiting…" >&2; waited=1; fi
    sleep 5
  done
}

run_logged() {
  local name="$1" cmd="$2" status=0
  case "$name" in test|build|apptest|uitest|run) take_slot ;; esac
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

boot_sim='{ xcrun simctl boot $udid 2>/dev/null || true; } && xcrun simctl bootstatus $udid -b >/dev/null && xcrun simctl ui $udid appearance '"${APPEARANCE:-light}"' && xcrun simctl ui $udid content_size '"${CONTENT_SIZE:-large}"

launch_app() {
  # "$@" = launch arguments. Terminates the app, launches it with them, waits, then screenshots.
  # Each argument is quoted for the Mac's shell, so one argument stays one (spaces, and the `>`
  # that joins -demoRoute specs, are not reparsed there), and the settle time is this machine's.
  # An argument holding several flags ("-demo YES -demoTab spaces") is still split on spaces.
  local args="" arg word words
  for arg in "$@"; do
    if [[ $arg == -*" -"* ]]; then
      read -ra words <<<"$arg"
      for word in "${words[@]}"; do args+=" $(printf '%q' "$word")"; done
    else
      args+=" $(printf '%q' "$arg")"
    fi
  done
  echo "{ xcrun simctl terminate \$udid $BUNDLE_ID 2>/dev/null || true; } && xcrun simctl launch \$udid $BUNDLE_ID$args && sleep ${RUN_SETTLE_SECONDS:-4} && xcrun simctl io \$udid screenshot ~/$REMOTE_ROOT/screenshot.png"
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
    # Hosted tests use the keychain, which the simulator only grants to a signed app (-34018
    # otherwise), so sign ad hoc here; these later settings override CODE_SIGNING_ALLOWED=NO.
    run_logged apptest "$ensure_sim && $(xcbuild_app test 'id=$udid' "CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual $*")"
    ;;
  uitest)
    sync_up
    # Its own scheme, so apptest keeps to the unit bundle. Signed ad hoc like apptest.
    run_logged uitest "$ensure_sim && $generate && xcodebuild -project Inventory.xcodeproj -scheme InventoryUITests -configuration Debug -destination \"id=\$udid\" -derivedDataPath ~/$REMOTE_ROOT/DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual $* test"
    ;;
  run)
    out="${1:-$LOG_DIR/screenshot.png}"
    shift || true
    sync_up
    run_logged run "$ensure_sim && $(xcbuild_app build 'id=$udid' '') && $boot_sim && xcrun simctl install \$udid ~/$REMOTE_ROOT/DerivedData/Build/Products/Debug-iphonesimulator/Inventory.app && $(launch_app "$@")"
    scp -q "$MAC_HOST:$REMOTE_ROOT/screenshot.png" "$out" && echo "screenshot: $out"
    ;;
  launch)
    out="${1:-$LOG_DIR/screenshot.png}"
    shift || true
    run_logged launch "$ensure_sim && $boot_sim && $(launch_app "$@")"
    scp -q "$MAC_HOST:$REMOTE_ROOT/screenshot.png" "$out" && echo "screenshot: $out"
    ;;
  openurl)
    url="${1:?usage: mac.sh openurl <url> [out.png]}"
    out="${2:-$LOG_DIR/screenshot.png}"
    run_logged openurl "$ensure_sim && $boot_sim && xcrun simctl openurl \$udid '$url' && sleep ${RUN_SETTLE_SECONDS:-4} && xcrun simctl io \$udid screenshot ~/$REMOTE_ROOT/screenshot.png"
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
    # Every simulator of this checkout, whatever its DEVICE.
    remote "for n in inventory-$KEY inventory-$KEY-ipad inventory-$KEY-se; do for u in \$(xcrun simctl list devices | grep \"\$n (\" | grep -oE '[0-9A-F-]{36}'); do xcrun simctl shutdown \$u 2>/dev/null; xcrun simctl delete \$u 2>/dev/null; done; done; rm -rf ~/$REMOTE_ROOT" || true
    echo "removed ~/$REMOTE_ROOT and the inventory-$KEY simulators on $MAC_HOST"
    ;;
  *)
    sed -n '2,26p' "${BASH_SOURCE[0]}"
    ;;
esac
