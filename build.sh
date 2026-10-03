#!/bin/bash
# Builds "Screen Recorder.app", copies it to your Applications folder and opens it.
#   ./build.sh               build, install and open
#   ./build.sh --no-install  only build (into ./build)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Screen Recorder"
BUNDLE_ID="io.github.fayzaans.ScreenRecorder"
APP="build/$APP_NAME.app"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Building needs Apple's free command line developer tools."
  echo "Click Install in the window that appears, wait for it to finish, then run ./build.sh again."
  xcode-select --install || true
  exit 1
fi

echo "Building $APP_NAME..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/ScreenRecorder"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--no-install" ]]; then
  echo "Built $APP"
  exit 0
fi

DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
TARGET="$DEST/$APP_NAME.app"

if [[ -e "$TARGET" ]]; then
  if [[ "$(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$BUNDLE_ID" ]]; then
    echo "A different app is already at $TARGET, so it was left alone." >&2
    exit 1
  fi
  # Quit the old copy so the new one can start.
  EXECUTABLE="$TARGET/Contents/MacOS/ScreenRecorder"
  pkill -f "$EXECUTABLE" || true
  for _ in {1..50}; do pgrep -f "$EXECUTABLE" >/dev/null || break; sleep 0.1; done
  rm -rf "$TARGET"
fi

mkdir -p "$DEST"
ditto "$APP" "$TARGET"
open "$TARGET"
echo "Installed $TARGET and opened it. Look for the ⏺ icon in your menu bar."
