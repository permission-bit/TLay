#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/Terminal Layout.app"
MODULE_CACHE="$ROOT_DIR/.module-cache"
BUILD_DIR="$(mktemp -d "$ROOT_DIR/.app-build.XXXXXX")"
CONTENTS_DIR="$BUILD_DIR/Terminal Layout.app/Contents"
ARCHITECTURES="${ARCHITECTURES:-arm64 x86_64}"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$MODULE_CACHE"

BINARIES=()
xcrun swiftc "$ROOT_DIR/Tools/RenderIcon.swift" \
  -module-cache-path "$MODULE_CACHE" -o "$BUILD_DIR/RenderIcon"
"$BUILD_DIR/RenderIcon" "$BUILD_DIR/AppIcon.iconset"
cp "$BUILD_DIR/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
for architecture in $ARCHITECTURES; do
  case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
  binary="$BUILD_DIR/TerminalLayout-$architecture"
  xcrun swiftc \
    "$ROOT_DIR"/MacApp/*.swift \
    -o "$binary" \
    -target "$architecture-apple-macos13.0" \
    -module-name TerminalLayout \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -module-cache-path "$MODULE_CACHE" \
    -Xcc -fmodules-cache-path="$MODULE_CACHE" \
    -framework SwiftUI \
    -framework AppKit \
    -framework ApplicationServices
  BINARIES+=("$binary")
done
xcrun lipo -create "${BINARIES[@]}" -output "$CONTENTS_DIR/MacOS/TerminalLayout"

cp "$ROOT_DIR/MacApp/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR"/MacApp/Resources/*.json "$CONTENTS_DIR/Resources/"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$BUILD_DIR/Terminal Layout.app"
codesign --verify --strict "$BUILD_DIR/Terminal Layout.app"
# Only replace the generated bundle after compilation and signing succeed.
ditto "$BUILD_DIR/Terminal Layout.app" "$APP_DIR"

echo "Erstellt: $APP_DIR"
echo "Starten: open \"$APP_DIR\""
echo "Neue Instanz öffnen: open -n \"$APP_DIR\""
