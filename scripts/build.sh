#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="${STILL_BUILD_DIR:-$PWD/build}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
APP="$BUILD_DIR/Still.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/module-cache"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  Sources/*.swift -o "$APP/Contents/MacOS/Still" \
  -framework AppKit -framework WebKit -framework UniformTypeIdentifiers
cp Resources/* "$APP/Contents/Resources/"
cp LICENSE NOTICE "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f "$APP/Contents/Resources/Still.icns" ]; then
  xcrun swift -module-cache-path "$BUILD_DIR/module-cache" scripts/make-icon.swift "$BUILD_DIR"
  iconutil -c icns "$BUILD_DIR/Still.iconset" -o "$APP/Contents/Resources/Still.icns"
fi
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
