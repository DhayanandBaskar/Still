#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_APP="$PWD/build/WindowControlsTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources" build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Tests/WindowControlsTests.swift Sources/ReaderApp.swift Sources/FileMonitor.swift Sources/DocumentIndex.swift Sources/SidebarSplitView.swift \
  -o "$TEST_APP/Contents/MacOS/WindowControlsTests" \
  -framework AppKit -framework WebKit -framework UniformTypeIdentifiers
cp Resources/* "$TEST_APP/Contents/Resources/"
"$TEST_APP/Contents/MacOS/WindowControlsTests"
