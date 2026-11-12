#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ "$(uname -s)" != Darwin ]; then
    echo "The native helper must be built on macOS 14 or later." >&2
    exit 1
fi
command -v xcrun >/dev/null 2>&1 || { echo "Install Xcode Command Line Tools first." >&2; exit 1; }
mkdir -p build
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit -module-cache-path "${TMPDIR:-/tmp}/setalight-swift-module-cache" SetALightInput.swift -o build/setalight-input
mkdir -p "SetALight MCP.app/Contents/MacOS"
cp build/setalight-input "SetALight MCP.app/Contents/MacOS/setalight-input"
cat > "SetALight MCP.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>SetALight MCP</string>
    <key>CFBundleName</key><string>SetALight MCP</string>
    <key>CFBundleIdentifier</key><string>local.setalight.mcp</string>
    <key>CFBundleExecutable</key><string>setalight-input</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.1</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier local.setalight.mcp "SetALight MCP.app"
codesign --verify --strict "SetALight MCP.app"
