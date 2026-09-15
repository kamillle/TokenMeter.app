#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/UsageBar.app"
BUILD_DIR="${USAGEBAR_BUILD_DIR:-${TMPDIR:-/tmp}/usagebar-build}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$BUILD_DIR/module-cache"
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement \
  "$ROOT/Sources/Collector.swift" "$ROOT/Sources/PricingUpdater.swift" "$ROOT/Sources/SessionSorting.swift" "$ROOT/Sources/BridgeManager.swift" "$ROOT/Sources/UsageBar.swift" \
  -o "$APP/Contents/MacOS/UsageBar"
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT/Sources/ClaudeBridge.swift" -o "$APP/Contents/Helpers/UsageBarClaudeBridge"
rm -f "$APP/Contents/Resources/collector.py" "$APP/Contents/Resources/claude_bridge.py" "$APP/Contents/Resources/bridge_setup.py"
cp "$ROOT/Sources/pricing.json" "$APP/Contents/Resources/"
cp "$ROOT/Sources/Assets/chatgpt-logo.png" "$ROOT/Sources/Assets/claude-logo.png" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UsageBar</string>
<key>CFBundleIdentifier</key><string>local.tokenmeter.TokenMeter</string>
<key>CFBundleName</key><string>UsageBar</string>
<key>CFBundleDisplayName</key><string>UsageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/UsageBarClaudeBridge"
codesign --force --sign - "$APP"
echo "$APP"
