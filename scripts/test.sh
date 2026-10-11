#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Tests/FileMonitorTests.swift Sources/FileMonitor.swift -o build/FileMonitorTests
build/FileMonitorTests
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Tests/RenderTests.swift Sources/ReaderApp.swift Sources/FileMonitor.swift Sources/DocumentIndex.swift Sources/SidebarSplitView.swift -o build/RenderTests \
  -framework AppKit -framework WebKit -framework UniformTypeIdentifiers
build/RenderTests "$PWD/Resources"
