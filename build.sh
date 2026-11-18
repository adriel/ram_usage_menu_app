#!/bin/bash
# Builds "RAM Watch.app" for Apple Silicon, macOS 27+.
#   ./build.sh            build into ./build
#   ./build.sh --install  build and copy to /Applications, then launch
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="RAM Watch"
EXEC="RAMWatch"
MIN_OS="27.0"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
xcrun swiftc -O -swift-version 6 -default-isolation MainActor \
  -target "arm64-apple-macos$MIN_OS" -sdk "$SDK" \
  Sources/RAMWatch/*.swift \
  -o "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f "$BUILD/AppIcon.icns" ]; then
  echo "Rendering icon…"
  rm -rf "$BUILD/AppIcon.iconset"
  xcrun swift Scripts/make_icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature (no Apple Developer account needed).
codesign --force --sign - "$APP"

# Zip for sending to another Mac.
rm -f "$BUILD/RAM-Watch.zip"
ditto -c -k --keepParent "$APP" "$BUILD/RAM-Watch.zip"

echo "Built: $APP"
echo "Zip:   $BUILD/RAM-Watch.zip"

if [ "${1:-}" = "--install" ]; then
  pkill -x "$EXEC" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "Installed to /Applications and launched."
fi
