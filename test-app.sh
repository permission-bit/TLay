#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT_DIR/.test-build" "$ROOT_DIR/.module-cache"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$ROOT_DIR/.module-cache" \
  "$ROOT_DIR/MacApp/Core.swift" \
  "$ROOT_DIR/MacApp/Localization.swift" \
  "$ROOT_DIR/Tests/CoreTests.swift" \
  -o "$ROOT_DIR/.test-build/CoreTests"
"$ROOT_DIR/.test-build/CoreTests" "$ROOT_DIR/MacApp/Resources/Translations.json"
xcrun swiftc -parse-as-library -D TESTING -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$ROOT_DIR/.module-cache" \
  "$ROOT_DIR"/MacApp/*.swift \
  "$ROOT_DIR/Tests/ModelTests.swift" \
  -o "$ROOT_DIR/.test-build/ModelTests"
"$ROOT_DIR/.test-build/ModelTests"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$ROOT_DIR/.module-cache" \
  "$ROOT_DIR/MacApp/Core.swift" "$ROOT_DIR/MacApp/Localization.swift" \
  "$ROOT_DIR/MacApp/WindowManager.swift" "$ROOT_DIR/MacApp/Automation.swift" \
  "$ROOT_DIR/MacApp/DirectoryDiscovery.swift" "$ROOT_DIR/Tests/AutomationTests.swift" \
  -o "$ROOT_DIR/.test-build/AutomationTests"
"$ROOT_DIR/.test-build/AutomationTests"
